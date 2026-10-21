-- ============================================================================
-- MATHILDES KAGER — SUPABASE OPSÆTNING (supabase-setup.sql)
-- ============================================================================
-- Kopiér hele indholdet af denne fil ind i Supabase -> "SQL Editor" -> "New query"
-- og klik på "Run".
-- ============================================================================

-- 1. Opret tabellen til kager
CREATE TABLE IF NOT EXISTS public.cakes (
  position SERIAL PRIMARY KEY,
  id TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL,
  date_added TEXT NOT NULL,
  published BOOLEAN NOT NULL DEFAULT true,
  ratings INTEGER[] NOT NULL DEFAULT '{}',
  short_description TEXT NOT NULL,
  ingredients TEXT[] NOT NULL DEFAULT '{}',
  image TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Tabel til at huske hvem der allerede har bedømt en kage (1 bedømmelse pr. bruger pr. kage)
CREATE TABLE IF NOT EXISTS public.cake_votes (
  cake_id TEXT NOT NULL,
  voter_id TEXT NOT NULL,
  rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (cake_id, voter_id)
);

ALTER TABLE public.cake_votes ENABLE ROW LEVEL SECURITY;

-- Slå Row Level Security (RLS) til på cakes, så kun læsning er åben direkte,
-- mens bedømmelser og admin-ændringer sker gennem sikrede funktioner.
ALTER TABLE public.cakes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Alle kan læse kager" ON public.cakes;
CREATE POLICY "Alle kan læse kager"
  ON public.cakes
  FOR SELECT
  USING (true);

-- 3. Funktion så hver besøgende har én bedømmelse pr. kage, kan ændre den eller fjerne den ved at trykke igen
DROP FUNCTION IF EXISTS public.rate_cake(TEXT, INTEGER);
DROP FUNCTION IF EXISTS public.rate_cake(TEXT, INTEGER, TEXT);
CREATE OR REPLACE FUNCTION public.rate_cake(
  cake_id TEXT,
  new_rating INTEGER,
  voter_id TEXT DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  updated_row public.cakes;
  effective_voter TEXT;
  old_rating INTEGER;
  current_ratings INTEGER[];
  pos INTEGER;
  arr_len INTEGER;
BEGIN
  effective_voter := NULLIF(TRIM(COALESCE(voter_id, '')), '');
  IF effective_voter IS NULL THEN
    -- Fallback til besøgendes IP-hash hvis voter_id ikke er angivet
    effective_voter := encode(
      sha256(
        convert_to(
          COALESCE(current_setting('request.headers', true)::json->>'x-forwarded-for', 'anon'),
          'UTF8'
        )
      ),
      'hex'
    );
  END IF;

  SELECT cv.rating INTO old_rating
  FROM public.cake_votes cv
  WHERE cv.cake_id = rate_cake.cake_id AND cv.voter_id = effective_voter;

  -- Hvis brugeren trykker på samme rating igen (eller sender <= 0 / NULL), fjernes bedømmelsen
  IF new_rating IS NULL OR new_rating <= 0 OR (old_rating IS NOT NULL AND new_rating = old_rating) THEN
    IF old_rating IS NOT NULL THEN
      DELETE FROM public.cake_votes
      WHERE cake_votes.cake_id = rate_cake.cake_id AND cake_votes.voter_id = effective_voter;

      SELECT c.ratings INTO current_ratings
      FROM public.cakes c
      WHERE c.id = rate_cake.cake_id;

      pos := array_position(current_ratings, old_rating);
      IF pos IS NOT NULL THEN
        arr_len := array_length(current_ratings, 1);
        IF arr_len IS NULL OR arr_len <= 1 THEN
          current_ratings := '{}'::integer[];
        ELSIF pos = 1 THEN
          current_ratings := current_ratings[2:arr_len];
        ELSIF pos = arr_len THEN
          current_ratings := current_ratings[1:arr_len-1];
        ELSE
          current_ratings := current_ratings[1:pos-1] || current_ratings[pos+1:arr_len];
        END IF;
      END IF;

      UPDATE public.cakes
      SET ratings = COALESCE(current_ratings, '{}'::integer[])
      WHERE id = rate_cake.cake_id
      RETURNING * INTO updated_row;
    ELSE
      SELECT * INTO updated_row
      FROM public.cakes
      WHERE id = rate_cake.cake_id;
    END IF;

    IF updated_row.id IS NULL THEN
      RAISE EXCEPTION 'Kagen blev ikke fundet';
    END IF;

    RETURN row_to_json(updated_row);
  END IF;

  IF new_rating < 1 OR new_rating > 5 THEN
    RAISE EXCEPTION 'Bedømmelsen skal være mellem 1 og 5';
  END IF;

  IF old_rating IS NULL THEN
    INSERT INTO public.cake_votes (cake_id, voter_id, rating)
    VALUES (rate_cake.cake_id, effective_voter, new_rating);

    UPDATE public.cakes
    SET ratings = array_append(COALESCE(ratings, '{}'::integer[]), new_rating)
    WHERE id = rate_cake.cake_id
    RETURNING * INTO updated_row;
  ELSE
    UPDATE public.cake_votes
    SET rating = new_rating, created_at = now()
    WHERE cake_votes.cake_id = rate_cake.cake_id AND cake_votes.voter_id = effective_voter;

    SELECT c.ratings INTO current_ratings
    FROM public.cakes c
    WHERE c.id = rate_cake.cake_id;

    pos := array_position(current_ratings, old_rating);
    IF pos IS NOT NULL THEN
      current_ratings[pos] := new_rating;
    ELSE
      current_ratings := array_append(COALESCE(current_ratings, '{}'::integer[]), new_rating);
    END IF;

    UPDATE public.cakes
    SET ratings = COALESCE(current_ratings, '{}'::integer[])
    WHERE id = rate_cake.cake_id
    RETURNING * INTO updated_row;
  END IF;

  IF updated_row.id IS NULL THEN
    RAISE EXCEPTION 'Kagen blev ikke fundet';
  END IF;

  RETURN row_to_json(updated_row);
END;
$$;

-- Ekstra funktion til eksplicit afregistrering af bedømmelse
CREATE OR REPLACE FUNCTION public.remove_cake_rating(
  cake_id TEXT,
  voter_id TEXT DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN public.rate_cake(cake_id, 0, voter_id);
END;
$$;

-- 4. Sikrede admin-funktioner (hasher det modtagne token med SHA-256 på serveren,
--    så selv hvis koden på GitHub er offentlig, kan ingen kalde funktionerne uden adgangskoden)
CREATE OR REPLACE FUNCTION public.admin_create_cake(
  pw_hash TEXT,
  cake_id TEXT,
  cake_title TEXT,
  cake_date_added TEXT,
  cake_published BOOLEAN,
  cake_short_description TEXT,
  cake_ingredients TEXT[],
  cake_image TEXT
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  expected_double_hash CONSTANT TEXT := '01760f4539ecad69c38c21a67754badabe6510e8c6ecc217493d4bdfdc9ab5bd';
  actual_double_hash TEXT;
  new_row public.cakes;
BEGIN
  actual_double_hash := encode(sha256(convert_to(COALESCE(pw_hash, ''), 'UTF8')), 'hex');
  IF actual_double_hash IS DISTINCT FROM expected_double_hash THEN
    RAISE EXCEPTION 'Uautoriseret: Forkert adgangskode';
  END IF;

  INSERT INTO public.cakes (
    id, title, date_added, published, ratings, short_description, ingredients, image
  )
  VALUES (
    cake_id,
    cake_title,
    cake_date_added,
    COALESCE(cake_published, true),
    '{}',
    cake_short_description,
    COALESCE(cake_ingredients, '{}'),
    cake_image
  )
  RETURNING * INTO new_row;

  RETURN row_to_json(new_row);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_cake(
  pw_hash TEXT,
  cake_id TEXT,
  cake_title TEXT,
  cake_published BOOLEAN,
  cake_short_description TEXT,
  cake_ingredients TEXT[],
  cake_image TEXT
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  expected_double_hash CONSTANT TEXT := '01760f4539ecad69c38c21a67754badabe6510e8c6ecc217493d4bdfdc9ab5bd';
  actual_double_hash TEXT;
  updated_row public.cakes;
BEGIN
  actual_double_hash := encode(sha256(convert_to(COALESCE(pw_hash, ''), 'UTF8')), 'hex');
  IF actual_double_hash IS DISTINCT FROM expected_double_hash THEN
    RAISE EXCEPTION 'Uautoriseret: Forkert adgangskode';
  END IF;

  UPDATE public.cakes
  SET
    title = COALESCE(cake_title, title),
    published = COALESCE(cake_published, published),
    short_description = COALESCE(cake_short_description, short_description),
    ingredients = COALESCE(cake_ingredients, ingredients),
    image = COALESCE(cake_image, image)
  WHERE id = cake_id
  RETURNING * INTO updated_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Kagen blev ikke fundet';
  END IF;

  RETURN row_to_json(updated_row);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_cake(
  pw_hash TEXT,
  cake_id TEXT
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  expected_double_hash CONSTANT TEXT := '01760f4539ecad69c38c21a67754badabe6510e8c6ecc217493d4bdfdc9ab5bd';
  actual_double_hash TEXT;
BEGIN
  actual_double_hash := encode(sha256(convert_to(COALESCE(pw_hash, ''), 'UTF8')), 'hex');
  IF actual_double_hash IS DISTINCT FROM expected_double_hash THEN
    RAISE EXCEPTION 'Uautoriseret: Forkert adgangskode';
  END IF;

  DELETE FROM public.cake_votes WHERE cake_id = admin_delete_cake.cake_id;
  DELETE FROM public.cakes WHERE id = admin_delete_cake.cake_id;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reset_ratings(
  pw_hash TEXT,
  cake_id TEXT
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  expected_double_hash CONSTANT TEXT := '01760f4539ecad69c38c21a67754badabe6510e8c6ecc217493d4bdfdc9ab5bd';
  actual_double_hash TEXT;
  updated_row public.cakes;
BEGIN
  actual_double_hash := encode(sha256(convert_to(COALESCE(pw_hash, ''), 'UTF8')), 'hex');
  IF actual_double_hash IS DISTINCT FROM expected_double_hash THEN
    RAISE EXCEPTION 'Uautoriseret: Forkert adgangskode';
  END IF;

  DELETE FROM public.cake_votes WHERE cake_votes.cake_id = admin_reset_ratings.cake_id;

  UPDATE public.cakes
  SET ratings = '{}'
  WHERE id = admin_reset_ratings.cake_id
  RETURNING * INTO updated_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Kagen blev ikke fundet';
  END IF;

  RETURN row_to_json(updated_row);
END;
$$;

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

-- 3. Funktion så hver besøgende har én bedømmelse pr. kage, men kan ændre sin bedømmelse
DROP FUNCTION IF EXISTS public.rate_cake(TEXT, INTEGER);
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
BEGIN
  IF new_rating < 1 OR new_rating > 5 THEN
    RAISE EXCEPTION 'Bedømmelsen skal være mellem 1 og 5';
  END IF;

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

  IF old_rating IS NULL THEN
    INSERT INTO public.cake_votes (cake_id, voter_id, rating)
    VALUES (rate_cake.cake_id, effective_voter, new_rating);

    UPDATE public.cakes
    SET ratings = array_append(ratings, new_rating)
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
      current_ratings := array_append(COALESCE(current_ratings, '{}'), new_rating);
    END IF;

    UPDATE public.cakes
    SET ratings = current_ratings
    WHERE id = rate_cake.cake_id
    RETURNING * INTO updated_row;
  END IF;

  IF updated_row.id IS NULL THEN
    RAISE EXCEPTION 'Kagen blev ikke fundet';
  END IF;

  RETURN row_to_json(updated_row);
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

-- 5. Indsæt de 6 start-kager (hvis de ikke allerede findes)
INSERT INTO public.cakes (id, title, date_added, published, ratings, short_description, ingredients, image)
VALUES
  (
    'kaempe-hindbaersnitte-i-bradepande',
    'Kæmpe hindbærsnitte i bradepande',
    '20. oktober 2026',
    true,
    '{}',
    'Klassisk, sprød hindbærsnitte bagt i en hel bradepande med sød hindbærmarmelade, tyk glasur og farverigt krymmel.',
    ARRAY['Hvedemel', 'Flormelis', 'Bagepulver', 'Smør', 'Æg', 'Hindbærmarmelade', 'Krymmel'],
    'uploads/hindbaersnitte.jpg'
  ),
  (
    'studenterbroed',
    'Studenterbrød',
    '20. oktober 2026',
    true,
    '{}',
    'Hjemmelavede studenterbrød med sprød mørdejsbund, hindbærmarmelade, fyldig kakaotrøffel og lyserød glasur med krymmel.',
    ARRAY['Hvedemel', 'Flormelis', 'Salt', 'Smør', 'Æg', 'Vand', 'Kagerester', 'Mørk chokolade', 'Marcipan', 'Mørk rom', 'Hindbærmarmelade', 'Lyserød farvepasta', 'Krymmel'],
    'uploads/studenterbroed.jpg'
  ),
  (
    'hindbaermuffins-med-hvid-chokolade',
    'Hindbærmuffins med hvid chokolade',
    '20. oktober 2026',
    true,
    '{}',
    'Svampede og luftige vaniljemuffins fyldt med syrlige hindbær og stykker af sød hvid chokolade.',
    ARRAY['Smør', 'Æg', 'Sukker', 'Sødmælk', 'Hvedemel', 'Bagepulver', 'Vaniljesukker', 'Hvid chokolade', 'Hindbær'],
    'uploads/hindbaermuffins.jpg'
  ),
  (
    'pavlova',
    'Pavlova med friske bær',
    '20. oktober 2026',
    true,
    '{}',
    'Luftig marengskage med sprød yderside og sej midte, toppet med blødt flødeskum og masser af friske sommerbær.',
    ARRAY['Æggehvider', 'Sukker', 'Majsstivelse', 'Hvidvinseddike', 'Vaniljesukker', 'Piskefløde', 'Friske bær', 'Flormelis'],
    'uploads/pavlova.jpg'
  ),
  (
    'chokoladekage-med-oreo',
    'Chokoladekage med Oreo',
    '20. oktober 2026',
    true,
    '{}',
    'Snasket og syndig chokoladekage med hakket mørk chokolade, blød chokoladeglasur og masser af knuste Oreo-kiks.',
    ARRAY['Hvedemel', 'Sukker', 'Raps- eller solsikkeolie', 'Bagepulver', 'Æg', 'Mælk', 'Bagekakao', 'Salt', 'Mørk chokolade', 'Oreo-kiks', 'Smør', 'Flormelis', 'Vand', 'Vaniljesukker'],
    'uploads/chokoladekage-med-oreo.png'
  ),
  (
    'verdens-bedste-chocolate-chip-cookies',
    'Verdens bedste chocolate chip cookies',
    '20. oktober 2026',
    true,
    '{}',
    'Klassiske amerikanske chocolate chip cookies med sprøde kanter, sej midte, ægte vanilje, store stykker mørk chokolade og flagesalt.',
    ARRAY['Hvedemel', 'Natron', 'Bagepulver', 'Fint salt', 'Smør', 'Brun farin', 'Sukker', 'Æg', 'Vaniljestang', 'Mørk chokolade', 'Havsalt'],
    'uploads/chocolate-chip-cookies.jpg'
  )
ON CONFLICT (id) DO NOTHING;

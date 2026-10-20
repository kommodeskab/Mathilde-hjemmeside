# Mathildes Kager

En kage-tematiseret hjemmeside klar til **GitHub Pages + Supabase** (samt lokal visning).

## Sådan udgiver du på Supabase + GitHub Pages

### Trin 1: Opret gratis Supabase-database
1. Gå til [https://supabase.com](https://supabase.com) og log ind (f.eks. med din GitHub-konto).
2. Klik på **New project**, vælg et navn (f.eks. `mathildes-kager`), vælg et database-kodeord, og vælg en region tæt på Danmark (f.eks. *Central EU (Frankfurt)*). Klik **Create new project**.
3. Når projektet er klar (~1 minut), klik på **SQL Editor** i menuen til venstre og derefter **New query**.
4. Åbn filen `supabase-setup.sql` fra denne mappe, kopiér **hele** indholdet ind i SQL Editoren, og klik på **Run**.
   - Dette opretter automatisk tabellen `cakes`, indsætter de 6 start-kager og opretter de sikrede funktioner til bedømmelse og administration.

### Trin 2: Indsæt dine Supabase-nøgler i `supabase-config.js`
1. I Supabase-menuen til venstre klikker du på **Project Settings** (tandhjulet nederst) -> **API** (eller **Data API** / **API Keys**).
2. Kopiér:
   - **Project URL** (f.eks. `https://xyzcompany.supabase.co`)
   - **anon / public** nøglen (den lange tekststreng under *Project API keys*)
3. Åbn [`supabase-config.js`](./supabase-config.js) og indsæt begge værdier:
   ```js
   const SUPABASE_CONFIG = {
     url: "https://DIN-PROJEKT-ID.supabase.co",
     anonKey: "DIN-ANON-PUBLIC-KEY"
   };
   ```

### Trin 3: Læg koden på GitHub og slå GitHub Pages til
1. Opret et nyt repository på [https://github.com/new](https://github.com/new) (f.eks. `Mathilde-hjemmeside`).
2. Kør følgende kommandoer i terminalen fra denne mappe:
   ```bash
   git add .
   git commit -m "Mathildes Kager hjemmeside"
   git branch -M main
   git remote add origin https://github.com/DIT-BRUGERNAVN/Mathilde-hjemmeside.git
   git push -u origin main
   ```
3. Gå ind på dit repository på GitHub -> klik på **Settings** (øverst) -> **Pages** (i venstre menu).
4. Under **Build and deployment** -> **Branch**, vælg `main` og `/ (root)`, og klik **Save**.
5. Efter ca. 1 minut er hjemmesiden live på:
   `https://DIT-BRUGERNAVN.github.io/Mathilde-hjemmeside/`

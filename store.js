/**
 * store.js — Håndterer login, kommunikation med Supabase (når konfigureret i
 * supabase-config.js), lokal server.py (/api/cakes) samt localStorage-fallback.
 */

const CakeStore = (function () {
  const STORAGE_KEY = "mathildes_kager_data_v3";
  const SESSION_HASH_KEY = "mathildes_kager_admin_hash";
  // Kun den dobbelte SHA-256 hash SHA256(SHA256(password)) gemmes i koden.
  // Dermed kan ingen aflæse det mellemliggende token SHA256(password) fra et offentligt GitHub-repo.
  const ADMIN_PASSWORD_DOUBLE_HASH =
    "01760f4539ecad69c38c21a67754badabe6510e8c6ecc217493d4bdfdc9ab5bd";

  function isSupabaseConfigured() {
    return (
      typeof SUPABASE_CONFIG !== "undefined" &&
      Boolean(SUPABASE_CONFIG.url && SUPABASE_CONFIG.url.trim()) &&
      Boolean(SUPABASE_CONFIG.anonKey && SUPABASE_CONFIG.anonKey.trim())
    );
  }

  function supabaseHeaders() {
    const key = SUPABASE_CONFIG.anonKey.trim();
    return {
      "Content-Type": "application/json",
      apikey: key,
      Authorization: `Bearer ${key}`
    };
  }

  function supabaseUrl(path) {
    const base = SUPABASE_CONFIG.url.trim().replace(/\/+$/, "");
    return `${base}${path}`;
  }

  function mapRowFromSupabase(row) {
    if (!row) return null;
    return {
      id: row.id,
      title: row.title,
      dateAdded: row.date_added || row.dateAdded || "",
      published: row.published !== false,
      ratings: Array.isArray(row.ratings) ? row.ratings : [],
      shortDescription: row.short_description || row.shortDescription || "",
      ingredients: Array.isArray(row.ingredients) ? row.ingredients : [],
      image: row.image || ""
    };
  }

  // Ren JS SHA-256 fallback (hvis crypto.subtle ikke er tilgængelig på file://)
  function sha256Fallback(ascii) {
    function rightRotate(value, amount) {
      return (value >>> amount) | (value << (32 - amount));
    }
    const K = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];
    let H = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ];
    const words = [];
    const asciiBitLength = ascii.length * 8;
    ascii += "\x80";
    while ((ascii.length % 64) - 56) ascii += "\x00";
    for (let i = 0; i < ascii.length; i++) {
      const j = ascii.charCodeAt(i);
      words[i >> 2] |= j << ((3 - (i % 4)) * 8);
    }
    words[words.length] = Math.floor(asciiBitLength / 4294967296);
    words[words.length] = asciiBitLength;
    for (let j = 0; j < words.length; ) {
      const w = words.slice(j, (j += 16));
      const oldH = H.slice(0);
      for (let i = 0; i < 64; i++) {
        const w15 = w[i - 15],
          w2 = w[i - 2];
        const a = H[0],
          e = H[4];
        const temp1 =
          (H[7] +
            (rightRotate(e, 6) ^ rightRotate(e, 11) ^ rightRotate(e, 25)) +
            ((e & H[5]) ^ (~e & H[6])) +
            K[i] +
            (w[i] =
              i < 16
                ? w[i]
                : (w[i - 16] +
                    (rightRotate(w15, 7) ^ rightRotate(w15, 18) ^ (w15 >>> 3)) +
                    w[i - 7] +
                    (rightRotate(w2, 17) ^ rightRotate(w2, 19) ^ (w2 >>> 10))) |
                  0)) |
          0;
        const temp2 =
          ((rightRotate(a, 2) ^ rightRotate(a, 13) ^ rightRotate(a, 22)) +
            ((a & H[1]) ^ (a & H[2]) ^ (H[1] & H[2]))) |
          0;
        H = [(temp1 + temp2) | 0].concat(H);
        H[4] = (H[4] + temp1) | 0;
        H.length = 8;
      }
      for (let i = 0; i < 8; i++) {
        H[i] = (H[i] + oldH[i]) | 0;
      }
    }
    let result = "";
    for (let i = 0; i < 8; i++) {
      for (let j = 3; j >= 0; j--) {
        const b = (H[i] >> (j * 8)) & 255;
        result += (b < 16 ? "0" : "") + b.toString(16);
      }
    }
    return result;
  }

  async function hashPassword(password) {
    const str = String(password || "");
    if (window.crypto && window.crypto.subtle && window.TextEncoder) {
      try {
        const buf = await window.crypto.subtle.digest(
          "SHA-256",
          new TextEncoder().encode(str)
        );
        return Array.from(new Uint8Array(buf))
          .map((b) => b.toString(16).padStart(2, "0"))
          .join("");
      } catch (_e) {}
    }
    return sha256Fallback(unescape(encodeURIComponent(str)));
  }

  const DANISH_MONTHS = [
    "januar",
    "februar",
    "marts",
    "april",
    "maj",
    "juni",
    "juli",
    "august",
    "september",
    "oktober",
    "november",
    "december"
  ];

  function formatDanishDate(date = new Date()) {
    const day = date.getDate();
    const month = DANISH_MONTHS[date.getMonth()];
    const year = date.getFullYear();
    return `${day}. ${month} ${year}`;
  }

  function generateId(title) {
    let slug = (title || "kage")
      .toLowerCase()
      .replace(/æ/g, "ae")
      .replace(/ø/g, "oe")
      .replace(/å/g, "aa")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "");
    if (!slug) slug = "kage";
    const rand = Math.random().toString(16).substring(2, 8);
    return `${slug}-${rand}`;
  }

  function getSavedPasswordHash() {
    return sessionStorage.getItem(SESSION_HASH_KEY) || "";
  }

  function isLoggedIn() {
    const saved = getSavedPasswordHash();
    if (!saved) return false;
    return sha256Fallback(saved) === ADMIN_PASSWORD_DOUBLE_HASH;
  }

  function logout() {
    sessionStorage.removeItem(SESSION_HASH_KEY);
  }

  async function login(password) {
    const rawHash1 = await hashPassword(password);
    const rawHash2 = await hashPassword(rawHash1);
    const trimmedHash1 = await hashPassword(String(password || "").trim());
    const trimmedHash2 = await hashPassword(trimmedHash1);

    const matchedToken =
      rawHash2 === ADMIN_PASSWORD_DOUBLE_HASH
        ? rawHash1
        : trimmedHash2 === ADMIN_PASSWORD_DOUBLE_HASH
          ? trimmedHash1
          : "";

    if (matchedToken) {
      sessionStorage.setItem(SESSION_HASH_KEY, matchedToken);
      if (!isSupabaseConfigured()) {
        fetch("/api/login", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ passwordHash: matchedToken })
        }).catch(() => {});
      }
      return { ok: true };
    }

    return { ok: false, error: "Forkert adgangskode" };
  }

  function getLocalFallbackCakes() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) return parsed;
      }
    } catch (_e) {}
    const initial = typeof CAKES !== "undefined" ? JSON.parse(JSON.stringify(CAKES)) : [];
    initial.forEach((c) => {
      if (typeof c.published === "undefined") c.published = true;
    });
    return initial;
  }

  function saveLocalFallbackCakes(cakes) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(cakes));
    } catch (_e) {}
  }

  async function getAllCakes() {
    // 1. Hvis Supabase er konfigureret i supabase-config.js, hent derfra
    if (isSupabaseConfigured()) {
      try {
        const res = await fetch(
          supabaseUrl("/rest/v1/cakes?select=*&order=position.asc"),
          {
            method: "GET",
            headers: supabaseHeaders(),
            cache: "no-store"
          }
        );
        if (res.ok) {
          const rows = await res.json();
          const mapped = rows.map(mapRowFromSupabase).filter(Boolean);
          saveLocalFallbackCakes(mapped);
          return mapped;
        }
      } catch (_err) {}
    }

    // 2. Ellers prøv lokal server.py hvis den kører
    try {
      const res = await fetch("/api/cakes", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (Array.isArray(data.cakes)) {
          saveLocalFallbackCakes(data.cakes);
          return data.cakes;
        }
      }
    } catch (_networkError) {}

    // 3. Ellers brug lokal fallback
    return getLocalFallbackCakes();
  }

  async function getPublishedCakes() {
    const all = await getAllCakes();
    return all.filter((c) => c.published !== false);
  }

  async function createCake(cakeInput) {
    const pwHash = getSavedPasswordHash();
    const newId = generateId(cakeInput.title);
    const dateAdded = formatDanishDate();
    const title = (cakeInput.title || "").trim();
    const published = cakeInput.published !== false;
    const shortDescription = (cakeInput.shortDescription || "").trim();
    const ingredients = Array.isArray(cakeInput.ingredients)
      ? cakeInput.ingredients
      : [];
    const image = (cakeInput.image || "").trim();

    if (isSupabaseConfigured()) {
      try {
        const res = await fetch(supabaseUrl("/rest/v1/rpc/admin_create_cake"), {
          method: "POST",
          headers: supabaseHeaders(),
          body: JSON.stringify({
            pw_hash: pwHash,
            cake_id: newId,
            cake_title: title,
            cake_date_added: dateAdded,
            cake_published: published,
            cake_short_description: shortDescription,
            cake_ingredients: ingredients,
            cake_image: image
          })
        });
        if (res.ok) {
          const createdRow = await res.json();
          const cake = mapRowFromSupabase(createdRow);
          const cakes = await getAllCakes();
          return { ok: true, cake, cakes };
        }
        const err = await res.json().catch(() => ({}));
        return { ok: false, error: err.message || "Kunne ikke gemme i Supabase" };
      } catch (e) {
        return { ok: false, error: "Netværksfejl mod Supabase" };
      }
    }

    try {
      const res = await fetch("/api/cakes", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Admin-Password-Hash": pwHash
        },
        body: JSON.stringify(cakeInput)
      });
      if (res.ok) {
        const data = await res.json();
        saveLocalFallbackCakes(data.cakes);
        return { ok: true, cake: data.cake, cakes: data.cakes };
      }
    } catch (_networkError) {}

    const cakes = getLocalFallbackCakes();
    const newCake = {
      id: newId,
      title,
      dateAdded,
      published,
      ratings: [],
      shortDescription,
      ingredients,
      image
    };
    cakes.push(newCake);
    saveLocalFallbackCakes(cakes);
    return { ok: true, cake: newCake, cakes };
  }

  async function rateCake(id, ratingValue) {
    const rating = Number(ratingValue);
    if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
      return { ok: false, error: "Bedømmelsen skal være mellem 1 og 5 kager" };
    }

    if (isSupabaseConfigured()) {
      try {
        const res = await fetch(supabaseUrl("/rest/v1/rpc/rate_cake"), {
          method: "POST",
          headers: supabaseHeaders(),
          body: JSON.stringify({
            cake_id: id,
            new_rating: rating
          })
        });
        if (res.ok) {
          const updatedRow = await res.json();
          const cake = mapRowFromSupabase(updatedRow);
          const cakes = await getAllCakes();
          return { ok: true, cake, cakes };
        }
      } catch (_err) {}
    }

    try {
      const res = await fetch(`/api/cakes/${encodeURIComponent(id)}/rate`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ rating })
      });
      if (res.ok) {
        const data = await res.json();
        saveLocalFallbackCakes(data.cakes);
        return { ok: true, cake: data.cake, cakes: data.cakes };
      }
    } catch (_networkError) {}

    const cakes = getLocalFallbackCakes();
    const target = cakes.find((c) => c.id === id);
    if (!target) {
      return { ok: false, error: "Kagen blev ikke fundet" };
    }
    if (!Array.isArray(target.ratings)) {
      target.ratings = [];
    }
    target.ratings.push(rating);
    saveLocalFallbackCakes(cakes);
    return { ok: true, cake: target, cakes };
  }

  function getRatingStats(cake) {
    const ratings = Array.isArray(cake && cake.ratings)
      ? cake.ratings.map(Number).filter((n) => n >= 1 && n <= 5)
      : [];
    const count = ratings.length;
    if (count === 0) {
      return {
        count: 0,
        average: 0,
        rounded: 0,
        formattedAverage: "0,0",
        label: "Ingen bedømmelser endnu"
      };
    }
    const sum = ratings.reduce((acc, val) => acc + val, 0);
    const average = sum / count;
    const rounded = Math.round(average);
    const formattedAverage = average.toFixed(1).replace(".", ",");
    const countWord = count === 1 ? "bedømmelse" : "bedømmelser";
    return {
      count,
      average,
      rounded,
      formattedAverage,
      label: `${formattedAverage} / 5 kager (${count} ${countWord})`
    };
  }

  function renderStaticCakeIcons(roundedCount) {
    let html = "";
    for (let i = 1; i <= 5; i++) {
      const filled = i <= roundedCount;
      html += `<span class="rating-cake-icon ${filled ? "filled" : "empty"}" aria-hidden="true">🍰</span>`;
    }
    return html;
  }

  async function updateCake(id, updates) {
    const pwHash = getSavedPasswordHash();

    if (isSupabaseConfigured()) {
      try {
        const res = await fetch(supabaseUrl("/rest/v1/rpc/admin_update_cake"), {
          method: "POST",
          headers: supabaseHeaders(),
          body: JSON.stringify({
            pw_hash: pwHash,
            cake_id: id,
            cake_title: typeof updates.title === "string" ? updates.title : null,
            cake_published:
              typeof updates.published === "boolean" ? updates.published : null,
            cake_short_description:
              typeof updates.shortDescription === "string"
                ? updates.shortDescription
                : null,
            cake_ingredients: Array.isArray(updates.ingredients)
              ? updates.ingredients
              : null,
            cake_image: typeof updates.image === "string" ? updates.image : null
          })
        });
        if (res.ok) {
          const updatedRow = await res.json();
          const cake = mapRowFromSupabase(updatedRow);
          const cakes = await getAllCakes();
          return { ok: true, cake, cakes };
        }
        const err = await res.json().catch(() => ({}));
        return { ok: false, error: err.message || "Kunne ikke opdatere i Supabase" };
      } catch (_e) {
        return { ok: false, error: "Netværksfejl mod Supabase" };
      }
    }

    try {
      const res = await fetch(`/api/cakes/${encodeURIComponent(id)}`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
          "X-Admin-Password-Hash": pwHash
        },
        body: JSON.stringify(updates)
      });
      if (res.ok) {
        const data = await res.json();
        saveLocalFallbackCakes(data.cakes);
        return { ok: true, cake: data.cake, cakes: data.cakes };
      }
    } catch (_networkError) {}

    const cakes = getLocalFallbackCakes();
    const target = cakes.find((c) => c.id === id);
    if (!target) {
      return { ok: false, error: "Kagen blev ikke fundet" };
    }
    Object.assign(target, updates);
    saveLocalFallbackCakes(cakes);
    return { ok: true, cake: target, cakes };
  }

  async function deleteCake(id) {
    const pwHash = getSavedPasswordHash();

    if (isSupabaseConfigured()) {
      try {
        const res = await fetch(supabaseUrl("/rest/v1/rpc/admin_delete_cake"), {
          method: "POST",
          headers: supabaseHeaders(),
          body: JSON.stringify({
            pw_hash: pwHash,
            cake_id: id
          })
        });
        if (res.ok) {
          const cakes = await getAllCakes();
          return { ok: true, cakes };
        }
        const err = await res.json().catch(() => ({}));
        return { ok: false, error: err.message || "Kunne ikke slette i Supabase" };
      } catch (_e) {
        return { ok: false, error: "Netværksfejl mod Supabase" };
      }
    }

    try {
      const res = await fetch(`/api/cakes/${encodeURIComponent(id)}`, {
        method: "DELETE",
        headers: {
          "X-Admin-Password-Hash": pwHash
        }
      });
      if (res.ok) {
        const data = await res.json();
        saveLocalFallbackCakes(data.cakes);
        return { ok: true, cakes: data.cakes };
      }
    } catch (_networkError) {}

    const cakes = getLocalFallbackCakes().filter((c) => c.id !== id);
    saveLocalFallbackCakes(cakes);
    return { ok: true, cakes };
  }

  // Komprimerer og skalerer billeder (maks 1100px bred/høj, JPEG 82%),
  // så telefonbilleder fylder ~80-150 KB og kan gemmes lynhurtigt i Supabase.
  function compressImageToDataUrl(file, maxDim = 1100, quality = 0.82) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(new Error("Kunne ikke læse billedfilen"));
      reader.onload = () => {
        const img = new Image();
        img.onerror = () => resolve(reader.result);
        img.onload = () => {
          let { width, height } = img;
          if (width > maxDim || height > maxDim) {
            if (width >= height) {
              height = Math.round((height * maxDim) / width);
              width = maxDim;
            } else {
              width = Math.round((width * maxDim) / height);
              height = maxDim;
            }
          }
          const canvas = document.createElement("canvas");
          canvas.width = width;
          canvas.height = height;
          const ctx = canvas.getContext("2d");
          ctx.drawImage(img, 0, 0, width, height);
          resolve(canvas.toDataURL("image/jpeg", quality));
        };
        img.src = reader.result;
      };
      reader.readAsDataURL(file);
    });
  }

  async function uploadImage(file) {
    const dataUrl = await compressImageToDataUrl(file);
    if (isSupabaseConfigured()) {
      return { ok: true, url: dataUrl };
    }
    const pwHash = getSavedPasswordHash();
    try {
      const res = await fetch("/api/upload", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Admin-Password-Hash": pwHash
        },
        body: JSON.stringify({
          filename: file.name,
          dataUrl
        })
      });
      if (res.ok) {
        const data = await res.json();
        return { ok: true, url: data.url };
      }
    } catch (_networkError) {}
    return { ok: true, url: dataUrl };
  }

  function openLoginModal() {
    if (isLoggedIn()) {
      window.location.href = "admin.html";
      return;
    }

    let overlay = document.getElementById("login-modal-overlay");
    if (!overlay) {
      overlay = document.createElement("div");
      overlay.id = "login-modal-overlay";
      overlay.className = "modal-overlay";
      overlay.innerHTML = `
        <div class="modal-card" role="dialog" aria-modal="true" aria-labelledby="login-modal-title">
          <div class="modal-header">
            <h2 id="login-modal-title">🔒 Log ind</h2>
            <button type="button" class="modal-close-btn" id="login-modal-close" aria-label="Luk">&times;</button>
          </div>
          <p class="modal-subtitle">Indtast adgangskoden for at administrere Mathildes Kager.</p>
          <form id="login-modal-form">
            <label class="form-label" for="login-password-input">Adgangskode</label>
            <input
              type="password"
              id="login-password-input"
              class="form-input"
              placeholder="Indtast adgangskode..."
              required
              autocomplete="current-password"
            />
            <p id="login-modal-error" class="form-error" style="display: none;"></p>
            <div class="modal-actions">
              <button type="button" class="btn btn-secondary" id="login-modal-cancel">Annuller</button>
              <button type="submit" class="btn btn-primary">Log ind</button>
            </div>
          </form>
        </div>
      `;
      document.body.appendChild(overlay);

      const closeModal = () => {
        overlay.classList.remove("open");
      };

      overlay.querySelector("#login-modal-close").addEventListener("click", closeModal);
      overlay.querySelector("#login-modal-cancel").addEventListener("click", closeModal);
      overlay.addEventListener("click", (e) => {
        if (e.target === overlay) closeModal();
      });

      overlay.querySelector("#login-modal-form").addEventListener("submit", async (e) => {
        e.preventDefault();
        const input = overlay.querySelector("#login-password-input");
        const errEl = overlay.querySelector("#login-modal-error");
        errEl.style.display = "none";

        const result = await login(input.value);
        if (result.ok) {
          window.location.href = "admin.html";
        } else {
          errEl.textContent = result.error || "Forkert adgangskode";
          errEl.style.display = "block";
          input.select();
        }
      });
    }

    const input = overlay.querySelector("#login-password-input");
    const errEl = overlay.querySelector("#login-modal-error");
    input.value = "";
    errEl.style.display = "none";
    overlay.classList.add("open");
    setTimeout(() => input.focus(), 50);
  }

  function setupHeaderLoginButton() {
    const btn = document.getElementById("header-login-btn");
    if (!btn) return;
    if (isLoggedIn()) {
      btn.textContent = "⚙️ Administrer kager";
    } else {
      btn.textContent = "🔒 Log ind";
    }
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      openLoginModal();
    });
  }

  return {
    isLoggedIn,
    login,
    logout,
    getAllCakes,
    getPublishedCakes,
    createCake,
    updateCake,
    deleteCake,
    rateCake,
    getRatingStats,
    renderStaticCakeIcons,
    uploadImage,
    openLoginModal,
    setupHeaderLoginButton
  };
})();

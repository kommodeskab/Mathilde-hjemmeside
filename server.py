#!/usr/bin/env python3
"""
Mathildes Kager — Lokal & Online Webserver (server.py)

Kør lokalt med:
    python3 server.py

Åbn derefter:
    http://localhost:8000
"""

import base64
import datetime
import hashlib
import hmac
import json
import os
import re
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CAKES_JSON_PATH = os.path.join(BASE_DIR, "cakes.json")
CAKES_JS_PATH = os.path.join(BASE_DIR, "cakes.js")
UPLOADS_DIR = os.path.join(BASE_DIR, "uploads")

# Kun den dobbelte SHA-256 hash SHA256(SHA256(password)) gemmes i koden
ADMIN_PASSWORD_DOUBLE_HASH = os.environ.get(
    "ADMIN_PASSWORD_DOUBLE_HASH",
    "01760f4539ecad69c38c21a67754badabe6510e8c6ecc217493d4bdfdc9ab5bd",
)
PORT = int(os.environ.get("PORT", "8000"))


def sha256_hex(val):
    return hashlib.sha256((val or "").encode("utf-8")).hexdigest()


def verify_password(entered_password):
    double_hash = sha256_hex(sha256_hex(entered_password))
    return hmac.compare_digest(double_hash, ADMIN_PASSWORD_DOUBLE_HASH)


def verify_token_hash(token_hash):
    double_hash = sha256_hex(token_hash)
    return hmac.compare_digest(double_hash, ADMIN_PASSWORD_DOUBLE_HASH)

DANISH_MONTHS = {
    1: "januar",
    2: "februar",
    3: "marts",
    4: "april",
    5: "maj",
    6: "juni",
    7: "juli",
    8: "august",
    9: "september",
    10: "oktober",
    11: "november",
    12: "december",
}


def format_danish_date(dt=None):
    if dt is None:
        dt = datetime.date.today()
    return f"{dt.day}. {DANISH_MONTHS[dt.month]} {dt.year}"


def generate_cake_id(title):
    slug = (title or "kage").lower()
    slug = (
        slug.replace("æ", "ae")
        .replace("ø", "oe")
        .replace("å", "aa")
    )
    slug = re.sub(r"[^a-z0-9]+", "-", slug).strip("-")
    if not slug:
        slug = "kage"
    short_uid = uuid.uuid4().hex[:6]
    return f"{slug}-{short_uid}"


def load_cakes():
    if not os.path.exists(CAKES_JSON_PATH):
        return []
    with open(CAKES_JSON_PATH, "r", encoding="utf-8") as f:
        cakes = json.load(f)
    for cake in cakes:
        if "published" not in cake:
            cake["published"] = True
        if not isinstance(cake.get("ratings"), list):
            cake["ratings"] = []
    return cakes


def save_cakes(cakes):
    with open(CAKES_JSON_PATH, "w", encoding="utf-8") as f:
        json.dump(cakes, f, ensure_ascii=False, indent=2)

    # Hold også cakes.js synkroniseret som backup
    js_content = (
        "// Auto-synkroniseret fra cakes.json\n"
        "const CAKES = "
        + json.dumps(cakes, ensure_ascii=False, indent=2)
        + ";\n"
    )
    with open(CAKES_JS_PATH, "w", encoding="utf-8") as f:
        f.write(js_content)


class CakeRequestHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=BASE_DIR, **kwargs)

    def send_json(self, status_code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_json_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        raw = self.rfile.read(length).decode("utf-8")
        return json.loads(raw)

    def is_authorized(self):
        auth_hash = self.headers.get("X-Admin-Password-Hash", "")
        if auth_hash and verify_token_hash(auth_hash):
            return True
        auth_pw = self.headers.get("X-Admin-Password", "")
        return verify_password(auth_pw)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/cakes":
            cakes = load_cakes()
            self.send_json(200, {"ok": True, "cakes": cakes})
            return
        return super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)

        if parsed.path == "/api/login":
            try:
                data = self.read_json_body()
            except Exception:
                self.send_json(400, {"ok": False, "error": "Ugyldig forespørgsel"})
                return

            entered_pw = data.get("password", "")
            entered_hash = data.get("passwordHash", "")
            if (entered_pw and verify_password(entered_pw)) or (
                entered_hash and verify_token_hash(entered_hash)
            ):
                self.send_json(200, {"ok": True})
            else:
                self.send_json(401, {"ok": False, "error": "Forkert adgangskode"})
            return

        if parsed.path == "/api/upload":
            if not self.is_authorized():
                self.send_json(401, {"ok": False, "error": "Ikke logget ind"})
                return
            try:
                data = self.read_json_body()
                data_url = data.get("dataUrl", "")
                orig_name = data.get("filename", "billede.jpg")
                if not data_url.startswith("data:image/"):
                    self.send_json(400, {"ok": False, "error": "Kun billedfiler understøttes"})
                    return

                header, b64_data = data_url.split(",", 1)
                ext = ".jpg"
                if "image/png" in header:
                    ext = ".png"
                elif "image/webp" in header:
                    ext = ".webp"
                elif "image/gif" in header:
                    ext = ".gif"
                else:
                    _, guessed_ext = os.path.splitext(orig_name)
                    if guessed_ext.lower() in [".jpg", ".jpeg", ".png", ".webp", ".gif"]:
                        ext = guessed_ext.lower()

                os.makedirs(UPLOADS_DIR, exist_ok=True)
                filename = f"cake-{uuid.uuid4().hex[:10]}{ext}"
                filepath = os.path.join(UPLOADS_DIR, filename)
                with open(filepath, "wb") as f:
                    f.write(base64.b64decode(b64_data))

                self.send_json(200, {"ok": True, "url": f"uploads/{filename}"})
            except Exception as e:
                self.send_json(500, {"ok": False, "error": f"Kunne ikke gemme billede: {e}"})
            return

        if parsed.path == "/api/cakes":
            if not self.is_authorized():
                self.send_json(401, {"ok": False, "error": "Ikke logget ind"})
                return
            try:
                data = self.read_json_body()
                title = (data.get("title") or "").strip()
                if not title:
                    self.send_json(400, {"ok": False, "error": "Kagen skal have en titel"})
                    return

                cakes = load_cakes()
                new_cake = {
                    "id": generate_cake_id(title),
                    "title": title,
                    "dateAdded": format_danish_date(),
                    "published": bool(data.get("published", True)),
                    "ratings": [],
                    "shortDescription": (data.get("shortDescription") or "").strip(),
                    "ingredients": data.get("ingredients") or [],
                    "image": (data.get("image") or "").strip(),
                }
                cakes.append(new_cake)
                save_cakes(cakes)
                self.send_json(201, {"ok": True, "cake": new_cake, "cakes": cakes})
            except Exception as e:
                self.send_json(500, {"ok": False, "error": str(e)})
            return

        if parsed.path.startswith("/api/cakes/") and parsed.path.endswith("/rate"):
            cake_id = parsed.path[len("/api/cakes/") : -len("/rate")].strip("/")
            try:
                data = self.read_json_body()
                rating = int(data.get("rating", 0))
                voter_id = (data.get("voterId") or "").strip()
                if not voter_id:
                    voter_id = sha256_hex(self.client_address[0] if self.client_address else "anon")
                if rating < 1 or rating > 5:
                    self.send_json(400, {"ok": False, "error": "Bedømmelsen skal være mellem 1 og 5 kager"})
                    return

                cakes = load_cakes()
                target = None
                for cake in cakes:
                    if cake.get("id") == cake_id:
                        target = cake
                        break

                if not target:
                    self.send_json(404, {"ok": False, "error": "Kagen blev ikke fundet"})
                    return

                if not isinstance(target.get("ratings"), list):
                    target["ratings"] = []
                if not isinstance(target.get("voterRatings"), dict):
                    target["voterRatings"] = {}

                old_rating = target["voterRatings"].get(voter_id)
                if old_rating is not None and old_rating in target["ratings"]:
                    idx = target["ratings"].index(old_rating)
                    target["ratings"][idx] = rating
                else:
                    target["ratings"].append(rating)
                target["voterRatings"][voter_id] = rating

                save_cakes(cakes)
                self.send_json(200, {"ok": True, "cake": target, "cakes": cakes})
            except Exception as e:
                self.send_json(400, {"ok": False, "error": f"Ugyldig bedømmelse: {e}"})
            return

        self.send_json(404, {"ok": False, "error": "Ikke fundet"})

    def do_PUT(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/cakes/"):
            if not self.is_authorized():
                self.send_json(401, {"ok": False, "error": "Ikke logget ind"})
                return
            cake_id = parsed.path[len("/api/cakes/"):]
            try:
                data = self.read_json_body()
                cakes = load_cakes()
                target = None
                for cake in cakes:
                    if cake.get("id") == cake_id:
                        target = cake
                        break

                if not target:
                    self.send_json(404, {"ok": False, "error": "Kagen blev ikke fundet"})
                    return

                if "title" in data and data["title"].strip():
                    target["title"] = data["title"].strip()
                if "shortDescription" in data:
                    target["shortDescription"] = data["shortDescription"].strip()
                if "ingredients" in data:
                    target["ingredients"] = data["ingredients"]
                if "image" in data:
                    target["image"] = data["image"].strip()
                if "published" in data:
                    target["published"] = bool(data["published"])
                if "ratings" in data and isinstance(data["ratings"], list):
                    target["ratings"] = data["ratings"]
                    if len(data["ratings"]) == 0:
                        target["voterRatings"] = {}

                save_cakes(cakes)
                self.send_json(200, {"ok": True, "cake": target, "cakes": cakes})
            except Exception as e:
                self.send_json(500, {"ok": False, "error": str(e)})
            return

        self.send_json(404, {"ok": False, "error": "Ikke fundet"})

    def do_DELETE(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/cakes/"):
            if not self.is_authorized():
                self.send_json(401, {"ok": False, "error": "Ikke logget ind"})
                return
            cake_id = parsed.path[len("/api/cakes/"):]
            cakes = load_cakes()
            new_cakes = [c for c in cakes if c.get("id") != cake_id]
            if len(new_cakes) == len(cakes):
                self.send_json(404, {"ok": False, "error": "Kagen blev ikke fundet"})
                return
            save_cakes(new_cakes)
            self.send_json(200, {"ok": True, "cakes": new_cakes})
            return

        self.send_json(404, {"ok": False, "error": "Ikke fundet"})


if __name__ == "__main__":
    os.makedirs(UPLOADS_DIR, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), CakeRequestHandler)
    print(f"🎂 Mathildes Kager server kører på http://localhost:{PORT}")
    print("Tryk Ctrl+C for at stoppe serveren.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopper server...")
        server.server_close()

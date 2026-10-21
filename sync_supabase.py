#!/usr/bin/env python3
"""
Synkroniserer supabase-setup.sql direkte til Supabase via Management API.
Læser SUPABASE_ACCESS_TOKEN og SUPABASE_PROJECT_REF fra .env (som er gitignored).
"""

import json
import os
import sys
import urllib.error
import urllib.request

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(BASE_DIR, ".env")
SQL_PATH = os.path.join(BASE_DIR, "supabase-setup.sql")


def load_env(filepath):
    env = {}
    if not os.path.exists(filepath):
        return env
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip("'").strip('"')
    return env


def main():
    env = load_env(ENV_PATH)
    token = os.environ.get("SUPABASE_ACCESS_TOKEN") or env.get("SUPABASE_ACCESS_TOKEN")
    project_ref = (
        os.environ.get("SUPABASE_PROJECT_REF")
        or env.get("SUPABASE_PROJECT_REF")
        or "xemxsjexcanfzndeuviq"
    )

    if not token:
        print("⚠️  SUPABASE_ACCESS_TOKEN mangler i .env — springer Supabase SQL-synkronisering over.")
        return 0

    if not os.path.exists(SQL_PATH):
        print(f"❌ Kunne ikke finde {SQL_PATH}", file=sys.stderr)
        return 1

    with open(SQL_PATH, "r", encoding="utf-8") as f:
        sql_query = f.read()

    url = f"https://api.supabase.com/v1/projects/{project_ref}/database/query"
    payload = json.dumps({"query": sql_query}).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "MathildesKager-Sync/1.0",
        },
        method="POST",
    )

    print(f"🔄 Kører supabase-setup.sql mod Supabase-projekt ({project_ref})...")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status = resp.getcode()
            print(f"✅ supabase-setup.sql blev kørt i Supabase (HTTP {status})!")
            return 0
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        print(f"❌ Fejl fra Supabase API (HTTP {e.code}): {err_body}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"❌ Kunne ikke forbinde til Supabase API: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

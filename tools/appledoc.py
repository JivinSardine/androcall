#!/usr/bin/env python3
"""Fetch an Apple DocC symbol page and print a compact availability/abstract summary.

Usage: appledoc.py corebluetooth/cbcentralmanager [more/symbol/paths...]
       appledoc.py --search "keyword"   (lists matching symbols from the local index)
"""
import json
import subprocess
import sys

BASE = "https://developer.apple.com/tutorials/data/documentation/"


def fetch(path):
    url = BASE + path + ".json"
    # curl is used because the local TLS chain is intercepted by a proxy whose
    # root CA the system keychain trusts but Python's bundled certs do not.
    out = subprocess.run(
        ["curl", "-sS", "--max-time", "40", url], capture_output=True, check=True
    )
    return json.loads(out.stdout.decode("utf-8"))


def summarize(path):
    try:
        d = fetch(path)
    except subprocess.CalledProcessError as e:
        return f"{path}: curl failed rc={e.returncode} {e.stderr.decode()[:200]}"
    except Exception as e:  # noqa: BLE001
        return f"{path}: ERROR {e}"
    md = d.get("metadata", {})
    plats = md.get("platforms", [])
    pstr = ", ".join(
        f"{p['name']} {p.get('introducedAt', p.get('name', '?'))}" for p in plats
    )
    abst = " ".join(x.get("text", "") for x in d.get("abstract", []))
    out = [f"### {md.get('title')}  ({path})"]
    out.append(f"ABSTRACT: {abst}")
    out.append(f"PLATFORMS: {pstr}")
    if md.get("deprecated"):
        out.append("DEPRECATED: yes")
    for s in d.get("topicSections", []):
        ids = s.get("identifiers", [])
        names = []
        for i in ids:
            ref = d.get("references", {}).get(i, {})
            t = ref.get("title") or ref.get("abstract") or ""
            names.append(t)
        out.append(f"  [{s.get('title')}] " + "; ".join(n for n in names if n)[:900])
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return
    for a in args:
        print(summarize(a.strip("/")))
        print()


if __name__ == "__main__":
    main()

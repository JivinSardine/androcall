#!/usr/bin/env python3
"""Fetch an Android reference page and print a compact summary.

Usage: androiddoc.py <path-under-/reference> [--grep PATTERN]
Prints: title, "Added in API level" lines, and any lines matching --grep.
"""
import re
import subprocess
import sys

BASE = "https://developer.android.com/reference/"


def fetch(path):
    out = subprocess.run(
        ["curl", "-sSL", "--max-time", "45", "-A", "Mozilla/5.0", BASE + path],
        capture_output=True,
        check=True,
    )
    html = out.stdout.decode("utf-8", "replace")
    html = re.sub(r"<script.*?</script>", " ", html, flags=re.S)
    html = re.sub(r"<style.*?</style>", " ", html, flags=re.S)
    text = re.sub(r"<[^>]+>", "\n", html)
    text = re.sub(r"&amp;", "&", text)
    text = re.sub(r"&lt;", "<", text)
    text = re.sub(r"&gt;", ">", text)
    text = re.sub(r"&quot;", '"', text)
    text = re.sub(r"&#39;", "'", text)
    text = re.sub(r"&nbsp;", " ", text)
    lines = [l.strip() for l in text.split("\n")]
    return [l for l in lines if l]


def main():
    argv = sys.argv[1:]
    grep = None
    paths = []
    i = 0
    while i < len(argv):
        if argv[i] == "--grep":
            grep = argv[i + 1]
            i += 2
        else:
            paths.append(argv[i])
            i += 1
    for path in paths:
        lines = fetch(path)
        print(f"===== {path} =====")
        title = next((l for l in lines if l.startswith("android.") or l.startswith("Companion")), "")
        print(f"TITLE: {title[:200]}")
        added = sorted({l for l in lines if re.search(r"(Added in API level|Requires API level)", l)})
        for a in added[:12]:
            print(f"  {a}")
        if grep:
            pat = re.compile(grep, re.I)
            hits = [l for l in lines if pat.search(l)]
            print(f"--- grep /{grep}/ ({len(hits)} hits) ---")
            seen = set()
            for h in hits:
                if h in seen:
                    continue
                seen.add(h)
                print(f"  {h[:400]}")
                if len(seen) > 40:
                    break
        print()


if __name__ == "__main__":
    main()

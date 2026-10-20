#!/usr/bin/env python3
"""Query the local Android SDK's api-versions.xml for authoritative API levels.

Usage: apiver.py android.telephony.TelephonyCallback [more.Class...]
       apiver.py --method android.telephony.TelecomManager placeCall
"""
import re
import sys
import xml.etree.ElementTree as ET

PLATFORM = "/Users/emperorrbk/Library/Android/sdk/platforms/android-36/data/api-versions.xml"


def load():
    tree = ET.parse(PLATFORM)
    classes = {}
    for c in tree.getroot().findall("class"):
        name = c.get("name")
        methods = {}
        for m in c.findall("method"):
            methods[m.get("name")] = m.get("since")
        classes[name] = (c.get("since"), methods)
    return classes


def main():
    classes = load()
    args = sys.argv[1:]
    if args and args[0] == "--method":
        cls, meth = args[1], args[2]
        since, methods = classes.get(cls, (None, {}))
        print(f"{cls} (class since {since})")
        for (name, _), s in sorted(methods.items()):
            if name == meth:
                print(f"  {name}  since API {s}")
        return
    for a in args:
        key = a.replace(".", "/", a.count(".") and 0) if False else a
        for cand in (a, a.replace(".", "/")):
            if cand in classes:
                key = cand
                break
        since, methods = classes.get(key, (None, None))
        if since is None:
            print(f"{a}: NOT FOUND")
            continue
        print(f"{a}: since API {since}")
        if methods:
            interesting = [
                (n, s) for n, s in methods.items()
                if any(k in n.lower() for k in
                       ("call", "state", "place", "listener", "register", "phone", "contact", "name"))
            ]
            seen = set()
            for n, s in sorted(interesting, key=lambda x: (int(x[1]) if x[1] and x[1].isdigit() else 999, x[0])):
                if (n, s) in seen:
                    continue
                seen.add((n, s))
                print(f"    {n} -> API {s}")


if __name__ == "__main__":
    main()

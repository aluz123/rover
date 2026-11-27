#!/usr/bin/env python3
"""Plain-English phrase checks for Rover's query understanding (no LLM, no windows).

Builds the fake home folder from launch/demo/make_home.py, indexes only that folder (ROVER_DEMO_HOME),
and checks what Rover understood and what it found. Works the same on any Mac.
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROVER = os.environ.get("ROVER_BIN", os.path.join(HERE, "..", "dist", "Rover.app", "Contents", "MacOS", "Rover"))
TOP = 5
# (query, chips that must appear, name fragment expected in the top 5, fragment expected at #1)
CASES = [
    ("latest pitch deck short", ["newest first", "Deck", "short"], None, "Pitch Deck — short version"),
    ("can you find the short pitch deck", ["short"], "short version", None),
    ("where's my pitch deck", ["Deck"], "Pitch Deck", None),
    ("i'm looking for the pitch deck i made", ["Deck"], "Pitch Deck", None),
    ("the lumen nda", [], None, "NDA — Lumen"),
    ("ortiz contract", [], None, "Consulting Agreement — Ortiz"),
    ("screenshots from two weeks ago", ["Image", "~2 weeks ago"], "Screenshot", None),
    ("pdfs from a couple weeks ago", ["PDF", "~2 weeks ago"], None, None),
    ("photos from last summer", ["Image", "summer"], "IMG_", None),
    ("invoices since march", ["since march"], "Invoice", None),
    ("contracts before 2025", ["before 2025"], None, "Contractor Agreement 2024"),
    ("stuff i downloaded this morning", ["today", "downloads"], "Onboarding checklist", None),
    ("videos from last weekend", ["Video", "last weekend"], None, None),
    ("big videos", ["Video", "> 50 MB"], "Product demo raw", None),
    ("lese agreemnt", [], None, "Lease Agreement"),
    ("pitch deck investors", ["closest matches"], "Pitch Deck", None),
    ("presented slides", ["Presentation"], None, None),
    ("cv", [], None, "Resume 2026"),
    ("tax return 2025", [], None, "Tax Return 2025"),
    ("the one-pager", [], "One-pager", None),
    ("latest invoice", ["newest first"], None, "Invoice-2026-1042"),
    ("agreement", [], None, "Agreement"),
    ("presentation", ["Presentation"], "Pitch Deck", None),
    # apps behave like Spotlight's top hit
    ("term", [], None, "Terminal.app"),
    ("chrome", [], None, "Google Chrome.app"),
    ("calc", [], None, "Calculator.app"),
    ("settings", [], None, "System Settings.app"),
    ("saf", [], None, "Safari.app"),
]

def main():
    home = tempfile.mkdtemp(prefix="rover-demo-home-")
    subprocess.run([sys.executable, os.path.join(HERE, "..", "launch", "demo", "make_home.py"), home], check=True, capture_output=True)
    env = dict(os.environ, ROVER_DEMO_HOME=home, ROVER_PRO="1")   # the junk check is a Pro feature
    subprocess.run([ROVER, "--index"], env=env, check=True, capture_output=True)
    fails = 0
    for q, want, top5, top1 in CASES:
        r = json.loads(subprocess.run([ROVER, "--json", q], env=env, capture_output=True, text=True, timeout=30).stdout)
        chips = " · ".join(r["chips"])
        names = [h["name"] for h in r["hits"]]
        ok = all(w.lower() in chips.lower() for w in want)
        ok &= top5 is None or any(top5.lower() in n.lower() for n in names[:TOP])
        ok &= top1 is None or (names and top1.lower() in names[0].lower() and not names[0].endswith((".h", ".py")))
        fails += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {q:<40} understood: {chips or '-'}")
        if not ok or "-v" in sys.argv:
            for n in names[:3]: print("        ", n)
    # junk finder: what it suggests in the demo home, and what it must never suggest
    out = subprocess.run([ROVER, "junk", "--json"], env=env, capture_output=True, text=True).stdout
    if not out.lstrip().startswith("["):   # the free, open-source build has no Free Up Space (Rover Pro)
        print(f"skip  junk finder (Rover Pro, not in this build)\n\n{len(CASES) - fails}/{len(CASES)} passed")
        sys.exit(1 if fails else 0)
    junk = json.loads(out)
    cats = {}
    for j in junk: cats[j["category"]] = cats.get(j["category"], 0) + 1
    names = [os.path.basename(j["path"]) for j in junk]
    want = {"installers": 3, "duplicates": 1, "videos": 1, "big": 1, "downloads": 5}
    ok = cats == want and not any(n in names for n in ["Pitch Deck v7.key", "Tax Return 2025.pdf", "Figma-125.4.dmg", "setup-helper.dmg"])
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'}  junk finder suggests the right things     {cats}")
    print(f"\n{len(CASES) + 1 - fails}/{len(CASES) + 1} passed")
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()

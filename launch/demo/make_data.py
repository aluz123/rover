#!/usr/bin/env python3
"""Runs the real Rover engine over the fake demo home and saves the results the website and videos show.
usage: make_data.py  (writes docs/assets/data.js)"""
import json, os, subprocess, sys, tempfile, time, datetime
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ROVER = os.environ.get("ROVER_BIN", os.path.join(ROOT, "dist", "Rover.app", "Contents", "MacOS", "Rover"))
QUERIES = ["latest pitch deck short", "lese agreemnt", "photos from last summer", "invoice from last month",
           "big videos", "screenshots yesterday", "stuff i downloaded this morning", "contracts before 2025",
           "tax return 2025", "cv", "pitch deck", "pitch", "pi", "pitch d", "pitch de", "pitch dec", "latest", "latest p",
           "latest pi", "latest pitch", "latest pitch d", "latest pitch deck", "latest pitch deck s", "lease", "le", "les", "lese",
           "lese a", "lese agr", "lese agree", "photos", "photos from", "photos from last", "invoice", "invoices",
           "taxes", "documents", "taxes 2025", "nda", "big", "screenshots", "ortiz contract", "the lumen nda",
           "can you find the deck i made a couple weeks ago", "videos from last weekend", "invoices in downloads",
           "invoices folder", "big v", "big vid", "big video", "photos from last s", "photos from last sum", "lese agreem",
           "lese agreemn", "can you find the deck", "can you find the deck i made", "can you find the deck i made a couple weeks",
           "stuff", "stuff i downloaded", "stuff i downloaded this", "invoice from", "invoice from last", "invoice from last m",
           "resme", "the deck i made a couple weeks ago", "photos from last sumer"]
home = tempfile.mkdtemp(prefix="rover-demo-")
subprocess.run([sys.executable, os.path.join(ROOT, "launch", "demo", "make_home.py"), home], check=True, capture_output=True)
env = dict(os.environ, ROVER_DEMO_HOME=home)
subprocess.run([ROVER, "--index"], env=env, check=True, capture_output=True)
now = datetime.datetime.now()
def when(ts):
    d = datetime.datetime.fromtimestamp(ts)
    days = (now.date() - d.date()).days
    if days == 0: return "Today, " + d.strftime("%-I:%M %p")
    if days == 1: return "Yesterday"
    if days < 7: return d.strftime("%A")
    return d.strftime("%b %-d, %Y") if d.year != now.year else d.strftime("%b %-d")
def size(b, isdir):
    if isdir: return "Folder"
    for u, m in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if b >= m: return f"{b / m:.1f} {u}".replace(".0 ", " ")
    return f"{b} bytes"
out = {}
for q in QUERIES:
    r = json.loads(subprocess.run([ROVER, "--json", q], env=env, capture_output=True, text=True).stdout)
    out[q] = {"chips": r["chips"], "total": r["total"],
              "hits": [{"name": h["name"], "folder": os.path.dirname(h["path"]).replace("~/Library/Mobile Documents/com~apple~CloudDocs", "iCloud Drive"),
                        "kind": h["kind"], "size": size(h["size"], h["dir"]), "when": when(h["mtime"]), "dir": h["dir"]} for h in r["hits"][:8]]}
dst = os.path.join(ROOT, "docs", "assets", "data.js")
open(dst, "w").write("// Real Rover results on the fake demo home (launch/demo/make_home.py). Regenerate: python3 launch/demo/make_data.py\nwindow.ROVER_DATA = " + json.dumps(out, ensure_ascii=False, indent=1) + ";\n")
print("wrote", dst, len(out), "queries")

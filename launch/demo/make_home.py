#!/usr/bin/env python3
"""Builds a fake home folder for Rover's launch footage, so no real files ever appear on camera.
Files are sparse (no disk used) with realistic sizes and dates relative to today.
usage: make_home.py <out-dir>"""
import os, sys, time, random, shutil
random.seed(7)
out = os.path.abspath(sys.argv[1])
if os.path.exists(out): shutil.rmtree(out)
now = time.time(); D = 86400
ic = "Library/Mobile Documents/com~apple~CloudDocs"

def f(path, age_days, size):
    p = os.path.join(out, path)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as fh: fh.truncate(int(size))
    t = now - age_days * D
    os.utime(p, (t, t))

KB, MB, GB = 1024, 1024**2, 1024**3
files = [
 # pitch & company
 ("Downloads/Pitch Deck — short version.pdf", 3, 4.2*MB), ("Documents/Northwind/Pitch Deck v7.key", 6, 88*MB),
 ("Documents/Northwind/Pitch Deck v6.key", 40, 81*MB), ("Downloads/Pitch Deck v7 export.pdf", 5, 12*MB),
 ("Documents/Northwind/2min pitch script.pages", 9, 310*KB), ("Documents/Northwind/One-pager Q4.pdf", 12, 1.1*MB),
 ("Documents/Northwind/Board Update Nov.key", 2, 64*MB), ("Documents/Northwind/Financial Model 2027.numbers", 4, 2.3*MB),
 ("Documents/Northwind/Hiring Plan.numbers", 21, 680*KB), ("Documents/Northwind/Roadmap 2027.pdf", 15, 3.4*MB),
 (ic + "/Northwind/Investor Updates/Update — October.pdf", 33, 900*KB), (ic + "/Northwind/Investor Updates/Update — September.pdf", 63, 870*KB),
 (ic + "/Northwind/Brand/Logo Final.svg", 120, 48*KB), (ic + "/Northwind/Brand/Logo Final@2x.png", 120, 410*KB),
 (ic + "/Northwind/Brand/Brand Guidelines.pdf", 118, 14*MB),
 # money
 ("Downloads/Invoice-2026-1042.pdf", 28, 160*KB), ("Downloads/Invoice-2026-1038.pdf", 47, 158*KB),
 ("Downloads/Invoice — Figma annual.pdf", 31, 92*KB), ("Downloads/Receipt Apple Store.pdf", 19, 120*KB),
 ("Documents/Taxes/2025/W-2 2025.pdf", 260, 210*KB), ("Documents/Taxes/2025/1099-NEC Acme.pdf", 255, 180*KB),
 ("Documents/Taxes/2025/Tax Return 2025.pdf", 215, 2.9*MB), ("Documents/Taxes/2024/Tax Return 2024.pdf", 580, 2.7*MB),
 ("Documents/Invoices/Invoice-2026-0990.pdf", 80, 150*KB), ("Documents/Invoices/Invoice-2026-0971.pdf", 110, 149*KB),
 ("Downloads/Bank Statement Oct 2026.pdf", 22, 340*KB), ("Downloads/Bank Statement Sep 2026.pdf", 52, 330*KB),
 # legal
 ("Documents/Home/Lease Agreement 2026.pdf", 300, 1.6*MB), ("Documents/Home/Renters Insurance Policy.pdf", 290, 980*KB),
 ("Downloads/NDA — Lumen Labs (signed).pdf", 14, 260*KB), ("Documents/Northwind/Legal/Consulting Agreement — Ortiz.docx", 70, 88*KB),
 ("Documents/Northwind/Legal/Contractor Agreement 2024.pdf", 760, 300*KB), ("Documents/Northwind/Legal/Offer Letter — Priya.pdf", 25, 140*KB),
 # personal
 ("Documents/Career/Resume 2026.pdf", 45, 190*KB), ("Documents/Career/Cover Letter — Studio Ten.docx", 44, 40*KB),
 ("Documents/Travel/Lisbon Itinerary.pdf", 130, 420*KB), ("Documents/Travel/Boarding Pass LIS-SFO.pdf", 118, 260*KB),
 ("Documents/Travel/Passport scan.jpg", 400, 2.1*MB), ("Desktop/Wedding toast draft.pages", 8, 120*KB),
 ("Documents/Recipes/Grandma's lasagna.pdf", 900, 600*KB), ("Documents/Notes/Meeting notes — design sync.md", 1, 9*KB),
 ("Documents/Notes/Meeting notes — investor call.md", 7, 7*KB), ("Documents/Notes/Ideas.md", 0.2, 4*KB),
 # media
 ("Movies/Launch film final.mov", 3, 1.9*GB), ("Movies/Product demo raw.mov", 10, 6.4*GB), ("Movies/Lisbon drone.mp4", 125, 2.2*GB),
 ("Movies/Screen Recording 2026-11-20.mov", 2, 310*MB), ("Music/Voice memo — melody.m4a", 30, 4*MB),
 ("Desktop/hero-shot.png", 1, 3.2*MB), ("Desktop/mockup-dark.png", 1.5, 2.8*MB),
]
for p, a, s in files: f(p, a, s)
# screenshots: a steady trickle
for d in [0.05, 0.3, 1.1, 1.4, 2, 4, 6, 9, 13, 20, 35]:
    t = time.localtime(now - d * D)
    f(f"Desktop/Screenshot {time.strftime('%Y-%m-%d at %-I.%M.%S %p', t)}.png", d, random.randint(300, 2500) * KB)
# photos from the summer trip and general camera roll
for i in range(1, 41):
    f(f"Pictures/Lisbon 2026/IMG_{4100 + i}.HEIC", random.uniform(115, 140), random.randint(1800, 4200) * KB)
for i in range(1, 25):
    f(f"Pictures/Camera Roll/IMG_{5200 + i}.HEIC", random.uniform(1, 90), random.randint(1800, 4200) * KB)
f("Pictures/Headshot 2026.jpg", 60, 3.1*MB)
# downloads clutter
for n in ["setup-helper.dmg", "Figma-125.4.dmg", "font-pack.zip", "data-export-2026-11.zip", "IMG_0042 (1).jpg", "document (3).pdf"]:
    f("Downloads/" + n, random.uniform(0.1, 60), random.randint(200, 90000) * KB)
f("Downloads/Untitled design (4).png", 0.15, 1.2*MB); f("Downloads/Onboarding checklist.pdf", 0.1, 240*KB)
# projects with toolkit clutter that should rank low
for i, w in enumerate(["invoice", "pitch", "agreement", "lease", "photo", "deck", "report"]):
    f(f"Developer/northwind-web/src/components/{w.capitalize()}Card.tsx", 5 + i, 6*KB)
    f(f"Developer/northwind-web/vendor/sdk/include/{w}.h", 200, 20*KB)
    f(f"Developer/tools/miniforge3/pkgs/lib/python3.11/{w}.py", 300, 18*KB)
f("Developer/northwind-web/README.md", 5, 8*KB)
# junk the cleanup finder should catch: old installers, a duplicate, forgotten big files, stale downloads
f("Downloads/Zoom-installer-5.17.pkg", 240, 98*MB); f("Downloads/Install Blender 4.0.dmg", 400, 310*MB)
f("Downloads/xcode-tools-2025.dmg", 300, 1.2*GB); f("Desktop/Pitch Deck v7 export (1).pdf", 200, 12*MB); f("Desktop/Old/Pitch Deck v7 export.pdf", 200, 12*MB)
f("Movies/Old trip 2024 raw.mov", 720, 3.4*GB); f("Documents/Archive/photos-backup-2023.zip", 900, 2.1*GB)
for i, n in enumerate(["W-9 form.pdf", "boarding-pass-old.pdf", "manual_router.pdf", "conference-schedule-2024.pdf", "statement-2023-04.pdf"]):
    f("Downloads/" + n, 420 + i * 60, (2 + i) * MB)
# a few apps, so app launching can be tested (bundles are folders ending in .app)
for app in ["Applications/Safari.app", "Applications/Utilities/Terminal.app", "Applications/Google Chrome.app",
            "Applications/Calculator.app", "Applications/Calendar.app", "Applications/System Settings.app", "Downloads/Zoom Installer.app"]:
    f(app + "/Contents/Info.plist", 200, 2*KB)
f("Documents/Career/Term paper — design history.docx", 400, 60*KB); f("Documents/Notes/calc homework.txt", 300, 3*KB)
# a folder's date is when its newest item arrived, like on a real Mac
for dp, dns, fns in sorted(os.walk(out), key=lambda x: -x[0].count("/")):
    ts = [os.path.getmtime(os.path.join(dp, n)) for n in fns + dns]
    if ts: os.utime(dp, (max(ts), max(ts)))
print(sum(len(fs) for _, _, fs in os.walk(out)), "files in", out)

#!/usr/bin/env python3
"""Rover vs Spotlight benchmark — Rover by Alex Towfigh, MIT License.

Picks real files from your Desktop, Documents, Downloads and iCloud Drive, generates the kinds of
queries people actually type when they half-remember a file (an exact word, a typo, a partial word,
"pdf"-style kinds, dates, folders), and asks both tools. Queries are generated mechanically from the
file name and metadata, so neither tool is favored by hand-picked wording.

Spotlight is measured through `mdfind`, the command-line front end to the same index the Spotlight
UI uses. Scored on: #1 result, top 5, top 50, and "anywhere in the results" (order-independent, the
most generous measure for Spotlight because mdfind's ordering is not the UI's ranking).

Only files that Spotlight has indexed (findable by exact name) are used, so the test measures
query understanding and ranking, not index coverage. Coverage is reported separately.
"""
import json, os, random, re, statistics, subprocess, sys, time, datetime

HOME = os.path.expanduser("~")
ROVER = os.environ.get("ROVER_BIN", os.path.join(HOME, "Applications/Rover.app/Contents/MacOS/Rover"))
ROOTS = [HOME + "/Downloads", HOME + "/Documents", HOME + "/Desktop",
         HOME + "/Library/Mobile Documents/com~apple~CloudDocs"]
SKIP = {"node_modules", ".git", "__pycache__", ".venv", "venv", "build", "dist", ".next"}
KIND = {"pdf": "pdf", "png": "image", "jpg": "photo", "jpeg": "photo", "heic": "photo", "mov": "video", "mp4": "video",
        "xlsx": "spreadsheet", "csv": "spreadsheet", "numbers": "spreadsheet", "docx": "document", "doc": "document",
        "pages": "document", "pptx": "presentation", "key": "presentation", "zip": "archive", "dmg": "archive",
        "mp3": "audio", "m4a": "audio", "wav": "audio", "txt": "text", "md": "text"}
STOP = {"copy", "final", "file", "new", "untitled", "the", "and", "for", "with", "from", "img", "image", "screenshot",
        "document", "scan", "draft", "version"}
N_TARGETS = int(os.environ.get("N", "80"))
# SAMPLE=all: any file (mostly toolkit/SDK clutter on a developer Mac). SAMPLE=docs: documents and media
# outside toolkit folders, closer to what people actually go looking for.
SAMPLE = os.environ.get("SAMPLE", "all")
DOC_EXT = {"pdf", "docx", "doc", "pages", "pptx", "key", "xlsx", "csv", "numbers", "png", "jpg", "jpeg", "heic", "mov",
           "mp4", "m4a", "mp3", "wav", "zip", "txt", "md", "rtf", "psd", "ai", "svg", "stl", "step", "stp", "sldprt", "dwg"}
NOISE = {"miniforge3", "miniconda3", "anaconda3", "site-packages", "pkgs", "include", "third_party", "vendor", "deps",
         "cmsis", "esp-idf", "sdk", "cache", "caches", "locale", "locales", "dist", "build", "user data", "target",
         "history", "runtime", "temp", "tmp", "logs", "backups"}
random.seed(int(os.environ.get("SEED", "11")))


def words(stem):
    parts = re.split(r"[^A-Za-z]+", re.sub(r"([a-z])([A-Z])", r"\1 \2", stem))
    return [w.lower() for w in parts if len(w) >= 4 and w.lower() not in STOP]


def collect():
    files = []
    for root in ROOTS:
        if not os.path.isdir(root):
            continue
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if not d.startswith(".") and d not in SKIP and not d.endswith((".app", ".photoslibrary"))]
            depth = dp[len(root):].count("/")
            if depth > 5:
                dns[:] = []
            for f in fns:
                if f.startswith("."):
                    continue
                stem, ext = os.path.splitext(f)
                if SAMPLE == "docs":
                    parts = [x.lower() for x in dp[len(HOME):].split("/")]
                    junk = f.startswith("~$") or ".~(" in f or f.endswith("~")
                    if junk or ext.lower().lstrip(".") not in DOC_EXT or any(x in NOISE or x.startswith("_temp_") or re.fullmatch(r"[a-z]{2}[_-][a-z]{2}", x) for x in parts):
                        continue
                if len(words(stem)) >= 1:
                    files.append(os.path.join(dp, f))
    return files


def mdfind(args, timeout=20):
    t = time.perf_counter()
    try:
        out = subprocess.run(["mdfind"] + args, capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return [], timeout * 1000
    return [l for l in out.split("\n") if l], (time.perf_counter() - t) * 1000


def spotlight_knows(path):
    name = os.path.basename(path)
    res, _ = mdfind(["-onlyin", os.path.dirname(path), "-name", name], timeout=10)
    return path in res


def rel_time(mtime):
    now = datetime.datetime.now()
    d = datetime.datetime.fromtimestamp(mtime)
    age = (now - d).days
    if age < 1 and d.date() == now.date():
        return "today"
    if age < 7:
        return "this week" if d.isocalendar()[1] == now.isocalendar()[1] else "last week"
    if age < 60:
        return "last month"
    return str(d.year)


def place(path):
    for r, label in [(HOME + "/Downloads", "downloads"), (HOME + "/Documents", "documents"), (HOME + "/Desktop", "desktop")]:
        if path.startswith(r + "/"):
            return label
    return None


def typo(w):
    i = len(w) // 2
    return w[:i - 1] + w[i] + w[i - 1] + w[i + 1:]


def make_queries(path):
    stem, ext = os.path.splitext(os.path.basename(path))
    ws = sorted(set(words(stem)), key=len, reverse=True)
    if not ws:
        return []
    w = ws[0]
    qs = [("exact word", w)]
    if len(ws) >= 2:
        qs.append(("two words", f"{ws[1]} {ws[0]}"))
    if len(w) >= 6:
        qs.append(("typo", typo(w)))
        qs.append(("partial word", w[:max(4, len(w) // 2 + 1)]))
    k = KIND.get(ext.lower().lstrip("."))
    if k:
        qs.append(("word + kind", f"{w} {k}"))
    qs.append(("word + date", f"{w} {rel_time(os.path.getmtime(path))}"))
    p = place(path)
    if p:
        qs.append(("word + folder", f"{w} in {p}"))
    return qs


def main():
    print("collecting candidate files…", file=sys.stderr)
    files = collect()
    random.shuffle(files)
    targets, checked, unknown = [], 0, 0
    for f in files:
        if len(targets) >= N_TARGETS or checked > N_TARGETS * 4:
            break
        checked += 1
        if spotlight_knows(f):
            targets.append(f)
        else:
            unknown += 1
    print(f"{len(targets)} targets ({unknown} of {checked} sampled files were not findable in Spotlight by exact name)", file=sys.stderr)

    cases = []
    for t in targets:
        for cat, q in make_queries(t):
            cases.append({"cat": cat, "q": q, "target": t})

    # Rover: one process, warm index, best of 3
    tmp_in, tmp_out = "/tmp/rover_bench_in.json", "/tmp/rover_bench_out.json"
    json.dump([{"q": c["q"], "target": c["target"]} for c in cases], open(tmp_in, "w"))
    subprocess.run([ROVER, "--bench-file", tmp_in, tmp_out], check=True)
    rover = json.load(open(tmp_out))

    # Rover cold: a fresh process per query (includes launch + loading the index)
    cold = []
    for c in cases[:20]:
        t = time.perf_counter()
        subprocess.run([ROVER, c["q"]], capture_output=True)
        cold.append((time.perf_counter() - t) * 1000)

    results = []
    for c, r in zip(cases, rover):
        res, ms = mdfind(["-onlyin", HOME, c["q"]])
        srank = res.index(c["target"]) + 1 if c["target"] in res else 0
        results.append({**c, "rover_rank": r["rank"], "rover_ms": r["ms"], "rover_total": r["total"], "spot_rank": srank, "spot_ms": ms, "spot_total": len(res),
                        "spot_in50": 0 < srank <= 50})
        print(f"  {c['cat']:<14} {c['q'][:38]:<38} rover #{r['rank'] or '-':<3} spotlight #{srank or '-'}", file=sys.stderr)

    def score(rows, key):
        n = len(rows)
        if n == 0:
            return {}
        at = lambda k: sum(1 for x in rows if 0 < x[key] <= k) / n
        return {"n": n, "top1": at(1), "top5": at(5), "top50": at(50), "anywhere": sum(1 for x in rows if x[key] > 0) / n,
                "mrr": sum((1 / x[key]) if x[key] else 0 for x in rows) / n}

    cats = sorted(set(c["cat"] for c in results), key=lambda c: [x[0] for x in make_queries(targets[0])].index(c) if c in [x[0] for x in make_queries(targets[0])] else 9)
    summary = {
        "generated": datetime.datetime.now().isoformat(timespec="minutes"),
        "targets": len(targets), "queries": len(results), "sampled": checked, "spotlight_unknown": unknown,
        "overall": {"rover": score(results, "rover_rank"), "spotlight": score(results, "spot_rank")},
        "by_category": {cat: {"rover": score([x for x in results if x["cat"] == cat], "rover_rank"),
                              "spotlight": score([x for x in results if x["cat"] == cat], "spot_rank")}
                        for cat in sorted(set(x["cat"] for x in results))},
        "latency_ms": {
            "rover_warm_median": statistics.median(x["rover_ms"] for x in results),
            "rover_warm_p95": sorted(x["rover_ms"] for x in results)[int(len(results) * 0.95) - 1],
            "rover_cold_median": statistics.median(cold),
            "spotlight_median": statistics.median(x["spot_ms"] for x in results),
            "spotlight_p95": sorted(x["spot_ms"] for x in results)[int(len(results) * 0.95) - 1],
        },
        "examples": [{k: x[k] for k in ("cat", "q", "rover_rank", "spot_rank")} | {"file": x["target"].replace(HOME, "~")}
                     for x in random.sample(results, min(24, len(results)))],
    }
    summary["sample"] = SAMPLE
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results.json" if SAMPLE == "all" else f"results_{SAMPLE}.json")
    json.dump(summary, open(out, "w"), indent=2)
    print(json.dumps({k: summary[k] for k in ("targets", "queries", "overall", "latency_ms")}, indent=2))
    print("by category:")
    for cat, v in summary["by_category"].items():
        print(f"  {cat:<14} n={v['rover']['n']:<3} top1 rover {v['rover']['top1']:.0%} vs spotlight {v['spotlight']['top1']:.0%}   "
              f"top5 {v['rover']['top5']:.0%} vs {v['spotlight']['top5']:.0%}   anywhere {v['rover']['anywhere']:.0%} vs {v['spotlight']['anywhere']:.0%}")


if __name__ == "__main__":
    main()

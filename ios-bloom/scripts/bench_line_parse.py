#!/usr/bin/env python3
"""Benchmarks the per-line parse prompt (LineParseService) against a few fast models.

Run: python3 ios-bloom/scripts/bench_line_parse.py [model ...]
Sends each line of the example text in parallel (as the app does) and prints the
wall time per run plus whether every line produced the expected rules.
Keep SYSTEM in sync with LineParseService.systemPrompt.
"""
import concurrent.futures as cf
import json
import os
import subprocess
import sys
import time
import urllib.request

SYSTEM = open(os.path.join(os.path.dirname(__file__), "line_parse_prompt.txt")).read().strip()

LINES = [
    "Thyroid as soon as I wake up, no food for 30 min after.",
    "Progesterone AM and Progesterone PM at least 10 hours apart.",
    "Iron 4 hours after Thyroid, no food 1 hour before or after.",
    "Prenatal AM with lunch. Prenatal PM with dinner.",
    "Keep Iron and calcium 2 hours apart.",
]
KNOWN = ["Thyroid", "Progesterone AM", "Progesterone PM", "Iron", "Prenatal AM", "Prenatal PM", "Calcium"]

# (line index) -> set of (subject, relation, targetType, target, min) that must appear
EXPECT = {
    0: {("thyroid", "at", "wake", None, 0), ("thyroid", "before", "food", None, 30)},
    1: {("progesterone am", "apart", "medication", "progesterone pm", 600)},
    2: {("iron", "after", "medication", "thyroid", 240), ("iron", "apart", "food", None, 60)},
    3: {("prenatal am", "with", "meal", "lunch", None), ("prenatal pm", "with", "meal", "dinner", None)},
    4: {("iron", "apart", "medication", "calcium", 120)},
}


def call(model, line):
    """One line through the Rork AI gateway (same Vercel AI Gateway the app's proxy forwards to)."""
    t = time.time()
    out = subprocess.run(
        ["rork", "ai", "text", "-m", model, "-s", SYSTEM, "--json",
         "Known: " + ", ".join(KNOWN) + "\nLine: " + line],
        capture_output=True, text=True, timeout=30,
    )
    elapsed = time.time() - t
    data = json.loads(out.stdout)
    if not data.get("results"):
        raise RuntimeError(json.dumps(data.get("failures"))[:200])
    r = data["results"][0]
    return elapsed, r.get("text") or r.get("output") or json.dumps(r)


def norm(x):
    return x.strip().lower() if isinstance(x, str) else None


def check(i, content):
    try:
        j = json.loads(content[content.index("{"): content.rindex("}") + 1])
    except Exception:
        return False
    got = set()
    for r in j.get("rules", []):
        mn = r.get("min")
        got.add((norm(r.get("subject")), norm(r.get("relation")), norm(r.get("targetType")), norm(r.get("target")),
                 mn if mn not in (None, 0) or r.get("relation") != "with" else None))
    ok = True
    for e in EXPECT[i]:
        alt = (e[3], e[1], e[2], e[0], e[4])  # "apart" is symmetric
        if e not in got and not (e[1] == "apart" and alt in got):
            if e[1] == "with" and any(g[:4] == e[:4] for g in got):
                continue
            ok = False
    return ok


def run(model):
    t = time.time()
    with cf.ThreadPoolExecutor(len(LINES)) as ex:
        results = list(ex.map(lambda il: (il[0], *call(model, il[1])), enumerate(LINES)))
    wall = time.time() - t
    passed = all(check(i, c) for i, _, c in results)
    slowest = max(d for _, d, _ in results)
    return wall, slowest, passed, results


if __name__ == "__main__":
    models = sys.argv[1:] or ["google/gemini-3.8-flash", "google/gemini-2.5-flash-lite", "openai/gpt-4.1-nano", "openai/gpt-4.1-mini"]
    for m in models:
        walls = []
        fails = 0
        for _ in range(3):
            try:
                wall, slowest, passed, results = run(m)
                walls.append(wall)
                if not passed:
                    fails += 1
                    bad = [c for i, _, c in results if not check(i, c)]
                    print("   miss:", bad[0][:300].replace("\n", " "))
            except Exception as e:  # noqa
                print("   error:", e)
                fails += 1
        if walls:
            print(f"{m}: runs {', '.join(f'{w:.2f}s' for w in walls)} | median {sorted(walls)[len(walls)//2]:.2f}s | failed {fails}/3", flush=True)

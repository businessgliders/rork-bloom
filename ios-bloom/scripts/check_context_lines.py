#!/usr/bin/env python3
"""Checks her follow-on lines against real models, read the way the app reads them.

Run: python3 ios-bloom/scripts/check_context_lines.py [model ...]
1. Each line alone: a line naming no medication must come back with "needsContext" (or no rules).
2. Each follow-on line with its context (nearest medication line above, down to it): must give the expected rule.
Messages match LineParseService.userMessage. Keep line_parse_prompt.txt in sync with LineParseService.systemPrompt.
"""
import concurrent.futures as cf
import json
import os
import subprocess
import sys

SYSTEM = open(os.path.join(os.path.dirname(__file__), "line_parse_prompt.txt")).read().strip()

# (line, context, expected (subject, relation, targetType, target, min, max)) — her text, reconstructed.
CASES = [
    ("Thyroid first thing in the morning", [], ("thyroid", "at", "wake", None, 0, None)),
    ("30 minutes afterwards I can't have any food", ["Thyroid first thing in the morning"],
     ("thyroid", "before", "food", None, 30, None)),
    ("approximately 10 to 12 hours apart from progesterone p.m.", ["Progesterone a.m."],
     ("progesterone am", "apart", "medication", "progesterone pm", 600, 720)),
    ("at least four hours after taking the thyroid", ["Iron"], ("iron", "after", "medication", "thyroid", 240, None)),
    ("cannot have food two hours before", ["Iron", "at least four hours after taking the thyroid"],
     ("iron", "after", "food", None, 120, None)),
    ("or 1 hour afterwards", ["Iron", "at least four hours after taking the thyroid", "cannot have food two hours before"],
     ("iron", "before", "food", None, 60, None)),
    ("within one hour after my dinner", ["Prenatal vitamin"], ("prenatal vitamin", "after", "meal", "dinner", 0, 60)),
]
ALONE = [c[0] for c in CASES[1:]]


def message(line, context):
    out = "Known: none\n"
    if context:
        out += "Context (lines just above, only to tell which medication Line is about):\n" + "\n".join(context) + "\n"
    return out + "Line: " + line


def ask(model, line, context):
    out = subprocess.run(["rork", "ai", "text", "-m", model, "-s", SYSTEM, "--json", message(line, context)],
                         capture_output=True, text=True, timeout=120)
    data = json.loads(out.stdout)
    r = (data.get("results") or [{}])[0]
    text = r.get("text") or r.get("output") or ""
    return json.loads(text[text.index("{"): text.rindex("}") + 1])


def norm(x):
    if not isinstance(x, str):
        return None
    x = x.strip().lower().replace(".", "").replace("a m", "am").replace("p m", "pm")
    x = " ".join(x.split())
    for prefix in ("the ", "my ", "taking "):  # LineParseService.decode drops these too
        if x.startswith(prefix):
            x = x[len(prefix):]
    return x


def has(j, e):
    for r in j.get("rules", []):
        got = (norm(r.get("subject")), r.get("relation"), r.get("targetType"), norm(r.get("target")))
        alt = (got[3], got[1], got[2], got[0])
        if (got == e[:4] or (e[1] == "apart" and alt == e[:4])) and (r.get("min") or 0) == e[4] \
                and (e[5] is None or r.get("max") == e[5]):
            return True
    return False


def run(model):
    ok = True
    with cf.ThreadPoolExecutor(4) as ex:
        ctx = list(ex.map(lambda c: ask(model, c[0], c[1]), CASES))
        alone = list(ex.map(lambda l: ask(model, l, []), ALONE))
    for (line, _, e), j in zip(CASES, ctx):
        good = has(j, e)
        ok &= good
        print(("PASS " if good else "FAIL ") + line + ("" if good else "  -> " + json.dumps(j)))
    for line, j in zip(ALONE, alone):
        good = j.get("needsContext") is True or not j.get("rules")
        ok &= good
        print(("PASS alone " if good else "FAIL alone ") + line + ("" if good else "  -> " + json.dumps(j)))
    return ok


if __name__ == "__main__":
    models = sys.argv[1:] or ["deepseek/deepseek-v4.1-flash-1017-ultrafast", "anthropic/claude-haiku-5.5"]
    results = {m: run(m) for m in models}
    print(json.dumps(results))
    sys.exit(0 if all(results.values()) else 1)

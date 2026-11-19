#!/usr/bin/env bash
# QA helper: print the simulator's on-screen elements (keyboard keys hidden), one per line.
# Usage: scripts/simsnap.sh   (set SIM=<simulator id> when the session has several simulators)
simarg=()
if [ -n "$SIM" ]; then simarg=(--sim "$SIM"); fi
rork sim snapshot "${simarg[@]}" --json 2>/dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin)["snapshot"]["rows"]:
    if r.get("role") == "key":
        continue
    print(r["ref"], r.get("role"), r.get("untrustedLabel") or "", r.get("actions") or "", sep=" | ")
'

#!/usr/bin/env bash
# QA helper: tap the first simulator element whose label contains $1 (case-insensitive).
# Usage: scripts/simtap.sh "Continue"   (prints the tapped ref, or "missing")
# Set SIM=<simulator id> when the session has several simulators.
set -e
simarg=()
if [ -n "$SIM" ]; then simarg=(--sim "$SIM"); fi
snap=$(rork sim snapshot "${simarg[@]}" --json 2>/dev/null)
ref=$(printf '%s' "$snap" | python3 -c '
import json,sys
want=sys.argv[1].lower()
rows=json.load(sys.stdin)["snapshot"]["rows"]
for r in rows:
    if "tap" in r.get("actions","") and want in (r.get("untrustedLabel") or "").lower():
        print(r["ref"]); break
' "$1")
if [ -z "$ref" ]; then echo "missing: $1"; exit 1; fi
rork sim tap "${simarg[@]}" "$ref" >/dev/null 2>&1 && echo "tapped $ref ($1)"

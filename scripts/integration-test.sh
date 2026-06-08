#!/bin/bash
# Integration regression test: configure the bundled OphanimTest app with full capture, launch it,
# and assert that (a) it didn't crash and (b) each core capture category produced events. Guards the
# end-to-end pipeline that has historically broken (ring/interpose changes, hook crashes).
set -uo pipefail

BID="be.ophanim.testharness"
BIN="$HOME/Applications/Ophanim.app/Contents/MacOS/Ophanim"
APP="$HOME/Library/Containers/be.ophanim.Ophanim/Applications/$BID.app"
DIR="$HOME/Library/Containers/$BID/Data/Documents/Ophanim"
[ -x "$BIN" ] || { echo "✗ Ophanim not installed at $BIN"; exit 1; }
[ -d "$APP" ] || { echo "✗ test app not installed ($BID) - drop TestApp/build/OphanimTest.ipa into Ophanim"; exit 1; }

mcp() { printf '%s\n' "$1" | "$BIN" --mcp 2>/dev/null; }

echo "▸ configuring full capture…"
mcp "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"set_config\",\"arguments\":{\"bundleID\":\"$BID\",\"enabled\":true,\"categories\":[\"network\",\"keychain\",\"crypto\",\"device\",\"privacy\",\"filesystem\",\"process\",\"jailbreak\"]}}}" >/dev/null

crashes_before=$(ls "$HOME/Library/Logs/DiagnosticReports/OphanimTest-"*.ips 2>/dev/null | wc -l | tr -d ' ')
pkill -x OphanimTest 2>/dev/null; sleep 1
echo "▸ launching test app…"
open "$APP"; sleep 12
crashes_after=$(ls "$HOME/Library/Logs/DiagnosticReports/OphanimTest-"*.ips 2>/dev/null | wc -l | tr -d ' ')
pkill -x OphanimTest 2>/dev/null

LOG=$(ls -t "$DIR"/*.ndjson 2>/dev/null | head -1)
[ -n "$LOG" ] || { echo "✗ no capture log produced"; exit 1; }

echo "▸ asserting events (log: $(basename "$LOG"))…"
python3 - "$LOG" "$crashes_before" "$crashes_after" <<'PY'
import json, sys, collections
log, cb, ca = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
cats = collections.Counter()
for ln in open(log):
    ln = ln.strip()
    if not ln: continue
    try: o = json.loads(ln)
    except: continue
    cats[o.get("category")] += 1
required = ["network", "keychain", "crypto", "filesystem", "process"]
fails = []
if ca > cb: fails.append(f"app crashed ({ca-cb} new report(s))")
for c in required:
    if cats.get(c, 0) == 0: fails.append(f"no {c} events")
print("  category counts:", dict(cats))
if fails:
    print("✗ FAIL:", "; ".join(fails)); sys.exit(1)
print("✓ PASS - no crash; all core categories captured.")
PY

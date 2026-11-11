#!/bin/bash
# Regenerates docs/screenshots from a debug build, a throwaway demo app and
# sample clipboard data. Nothing of the real desktop or clipboard history is
# captured. Panels flash on screen for about 20 s; keep your hands off the
# keyboard so the demo app can come to the front (tiling and dimming need
# that and are skipped otherwise). Run `make install` afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'touch "$WORK/text.quit"; sleep 0.5; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/data" "$WORK/out" docs/screenshots

scripts/build-app.sh debug
swiftc -O -o "$WORK/Demo" scripts/selftest/Probe.swift
: > "$WORK/text"
"$WORK/Demo" "$WORK/text" demo > "$WORK/demo.out" &
for _ in $(seq 1 50); do grep -q '^PID ' "$WORK/demo.out" 2>/dev/null && break; sleep 0.2; done
DEMO_PID="$(awk '/^PID /{print $2}' "$WORK/demo.out")"
[ -n "$DEMO_PID" ] || { echo "demo app did not start"; exit 1; }

pkill -x Flit || true
sleep 0.8
open -n build/Flit.app --args --screenshots "$WORK/out" "$DEMO_PID" --data-dir "$WORK/data"
for _ in $(seq 1 160); do grep -q '^DONE' "$WORK/out/report.txt" 2>/dev/null && break; sleep 0.5; done
[ -f "$WORK/out/report.txt" ] || { echo "no report after 80 s"; pkill -x Flit || true; exit 1; }
pkill -x Flit || true
cat "$WORK/out/report.txt"
cp "$WORK"/out/*.png docs/screenshots/ 2>/dev/null || true
ls -la docs/screenshots

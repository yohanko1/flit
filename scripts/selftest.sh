#!/bin/bash
# End-to-end self-test: builds a debug Flit, opens a throwaway probe window,
# and lets Flit press its own hotkeys against it. Takes about three minutes;
# do not type or switch apps while it runs. Prints the report and exits
# non-zero on any failure. Pass a section name to run only that part
# (`scripts/selftest.sh dimming`, about 15 s). Run `make install` (or
# `make run`) afterwards to go back to the release build.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'touch "$WORK/text.quit"; sleep 0.5; rm -rf "$WORK"' EXIT

scripts/build-app.sh debug
swiftc -O -o "$WORK/probe" scripts/selftest/Probe.swift
: > "$WORK/text"
"$WORK/probe" "$WORK/text" > "$WORK/probe.out" &
for _ in $(seq 1 50); do grep -q '^PID ' "$WORK/probe.out" 2>/dev/null && break; sleep 0.2; done
PROBE_PID="$(awk '/^PID /{print $2}' "$WORK/probe.out")"
[ -n "$PROBE_PID" ] || { echo "probe did not start"; exit 1; }

pkill -x Flit || true
sleep 0.8
open -n build/Flit.app --args --selftest "$WORK/report" "$PROBE_PID" "$WORK/text" ${1:+"$1"}
for _ in $(seq 1 240); do [ -s "$WORK/report" ] && break; sleep 0.5; done
[ -s "$WORK/report" ] || { echo "no report after 120 s"; exit 1; }
cat "$WORK/report"
grep -q '^RESULT: .* 0 failed$' "$WORK/report"

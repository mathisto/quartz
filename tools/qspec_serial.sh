#!/usr/bin/env bash
# Sequential QSpec runner with a hard per-spec timeout.
# Sidesteps the parallel qspec scheduler (worker-starvation hangs, see
# docs/handoff/2026-05-09-qspec-scheduler-mystery.md): each spec is a
# bounded subprocess, so the whole run can never hang — a stuck spec is
# killed after TIMEOUT and recorded as TIMEOUT, then the run continues.
#
# Slower than `quake qspec` (no shared cache / no parallelism) but reliable.
# Usage:  tools/qspec_serial.sh [TIMEOUT_SECONDS]   (default 60)
set -u
cd "$(dirname "$0")/.."
TIMEOUT="${1:-60}"
PASS=0; FAIL=0; TO=0
FAILED=""; TIMEDOUT=""
LOG="/tmp/qspec_serial.$(date +%s).log"
: > "$LOG"
specs=(spec/qspec/*_spec.qz)
total=${#specs[@]}
i=0
for f in "${specs[@]}"; do
  i=$((i+1))
  name=$(basename "$f" .qz)
  out=$(timeout "$TIMEOUT" bash -c "FILE=$f ./self-hosted/bin/quake qspec_file" 2>&1)
  rc=$?
  # Classify by genuine failure markers, NOT by presence of "All green":
  # specs that skip all tests (e.g. wasm_* need a --feature wasm compiler)
  # emit "[skip] ... PASS (Nms)" with no "All green" line — those are PASSES.
  # A real failure shows a qspec "✗"/"FAILURES:" line, a qspec_file
  # "FAILED:" (llc/link error), a compiler "error[QZ..." diagnostic, or a crash.
  if [ $rc -eq 124 ]; then
    TO=$((TO+1)); TIMEDOUT="$TIMEDOUT $name"
    printf '[%3d/%3d] TIMEOUT  %s\n' "$i" "$total" "$name" | tee -a "$LOG"
  elif echo "$out" | grep -qE 'FAILURES:|✗|FAILED:|error\[QZ|Segmentation fault'; then
    FAIL=$((FAIL+1)); FAILED="$FAILED $name"
    printf '[%3d/%3d] FAIL     %s\n' "$i" "$total" "$name" | tee -a "$LOG"
    echo "$out" | grep -iE "fail|✗|error|segm" | head -3 | sed 's/^/        /' | tee -a "$LOG"
  else
    PASS=$((PASS+1))
    printf '[%3d/%3d] pass     %s\n' "$i" "$total" "$name" >> "$LOG"
  fi
done
echo "=============================================="
echo "RESULT: $PASS passed, $FAIL failed, $TO timed out  (of $total)"
[ -n "$FAILED" ]   && echo "FAILED: $FAILED"
[ -n "$TIMEDOUT" ] && echo "TIMEOUT:$TIMEDOUT"
echo "Full log: $LOG"
echo ""
echo "NOTE: timeouts are almost always slow-lane concurrency/network/TLS specs"
echo "  (IR contains @qz_spawn / @__qz_sched_init / SSL_CTX_new / httpbin) that"
echo "  hit worker-starvation when run standalone — verify those via the parallel"
echo "  'quake qspec' runner, not here. Treat only FAILED as actionable."

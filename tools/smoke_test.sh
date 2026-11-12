#!/usr/bin/env bash
# Compiler Smoke Tests
#
# Run after every `quake guard`. Catches semantic regressions that
# fixpoint alone misses — a subtly broken compiler can produce
# byte-identical IR from broken source forever, but compiled
# programs that exercise real language features will misbehave.
#
# Currently runs:
#   1. examples/brainfuck.qz       — 30+ language features, all 4 tests must pass
#   2. examples/expr_eval.qz       — 22 Tier-3 feature tests; full run expected.
#                                    Output verified against a baseline; any
#                                    divergence = regression.
#
# Usage:
#   tools/smoke_test.sh            # run smoke tests
#   tools/smoke_test.sh --update   # update expr_eval baseline (after a fix)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUARTZ="$REPO_ROOT/self-hosted/bin/quartz"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

FAILED=0

# ----------------------------------------------------------------------
# Test 1: brainfuck.qz — 4/4 tests must pass
# ----------------------------------------------------------------------
echo "==> brainfuck.qz"

if ! "$QUARTZ" "$REPO_ROOT/examples/brainfuck.qz" 2>/dev/null > "$TMP/bf.ll"; then
  echo "  FAIL: compile error" >&2
  FAILED=1
elif ! llc -filetype=obj "$TMP/bf.ll" -o "$TMP/bf.o" 2>/dev/null; then
  echo "  FAIL: llc error" >&2
  FAILED=1
elif ! clang "$TMP/bf.o" -o "$TMP/bf" -lm -lpthread 2>/dev/null; then
  echo "  FAIL: link error" >&2
  FAILED=1
else
  BF_OUT=$("$TMP/bf" 2>&1)
  if echo "$BF_OUT" | grep -qE "^  4 passed, 0 failed$"; then
    echo "  OK: 4/4 tests passed"
  else
    echo "  FAIL: did not see '4 passed, 0 failed'" >&2
    echo "$BF_OUT" | tail -10 >&2
    FAILED=1
  fi
fi

# ----------------------------------------------------------------------
# Test 2: expr_eval.qz — full 22/22 PASS run (MULTI-CLAUSE-1 resolved)
# ----------------------------------------------------------------------
echo "==> expr_eval.qz"

BASELINE="$REPO_ROOT/spec/snapshots/expr_eval_baseline.txt"

if ! "$QUARTZ" "$REPO_ROOT/examples/expr_eval.qz" 2>/dev/null > "$TMP/ee.ll"; then
  echo "  FAIL: compile error" >&2
  FAILED=1
elif ! llc -filetype=obj "$TMP/ee.ll" -o "$TMP/ee.o" 2>/dev/null; then
  echo "  FAIL: llc error" >&2
  FAILED=1
elif ! clang "$TMP/ee.o" -o "$TMP/ee" -lm -lpthread 2>/dev/null; then
  echo "  FAIL: link error" >&2
  FAILED=1
else
  # stdbuf -o0 so partial output before the crash actually flushes
  stdbuf -o0 "$TMP/ee" > "$TMP/ee_out.txt" 2>&1 || true

  if [ "${1:-}" = "--update" ]; then
    cp "$TMP/ee_out.txt" "$BASELINE"
    echo "  Updated baseline at $BASELINE"
    cat "$BASELINE"
  elif [ ! -f "$BASELINE" ]; then
    echo "  WARN: baseline not found at $BASELINE" >&2
    echo "  Run: tools/smoke_test.sh --update" >&2
    echo "  Current output:" >&2
    cat "$TMP/ee_out.txt" >&2
    FAILED=1
  elif diff -q "$BASELINE" "$TMP/ee_out.txt" > /dev/null 2>&1; then
    LINES=$(wc -l < "$BASELINE" | tr -d ' ')
    echo "  OK: matches baseline ($LINES lines, full 22/22 pass)"
  else
    echo "  FAIL: expr_eval output diverged from baseline" >&2
    echo "  Diff (baseline vs current):" >&2
    diff -u "$BASELINE" "$TMP/ee_out.txt" >&2 || true
    echo "" >&2
    echo "  If this is intentional (e.g. new test added)," >&2
    echo "  regenerate the baseline:" >&2
    echo "    tools/smoke_test.sh --update" >&2
    FAILED=1
  fi
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "All smoke tests OK"
  exit 0
else
  echo "Smoke tests FAILED" >&2
  exit 1
fi

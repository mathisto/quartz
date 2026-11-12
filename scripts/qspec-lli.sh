#!/bin/bash
# QSpec runner using lli (LLVM JIT interpreter)
# Bypasses native compilation which hangs on LLVM 21
set -euo pipefail

COMPILER="./self-hosted/bin/quartz"
LLI="/opt/homebrew/opt/llvm@20/bin/lli"
TIMEOUT="${QSPEC_TIMEOUT:-60}"

# Set env vars for subprocess tests inside test binaries
export QUARTZ_COMPILER="$COMPILER"
export QUARTZ_STD="std"
export QUARTZ_LLI="$LLI"
export QUARTZ_FIXTURES="spec/qspec/fixtures"
export PATH="/opt/homebrew/opt/llvm/bin:$PATH"

if [ ! -x "$COMPILER" ]; then
  echo "Error: compiler not found at $COMPILER" >&2
  exit 1
fi
if [ ! -x "$LLI" ]; then
  echo "Error: lli not found at $LLI" >&2
  exit 1
fi

passed=0
failed=0
failed_names=""
total=0
skipped=0

for spec in spec/qspec/*_spec.qz; do
  name=$(basename "$spec" .qz)
  total=$((total + 1))
  ir="/tmp/_qspec_lli_${name}.ll"
  out="/tmp/_qspec_lli_${name}.out"
  err="/tmp/_qspec_lli_${name}.err"

  # Step 1: Compile
  if ! "$COMPILER" --no-cache -I std -I . -I self-hosted/shared -I spec/qspec/fixtures "$spec" > "$ir" 2>"$err"; then
    printf "\033[31mC\033[0m" >&2
    failed=$((failed + 1))
    failed_names="$failed_names\n  $name: compile error"
    rm -f "$ir" "$err"
    continue
  fi

  # Step 2: Check if test needs native (scheduler init = can't use lli)
  if grep -q 'call void @__qz_sched_init(' "$ir" 2>/dev/null; then
    printf "\033[33m-\033[0m" >&2
    skipped=$((skipped + 1))
    rm -f "$ir" "$err"
    continue
  fi

  # Step 3: Run via lli with timeout
  if timeout "$TIMEOUT" "$LLI" "$ir" > "$out" 2>&1; then
    printf "\033[32m.\033[0m" >&2
    passed=$((passed + 1))
  else
    exit_code=$?
    if [ $exit_code -eq 124 ]; then
      printf "\033[33mT\033[0m" >&2
      failed_names="$failed_names\n  $name: TIMEOUT (>${TIMEOUT}s)"
    elif [ $exit_code -eq 139 ] || [ $exit_code -eq 134 ]; then
      printf "\033[31mS\033[0m" >&2
      failed_names="$failed_names\n  $name: SIGSEGV/SIGABRT"
    else
      printf "\033[31mF\033[0m" >&2
      failed_names="$failed_names\n  $name: exit $exit_code"
    fi
    failed=$((failed + 1))
  fi

  rm -f "$ir" "$err" "$out"
done

echo "" >&2
echo "" >&2
echo "QSpec (lli): $passed/$total passed, $skipped skipped (scheduler)" >&2

if [ $failed -gt 0 ]; then
  echo "" >&2
  echo "Failures:" >&2
  printf "$failed_names\n" >&2
  exit 1
fi

#!/usr/bin/env bash
# Quartz Benchmark Runner
# Usage: bash benchmarks/run.sh [--hyperfine] [--compile-only]
#
# Compiles and runs all Quartz and C benchmarks.
# Uses hyperfine for statistical measurement if available and --hyperfine flag is set.
# Otherwise falls back to 'time'.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="/tmp/quartz_bench"

QUARTZ_COMPILER="${QUARTZ_COMPILER:-$PROJECT_DIR/self-hosted/bin/quartz}"
LLC="${LLC:-$(command -v llc 2>/dev/null || echo /opt/homebrew/opt/llvm/bin/llc)}"
OPT="${OPT:-$(command -v opt 2>/dev/null || echo /opt/homebrew/opt/llvm/bin/opt)}"
CC="${CC:-cc}"

USE_HYPERFINE=0
COMPILE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --hyperfine)
      if command -v hyperfine &>/dev/null; then
        USE_HYPERFINE=1
      else
        echo "Warning: hyperfine not found, falling back to time"
      fi
      ;;
    --compile-only)
      COMPILE_ONLY=1
      ;;
  esac
done

mkdir -p "$BUILD_DIR"

# =============================================================================
# Compilation
# =============================================================================

compile_quartz() {
  local name="$1"
  local src="$2"
  echo "  Compiling Quartz: $name..."
  "$QUARTZ_COMPILER" "$src" > "$BUILD_DIR/${name}.ll" 2>/dev/null
  "$OPT" -O2 -S "$BUILD_DIR/${name}.ll" -o "$BUILD_DIR/${name}.opt.ll"
  "$LLC" -O2 -filetype=obj -o "$BUILD_DIR/${name}.o" "$BUILD_DIR/${name}.opt.ll"
  "$CC" -O2 "$BUILD_DIR/${name}.o" -o "$BUILD_DIR/${name}_qz" -lm
}

compile_c() {
  local name="$1"
  local src="$2"
  echo "  Compiling C: $name..."
  "$CC" -O2 -o "$BUILD_DIR/${name}_c" "$src" -lm
}

# =============================================================================
# Benchmark pairs: [name, quartz_source, c_source]
# =============================================================================

declare -a BENCHMARKS=(
  "fibonacci:$SCRIPT_DIR/fibonacci/fib.qz:$SCRIPT_DIR/fibonacci/fib.c"
  "sum:$SCRIPT_DIR/sum/sum.qz:$SCRIPT_DIR/sum/sum.c"
  "sieve:$SCRIPT_DIR/sieve/sieve.qz:$SCRIPT_DIR/sieve/sieve.c"
  "matrix:$SCRIPT_DIR/matrix/matrix.qz:$SCRIPT_DIR/matrix/matrix.c"
  "string_concat:$SCRIPT_DIR/string_concat/concat.qz:$SCRIPT_DIR/string_concat/concat.c"
  "binary_trees:$SCRIPT_DIR/binary_trees/trees.qz:$SCRIPT_DIR/binary_trees/trees.c"
  "binary_trees_bump:$SCRIPT_DIR/binary_trees/trees_bump.qz:$SCRIPT_DIR/binary_trees/trees_bump.c"
  "nbody:$SCRIPT_DIR/nbody/nbody.qz:$SCRIPT_DIR/nbody/nbody.c"
  "hash_map_bench:$SCRIPT_DIR/hash_map_bench.qz:$SCRIPT_DIR/c/hash_map_bench.c"
  "linked_list:$SCRIPT_DIR/linked_list.qz:$SCRIPT_DIR/c/linked_list.c"
  "json_parse:$SCRIPT_DIR/json_parse/json_parse.qz:$SCRIPT_DIR/c/json_parse.c"
  "struct_heavy:$SCRIPT_DIR/struct_heavy/struct_heavy.qz:$SCRIPT_DIR/struct_heavy/struct_heavy.c"
)

# =============================================================================
# Compile all
# =============================================================================

echo "=== Compiling benchmarks ==="
for bench in "${BENCHMARKS[@]}"; do
  IFS=: read -r name qz_src c_src <<< "$bench"
  if [[ -f "$qz_src" ]]; then
    compile_quartz "$name" "$qz_src"
  else
    echo "  SKIP (no source): $qz_src"
  fi
  if [[ -f "$c_src" ]]; then
    compile_c "$name" "$c_src"
  else
    echo "  SKIP (no source): $c_src"
  fi
done

echo ""

if [[ "$COMPILE_ONLY" == "1" ]]; then
  echo "=== Compile-only mode: skipping benchmark runs ==="
  exit 0
fi

# =============================================================================
# Run benchmarks
# =============================================================================

run_bench() {
  local label="$1"
  local binary="$2"

  if [[ ! -x "$binary" ]]; then
    echo "  SKIP: $binary not found"
    return
  fi

  if [[ "$USE_HYPERFINE" == "1" ]]; then
    hyperfine --warmup 1 --min-runs 5 --export-markdown /dev/null "$binary" 2>&1 | head -3
  else
    echo -n "  $label: "
    { time "$binary" > /dev/null 2>&1 ; } 2>&1 | grep real | awk '{print $2}'
  fi
}

echo "=== Running benchmarks ==="
echo ""

if [[ "$USE_HYPERFINE" == "1" ]]; then
  echo "Using hyperfine for measurement"
  echo ""
  for bench in "${BENCHMARKS[@]}"; do
    IFS=: read -r name qz_src c_src <<< "$bench"
    echo "--- $name ---"
    qz_bin="$BUILD_DIR/${name}_qz"
    c_bin="$BUILD_DIR/${name}_c"
    if [[ -x "$qz_bin" && -x "$c_bin" ]]; then
      hyperfine --warmup 1 --min-runs 5 \
        --command-name "Quartz" "$qz_bin" \
        --command-name "C" "$c_bin"
    else
      [[ -x "$qz_bin" ]] && hyperfine --warmup 1 --min-runs 5 "$qz_bin"
      [[ -x "$c_bin" ]] && hyperfine --warmup 1 --min-runs 5 "$c_bin"
    fi
    echo ""
  done
else
  echo "Using time for measurement (install hyperfine for better stats)"
  echo ""
  printf "%-20s %-15s %-15s %-15s %-15s\n" "Benchmark" "Quartz" "C" "QZ RSS(KB)" "C RSS(KB)"
  printf "%-20s %-15s %-15s %-15s %-15s\n" "---------" "------" "-" "---------" "--------"
  for bench in "${BENCHMARKS[@]}"; do
    IFS=: read -r name qz_src c_src <<< "$bench"
    qz_bin="$BUILD_DIR/${name}_qz"
    c_bin="$BUILD_DIR/${name}_c"

    qz_time="N/A"
    c_time="N/A"
    qz_rss="N/A"
    c_rss="N/A"

    if [[ -x "$qz_bin" ]]; then
      qz_time=$( { time "$qz_bin" > /dev/null 2>&1 ; } 2>&1 | grep real | awk '{print $2}' )
      # Peak RSS via /usr/bin/time -l (macOS) — field 6 is max RSS in bytes
      if [[ "$(uname)" == "Darwin" ]]; then
        qz_rss=$( /usr/bin/time -l "$qz_bin" > /dev/null 2>&1 2>&1 | grep 'maximum resident' | awk '{print int($1/1024)}' )
      fi
    fi
    if [[ -x "$c_bin" ]]; then
      c_time=$( { time "$c_bin" > /dev/null 2>&1 ; } 2>&1 | grep real | awk '{print $2}' )
      if [[ "$(uname)" == "Darwin" ]]; then
        c_rss=$( /usr/bin/time -l "$c_bin" > /dev/null 2>&1 2>&1 | grep 'maximum resident' | awk '{print int($1/1024)}' )
      fi
    fi

    printf "%-20s %-15s %-15s %-15s %-15s\n" "$name" "$qz_time" "$c_time" "${qz_rss:-N/A}" "${c_rss:-N/A}"
  done
fi

echo ""
echo "=== Done ==="

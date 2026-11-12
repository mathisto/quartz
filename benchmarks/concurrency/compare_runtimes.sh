#!/bin/bash
# Cross-runtime scheduler benchmark comparison: Quartz vs Go vs Erlang/OTP
#
# Usage: ./benchmarks/concurrency/compare_runtimes.sh [SCENARIO]
# If SCENARIO given, runs only that scenario. Otherwise runs all 8.

set -e

SCENARIOS="spawn_rate channel_throughput fanout_fanin contention steal_throughput wake_burst scalability_curve memory_efficiency"
FILTER="${1:-}"

BENCH_DIR="benchmarks/concurrency"
TMP="/tmp/_runtime_compare"
mkdir -p "$TMP"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Check toolchains
HAVE_GO=0
HAVE_ERL=0
HAVE_QZ=0

if command -v go &>/dev/null; then HAVE_GO=1; fi
if command -v erlc &>/dev/null; then HAVE_ERL=1; fi
if [ -x ./self-hosted/bin/quartz ]; then HAVE_QZ=1; fi

echo -e "${BOLD}=== Cross-Runtime Scheduler Benchmark ===${RESET}"
echo -e "${DIM}Quartz $([ $HAVE_QZ -eq 1 ] && echo '✓' || echo '✗')  |  Go $([ $HAVE_GO -eq 1 ] && echo '✓' || echo '✗')  |  Erlang/OTP $([ $HAVE_ERL -eq 1 ] && echo '✓' || echo '✗')${RESET}"
echo ""

# Metric extraction: parse BENCH:scenario:metric:value lines
extract_metric() {
    local output="$1" scenario="$2" metric="$3"
    echo "$output" | grep "^BENCH:${scenario}:${metric}:" | head -1 | cut -d: -f4
}

format_rate() {
    local val="$1"
    if [ -z "$val" ] || [ "$val" = "0" ]; then
        echo "—"
    elif [ "$val" -ge 1000000000 ] 2>/dev/null; then
        echo "$((val / 1000000000)).$((val % 1000000000 / 100000000))B"
    elif [ "$val" -ge 1000000 ] 2>/dev/null; then
        echo "$((val / 1000000)).$((val % 1000000 / 100000))M"
    elif [ "$val" -ge 1000 ] 2>/dev/null; then
        echo "$((val / 1000)).$((val % 1000 / 100))K"
    else
        echo "$val"
    fi
}

# Header
printf "${BOLD}%-22s %12s %12s %12s   %-6s${RESET}\n" "Scenario" "Quartz" "Go" "Erlang" "Unit"
printf "%-22s %12s %12s %12s   %-6s\n" "----------------------" "------------" "------------" "------------" "------"

for scenario in $SCENARIOS; do
    if [ -n "$FILTER" ] && [ "$scenario" != "$FILTER" ]; then
        continue
    fi

    QZ_VAL="" GO_VAL="" ERL_VAL=""

    # Determine primary metric for this scenario
    case "$scenario" in
        spawn_rate|steal_throughput) METRIC="tasks_per_sec"; UNIT="tasks/s" ;;
        channel_throughput) METRIC="msgs_per_sec"; UNIT="msgs/s" ;;
        fanout_fanin) METRIC="items_per_sec"; UNIT="items/s" ;;
        contention) METRIC="ops_per_sec"; UNIT="ops/s" ;;
        wake_burst) METRIC="wakes_per_sec"; UNIT="wakes/s" ;;
        scalability_curve) METRIC="efficiency_x1000"; UNIT="eff×1K" ;;
        memory_efficiency) METRIC="bytes_per_task"; UNIT="B/task" ;;
    esac

    # --- Quartz ---
    if [ $HAVE_QZ -eq 1 ] && [ -f "$BENCH_DIR/${scenario}.qz" ]; then
        export PATH="/opt/homebrew/opt/llvm/bin:$PATH"
        ./self-hosted/bin/quartz --no-cache -I std -I . "$BENCH_DIR/${scenario}.qz" > "$TMP/${scenario}.ll" 2>/dev/null && \
        llc -filetype=obj "$TMP/${scenario}.ll" -o "$TMP/${scenario}.o" 2>/dev/null && \
        clang "$TMP/${scenario}.o" -o "$TMP/qz_${scenario}" -lpthread 2>/dev/null || true
        if [ -f "$TMP/qz_${scenario}" ]; then
            QZ_OUT=$(timeout 60 "$TMP/qz_${scenario}" 2>&1 || true)
            QZ_VAL=$(extract_metric "$QZ_OUT" "$scenario" "$METRIC")
        fi
    fi

    # --- Go ---
    if [ $HAVE_GO -eq 1 ] && [ -f "$BENCH_DIR/${scenario}.go" ]; then
        go build -o "$TMP/go_${scenario}" "$BENCH_DIR/${scenario}.go" 2>/dev/null
        if [ -f "$TMP/go_${scenario}" ]; then
            GO_OUT=$(timeout 30 "$TMP/go_${scenario}" 2>/dev/null || true)
            GO_VAL=$(extract_metric "$GO_OUT" "$scenario" "$METRIC")
        fi
    fi

    # --- Erlang ---
    if [ $HAVE_ERL -eq 1 ] && [ -f "$BENCH_DIR/${scenario}.erl" ]; then
        erlc -o "$TMP" "$BENCH_DIR/${scenario}.erl" 2>/dev/null
        if [ -f "$TMP/${scenario}.beam" ]; then
            ERL_OUT=$(timeout 60 erl -noshell -pa "$TMP" -eval "${scenario}:main()." 2>/dev/null || true)
            ERL_VAL=$(extract_metric "$ERL_OUT" "$scenario" "$METRIC")
        fi
    fi

    # Format and print row
    QZ_FMT=$(format_rate "$QZ_VAL")
    GO_FMT=$(format_rate "$GO_VAL")
    ERL_FMT=$(format_rate "$ERL_VAL")

    # Highlight winner in green
    BEST=""
    if [ "$scenario" = "memory_efficiency" ]; then
        # Lower is better for memory
        if [ -n "$QZ_VAL" ] && [ -n "$GO_VAL" ] && [ -n "$ERL_VAL" ]; then
            if [ "$QZ_VAL" -le "$GO_VAL" ] 2>/dev/null && [ "$QZ_VAL" -le "$ERL_VAL" ] 2>/dev/null; then
                BEST="qz"
            elif [ "$GO_VAL" -le "$QZ_VAL" ] 2>/dev/null && [ "$GO_VAL" -le "$ERL_VAL" ] 2>/dev/null; then
                BEST="go"
            else
                BEST="erl"
            fi
        fi
    else
        # Higher is better for rate metrics
        if [ -n "$QZ_VAL" ] && [ -n "$GO_VAL" ] && [ -n "$ERL_VAL" ]; then
            if [ "$QZ_VAL" -ge "$GO_VAL" ] 2>/dev/null && [ "$QZ_VAL" -ge "$ERL_VAL" ] 2>/dev/null; then
                BEST="qz"
            elif [ "$GO_VAL" -ge "$QZ_VAL" ] 2>/dev/null && [ "$GO_VAL" -ge "$ERL_VAL" ] 2>/dev/null; then
                BEST="go"
            else
                BEST="erl"
            fi
        fi
    fi

    # Apply colors
    if [ "$BEST" = "qz" ]; then QZ_FMT="${GREEN}${QZ_FMT}${RESET}"; fi
    if [ "$BEST" = "go" ]; then GO_FMT="${GREEN}${GO_FMT}${RESET}"; fi
    if [ "$BEST" = "erl" ]; then ERL_FMT="${GREEN}${ERL_FMT}${RESET}"; fi

    printf "%-22s %20b %20b %20b   %-6s\n" "$scenario" "$QZ_FMT" "$GO_FMT" "$ERL_FMT" "$UNIT"
done

echo ""
echo -e "${DIM}Green = best in category. Memory: lower is better. Everything else: higher is better.${RESET}"

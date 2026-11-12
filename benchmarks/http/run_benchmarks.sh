#!/bin/bash
# HTTP Server Benchmark Suite
# Compares all Quartz server modes + Go baseline
# Usage: ./benchmarks/http/run_benchmarks.sh [sweep|brutal|churn|all]

set -e
cd "$(dirname "$0")/../.."

QUARTZ=./self-hosted/bin/quartz
LLC="$(brew --prefix llvm 2>/dev/null || echo /opt/homebrew/opt/llvm)/bin/llc"
OPENSSL_LIB="$(brew --prefix openssl 2>/dev/null || echo /opt/homebrew/opt/openssl)/lib"
BUILD_DIR=/tmp/quartz_bench

mkdir -p $BUILD_DIR

# --- Build helpers ---
build_quartz() {
  local src=$1 name=$2
  echo "  Building $name..."
  $QUARTZ --no-cache -I std -I . "$src" > "$BUILD_DIR/${name}.ll" 2>&1
  # Strip duplicate declaration bug
  python3 -c "
lines = open('$BUILD_DIR/${name}.ll').readlines()
out = [l for l in lines if l.strip() != 'declare i64 @__qz_alpn_cb_ptr()']
open('$BUILD_DIR/${name}.ll','w').writelines(out)
"
  $LLC -O2 -filetype=obj -o "$BUILD_DIR/${name}.o" "$BUILD_DIR/${name}.ll" 2>&1
  clang -O2 "$BUILD_DIR/${name}.o" -o "$BUILD_DIR/$name" -lpthread -L"$OPENSSL_LIB" -lssl -lcrypto 2>&1
  echo "  OK: $BUILD_DIR/$name"
}

build_go() {
  echo "  Building go_server..."
  go build -o "$BUILD_DIR/go_server" benchmarks/http/plaintext_server.go 2>&1
  echo "  OK: $BUILD_DIR/go_server"
}

kill_servers() {
  pkill -f "$BUILD_DIR/" 2>/dev/null || true
  sleep 1
  for port in 18080 18081 18082 18083 18084; do
    lsof -ti:$port 2>/dev/null | xargs kill -9 2>/dev/null || true
  done
  sleep 1
}

start_server() {
  local bin=$1 name=$2
  $bin &
  local PID=$!
  sleep 2
  echo $PID
}

extract_metrics() {
  local output="$1"
  local rps=$(echo "$output" | grep 'http_reqs\b' | grep -oE '[0-9]+\.[0-9]+/s' | head -1)
  local p50=$(echo "$output" | grep 'http_req_duration' | head -1 | grep -oE 'med=[^ ]+' | sed 's/med=//')
  local p95=$(echo "$output" | grep 'http_req_duration' | head -1 | grep -oE 'p\(95\)=[^ ]+' | sed 's/p(95)=//')
  local errs=$(echo "$output" | grep 'http_req_failed' | grep -oE '[0-9]+\.[0-9]+%' | head -1)
  local total=$(echo "$output" | grep 'http_reqs\b' | grep -oE '[0-9]+ ' | head -1 | tr -d ' ')
  echo "$rps|$p50|$p95|$errs|$total"
}

run_k6() {
  local name=$1 port=$2 script=$3 extra_env=$4
  echo ""
  echo "  Running k6 against $name (:$port)..."
  local OUTPUT=$(k6 run --quiet --env TARGET=http://localhost:$port $extra_env "$script" 2>&1)
  local METRICS=$(extract_metrics "$OUTPUT")
  IFS='|' read -r rps p50 p95 errs total <<< "$METRICS"
  printf "  %-30s %12s  %10s  %10s  %8s  %10s\n" "$name" "$rps" "$p50" "$p95" "$errs" "$total"
}

# --- Main ---
MODE=${1:-all}

echo "=============================================="
echo "  Quartz HTTP Benchmark Suite"
echo "=============================================="
echo ""
echo "Building servers..."
build_quartz benchmarks/http/sync_server.qz bench_sync
build_quartz benchmarks/http/async_server.qz bench_async
build_quartz benchmarks/http/mn_server.qz bench_mn
build_quartz benchmarks/http/mn_keepalive_server.qz bench_mn_ka
build_go
echo ""

if [ "$MODE" = "compare" ] || [ "$MODE" = "all" ]; then
  echo "=============================================="
  echo "  HEAD-TO-HEAD COMPARISON (ramp to 3k VUs)"
  echo "=============================================="
  printf "  %-30s %12s  %10s  %10s  %8s  %10s\n" "SERVER" "REQ/S" "p50" "p95" "ERRORS" "TOTAL"
  printf "  %-30s %12s  %10s  %10s  %8s  %10s\n" "------" "-----" "---" "---" "------" "-----"

  kill_servers
  start_server "$BUILD_DIR/bench_sync" "sync" > /dev/null
  run_k6 "Quartz sync" 18080 benchmarks/http/k6_compare.js
  kill_servers

  start_server "$BUILD_DIR/bench_async" "async" > /dev/null
  run_k6 "Quartz async" 18082 benchmarks/http/k6_compare.js
  kill_servers

  start_server "$BUILD_DIR/bench_mn" "mn" > /dev/null
  run_k6 "Quartz M:N" 18083 benchmarks/http/k6_compare.js
  kill_servers

  start_server "$BUILD_DIR/bench_mn_ka" "mn_ka" > /dev/null
  run_k6 "Quartz M:N keepalive" 18084 benchmarks/http/k6_compare.js
  kill_servers

  start_server "$BUILD_DIR/go_server" "go" > /dev/null
  run_k6 "Go net/http" 18081 benchmarks/http/k6_compare.js
  kill_servers
  echo ""
fi

if [ "$MODE" = "brutal" ] || [ "$MODE" = "all" ]; then
  echo "=============================================="
  echo "  BRUTAL TEST — 10k VUs (M:N keepalive vs Go)"
  echo "=============================================="
  printf "  %-30s %12s  %10s  %10s  %8s  %10s\n" "SERVER" "REQ/S" "p50" "p95" "ERRORS" "TOTAL"
  printf "  %-30s %12s  %10s  %10s  %8s  %10s\n" "------" "-----" "---" "---" "------" "-----"

  kill_servers
  start_server "$BUILD_DIR/bench_mn_ka" "mn_ka" > /dev/null
  run_k6 "Quartz M:N keepalive" 18084 benchmarks/http/k6_brutal.js
  kill_servers

  start_server "$BUILD_DIR/go_server" "go" > /dev/null
  run_k6 "Go net/http" 18081 benchmarks/http/k6_brutal.js "--env TARGET=http://localhost:18081"
  kill_servers
  echo ""
fi

if [ "$MODE" = "churn" ] || [ "$MODE" = "all" ]; then
  echo "=============================================="
  echo "  CONNECTION CHURN (no keepalive, 3k VUs)"
  echo "=============================================="
  printf "  %-30s %12s  %10s  %10s  %8s  %10s\n" "SERVER" "REQ/S" "p50" "p95" "ERRORS" "TOTAL"
  printf "  %-30s %12s  %10s  %10s  %8s  %10s\n" "------" "-----" "---" "---" "------" "-----"

  kill_servers
  start_server "$BUILD_DIR/bench_mn_ka" "mn_ka" > /dev/null
  run_k6 "Quartz M:N keepalive" 18084 benchmarks/http/k6_no_keepalive.js
  kill_servers

  start_server "$BUILD_DIR/go_server" "go" > /dev/null
  run_k6 "Go net/http" 18081 benchmarks/http/k6_no_keepalive.js "--env TARGET=http://localhost:18081"
  kill_servers
  echo ""
fi

echo "=============================================="
echo "  DONE"
echo "=============================================="

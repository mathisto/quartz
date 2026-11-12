#!/usr/bin/env bash
# C-ABI struct-by-value oracle (B.10 Phase 3, MEMORY_MODEL_V3 §13.9).
#
# Fixpoint and `opt -verify` BOTH pass on ABI-wrong IR, so the ONLY real check
# that the struct-by-value calling convention matches the platform C ABI is to
# link Quartz against real C, compiled by the system C compiler, and run it.
#
# Two directions:
#   callee (P3.1a/b): a C driver calls Quartz `extern "C"` functions that take
#                     AND return small int/double structs by value.
#   caller (P3.1c):   a Quartz `main` calls C functions that take AND return
#                     small int/double structs by value.
# Pass = each direction's stdout matches EXPECT and exits 0.
#
# HOST (native) usage:    spec/c_abi/run.sh
# SysV cross-check usage:  spec/c_abi/run.sh --sysv lovelace
#   Cross-`llc` the x86_64 IR here, ship the ELF object to a real x86_64 box,
#   link + run there with -no-pie.
set -euo pipefail
cd "$(dirname "$0")/../.."
QZ=./self-hosted/bin/quartz
DIR=spec/c_abi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

EXPECT="pair_sum=13 pair_diff=7 v2_ok=1 mix_ok=1 ret_ok=1 ALL=1"
# P3.3 — large (>16B) structs: indirect byval params + sret returns, both dirs.
EXPECT_LARGE="p3_sum=60 quad_sum=10 big6_ok=1 m3_ok=1 ret_ok=1 ALL=1"
EXPECT_LARGE_CALLEE="p3_sum=60 big6_ok=1 m3_ok=1 ret_ok=1 ALL=1"
# P3.4a — narrow-integer (sub-8-byte) packed structs, both directions.
EXPECT_NARROW="v2i=13 rgba=10 i16=123 pixel=1 tri=18 ret_ok=1 ALL=1"
EXPECT_NARROW_CALLEE="v2i=13 rgba=10 tri=18 pixel=1 ret_ok=1 ALL=1"
# P3.4b — F32 (`float`) structs: boundary-repack (fptrunc/fpext), both directions.
EXPECT_FLOAT="v2f=16 v3f=18 v4f=21 mixf=1 fmix=1 ret_ok=1 ALL=1"
EXPECT_FLOAT_CALLEE="v2f=16 v3f=18 v4f=21 mixf=1 fmix=1 ret_ok=1 ALL=1"
# P3.4-ii-a — >16B narrow-packed structs: true-size %struct.T byval/sret, both dirs.
EXPECT_LNARROW="n6_sum=21 nw_sum=1024 ret_ok=1 ALL=1"
EXPECT_LNARROW_CALLEE="n6_sum=21 nw_sum=1024 ret_ok=1 ALL=1"
# P3.4-ii-b — >16B F32 structs: C-layout %struct.T.cabi byval/sret + repack, both dirs.
EXPECT_LFLOAT="f6=26 fmix6=1 fw=1 ret_ok=1 ALL=1"
EXPECT_LFLOAT_CALLEE="f6=26 fmix6=1 fw=1 ret_ok=1 ALL=1"
# B.11b @cImport — bindings auto-generated from a C header via clang AST dump.
EXPECT_CIMPORT="addi=42 point=3,4 vscale=60,80 dscale=100 counter=300 status=106,100 mode=20 macros=83 label=ci alias=33 span=60 ALL=1"
EXPECT_REPRC="pt_ret=3,4 pt_sum=7,30 v2f_sum=16 vx=6 vy=10 ALL=1"

# --- callee direction (C -> Quartz): C main calls Quartz extern fns ----------
run_host_callee() {
  echo "== callee C->Qz, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_params_callee.qz" > "$TMP/callee.ll"
  llc -filetype=obj "$TMP/callee.ll" -o "$TMP/callee.o"
  clang -c "$DIR/struct_params_driver.c" -o "$TMP/driver.o"
  clang "$TMP/callee.o" "$TMP/driver.o" -o "$TMP/abitest" -lm -lpthread
  local out; out="$("$TMP/abitest")"
  echo "  $out"
  [[ "$out" == "$EXPECT" ]] || { echo "  FAIL: expected '$EXPECT'"; exit 1; }
  echo "  PASS"
}

# --- caller direction (Quartz -> C): Quartz main calls C fns -----------------
run_host_caller() {
  echo "== caller Qz->C, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_call_main.qz" > "$TMP/main.ll"
  llc -filetype=obj "$TMP/main.ll" -o "$TMP/main.o"
  clang -c "$DIR/struct_call_lib.c" -o "$TMP/lib.o"
  clang "$TMP/main.o" "$TMP/lib.o" -o "$TMP/calltest" -lm -lpthread
  local out; out="$("$TMP/calltest")"
  echo "  $out"
  [[ "$out" == "$EXPECT" ]] || { echo "  FAIL: expected '$EXPECT'"; exit 1; }
  echo "  PASS"
}

# --- P3.3 large (>16B): caller direction (Quartz -> C) ----------------------
run_host_caller_large() {
  echo "== caller Qz->C LARGE >16B, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_large_call_main.qz" > "$TMP/lmain.ll"
  llc -filetype=obj "$TMP/lmain.ll" -o "$TMP/lmain.o"
  clang -c "$DIR/struct_large_call_lib.c" -o "$TMP/llib.o"
  clang "$TMP/lmain.o" "$TMP/llib.o" -o "$TMP/lcalltest" -lm -lpthread
  local out; out="$("$TMP/lcalltest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_LARGE" ]] || { echo "  FAIL: expected '$EXPECT_LARGE'"; exit 1; }
  echo "  PASS"
}

# --- P3.3 large (>16B): callee direction (C -> Quartz) -----------------------
run_host_callee_large() {
  echo "== callee C->Qz LARGE >16B, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_large_callee.qz" > "$TMP/lcallee.ll"
  llc -filetype=obj "$TMP/lcallee.ll" -o "$TMP/lcallee.o"
  clang -c "$DIR/struct_large_driver.c" -o "$TMP/ldriver.o"
  clang "$TMP/lcallee.o" "$TMP/ldriver.o" -o "$TMP/labitest" -lm -lpthread
  local out; out="$("$TMP/labitest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_LARGE_CALLEE" ]] || { echo "  FAIL: expected '$EXPECT_LARGE_CALLEE'"; exit 1; }
  echo "  PASS"
}

# --- P3.4a narrow (sub-8-byte int): caller direction (Quartz -> C) -----------
run_host_caller_narrow() {
  echo "== caller Qz->C NARROW int, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_narrow_call_main.qz" > "$TMP/nmain.ll"
  llc -filetype=obj "$TMP/nmain.ll" -o "$TMP/nmain.o"
  clang -c "$DIR/struct_narrow_call_lib.c" -o "$TMP/nlib.o"
  clang "$TMP/nmain.o" "$TMP/nlib.o" -o "$TMP/ncalltest" -lm -lpthread
  local out; out="$("$TMP/ncalltest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_NARROW" ]] || { echo "  FAIL: expected '$EXPECT_NARROW'"; exit 1; }
  echo "  PASS"
}

# --- P3.4a narrow: callee direction (C -> Quartz) ----------------------------
run_host_callee_narrow() {
  echo "== callee C->Qz NARROW int, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_narrow_callee.qz" > "$TMP/ncallee.ll"
  llc -filetype=obj "$TMP/ncallee.ll" -o "$TMP/ncallee.o"
  clang -c "$DIR/struct_narrow_driver.c" -o "$TMP/ndriver.o"
  clang "$TMP/ncallee.o" "$TMP/ndriver.o" -o "$TMP/nabitest" -lm -lpthread
  local out; out="$("$TMP/nabitest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_NARROW_CALLEE" ]] || { echo "  FAIL: expected '$EXPECT_NARROW_CALLEE'"; exit 1; }
  echo "  PASS"
}

# --- P3.4b F32: caller direction (Quartz -> C) -------------------------------
run_host_caller_float() {
  echo "== caller Qz->C FLOAT (F32), host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_float_call_main.qz" > "$TMP/fmain.ll"
  llc -filetype=obj "$TMP/fmain.ll" -o "$TMP/fmain.o"
  clang -c "$DIR/struct_float_call_lib.c" -o "$TMP/flib.o"
  clang "$TMP/fmain.o" "$TMP/flib.o" -o "$TMP/fcalltest" -lm -lpthread
  local out; out="$("$TMP/fcalltest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_FLOAT" ]] || { echo "  FAIL: expected '$EXPECT_FLOAT'"; exit 1; }
  echo "  PASS"
}

# --- P3.4b F32: callee direction (C -> Quartz) -------------------------------
run_host_callee_float() {
  echo "== callee C->Qz FLOAT (F32), host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_float_callee.qz" > "$TMP/fcallee.ll"
  llc -filetype=obj "$TMP/fcallee.ll" -o "$TMP/fcallee.o"
  clang -c "$DIR/struct_float_driver.c" -o "$TMP/fdriver.o"
  clang "$TMP/fcallee.o" "$TMP/fdriver.o" -o "$TMP/fabitest" -lm -lpthread
  local out; out="$("$TMP/fabitest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_FLOAT_CALLEE" ]] || { echo "  FAIL: expected '$EXPECT_FLOAT_CALLEE'"; exit 1; }
  echo "  PASS"
}

# --- P3.4-ii-a >16B narrow: caller direction (Quartz -> C) -------------------
run_host_caller_lnarrow() {
  echo "== caller Qz->C LARGE NARROW, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_large_narrow_call_main.qz" > "$TMP/lnmain.ll"
  llc -filetype=obj "$TMP/lnmain.ll" -o "$TMP/lnmain.o"
  clang -c "$DIR/struct_large_narrow_call_lib.c" -o "$TMP/lnlib.o"
  clang "$TMP/lnmain.o" "$TMP/lnlib.o" -o "$TMP/lncalltest" -lm -lpthread
  local out; out="$("$TMP/lncalltest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_LNARROW" ]] || { echo "  FAIL: expected '$EXPECT_LNARROW'"; exit 1; }
  echo "  PASS"
}

# --- P3.4-ii-a >16B narrow: callee direction (C -> Quartz) -------------------
run_host_callee_lnarrow() {
  echo "== callee C->Qz LARGE NARROW, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_large_narrow_callee.qz" > "$TMP/lncallee.ll"
  llc -filetype=obj "$TMP/lncallee.ll" -o "$TMP/lncallee.o"
  clang -c "$DIR/struct_large_narrow_driver.c" -o "$TMP/lndriver.o"
  clang "$TMP/lncallee.o" "$TMP/lndriver.o" -o "$TMP/lnabitest" -lm -lpthread
  local out; out="$("$TMP/lnabitest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_LNARROW_CALLEE" ]] || { echo "  FAIL: expected '$EXPECT_LNARROW_CALLEE'"; exit 1; }
  echo "  PASS"
}

# --- P3.4-ii-b >16B F32: caller direction (Quartz -> C) ----------------------
run_host_caller_lfloat() {
  echo "== caller Qz->C LARGE FLOAT, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_large_float_call_main.qz" > "$TMP/lfmain.ll"
  llc -filetype=obj "$TMP/lfmain.ll" -o "$TMP/lfmain.o"
  clang -c "$DIR/struct_large_float_call_lib.c" -o "$TMP/lflib.o"
  clang "$TMP/lfmain.o" "$TMP/lflib.o" -o "$TMP/lfcalltest" -lm -lpthread
  local out; out="$("$TMP/lfcalltest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_LFLOAT" ]] || { echo "  FAIL: expected '$EXPECT_LFLOAT'"; exit 1; }
  echo "  PASS"
}

# --- P3.4-ii-b >16B F32: callee direction (C -> Quartz) ----------------------
run_host_callee_lfloat() {
  echo "== callee C->Qz LARGE FLOAT, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/struct_large_float_callee.qz" > "$TMP/lfcallee.ll"
  llc -filetype=obj "$TMP/lfcallee.ll" -o "$TMP/lfcallee.o"
  clang -c "$DIR/struct_large_float_driver.c" -o "$TMP/lfdriver.o"
  clang "$TMP/lfcallee.o" "$TMP/lfdriver.o" -o "$TMP/lfabitest" -lm -lpthread
  local out; out="$("$TMP/lfabitest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_LFLOAT_CALLEE" ]] || { echo "  FAIL: expected '$EXPECT_LFLOAT_CALLEE'"; exit 1; }
  echo "  PASS"
}

# Turnkey LOCAL SysV (x86_64) oracle via Rosetta 2 on Apple Silicon. macOS
# x86_64 uses the System V AMD64 struct ABI, so this is a *real run* of the SysV
# convention without a remote x86 box — covers the lovelace lockout gap. Each
# case cross-compiles the Quartz IR for x86_64-apple, links the C side with
# `-arch x86_64`, and runs under `arch -x86_64`.
run_rosetta_case() {
  local label="$1" qz="$2" csrc="$3" expect="$4"
  echo "== $label, sysv x86_64 via Rosetta =="
  "$QZ" --no-cache --target=x86_64-apple-macosx "$DIR/$qz" > "$TMP/r.ll"
  llc -mtriple=x86_64-apple-macosx -filetype=obj "$TMP/r.ll" -o "$TMP/r.o"
  clang -arch x86_64 -c "$DIR/$csrc" -o "$TMP/rc.o"
  clang -arch x86_64 "$TMP/r.o" "$TMP/rc.o" -o "$TMP/rtest" -lm -lpthread
  local out; out="$(arch -x86_64 "$TMP/rtest")"
  echo "  $out"
  [[ "$out" == "$expect" ]] || { echo "  FAIL: expected '$expect'"; exit 1; }
  echo "  PASS"
}

run_rosetta_all() {
  run_rosetta_case "callee C->Qz"               struct_params_callee.qz          struct_params_driver.c          "$EXPECT"
  run_rosetta_case "caller Qz->C"               struct_call_main.qz              struct_call_lib.c               "$EXPECT"
  run_rosetta_case "callee C->Qz LARGE >16B"    struct_large_callee.qz           struct_large_driver.c           "$EXPECT_LARGE_CALLEE"
  run_rosetta_case "caller Qz->C LARGE >16B"    struct_large_call_main.qz        struct_large_call_lib.c         "$EXPECT_LARGE"
  run_rosetta_case "callee C->Qz NARROW int"    struct_narrow_callee.qz          struct_narrow_driver.c          "$EXPECT_NARROW_CALLEE"
  run_rosetta_case "caller Qz->C NARROW int"    struct_narrow_call_main.qz       struct_narrow_call_lib.c        "$EXPECT_NARROW"
  run_rosetta_case "callee C->Qz FLOAT (F32)"   struct_float_callee.qz           struct_float_driver.c           "$EXPECT_FLOAT_CALLEE"
  run_rosetta_case "caller Qz->C FLOAT (F32)"   struct_float_call_main.qz        struct_float_call_lib.c         "$EXPECT_FLOAT"
  run_rosetta_case "callee C->Qz LARGE NARROW"  struct_large_narrow_callee.qz    struct_large_narrow_driver.c    "$EXPECT_LNARROW_CALLEE"
  run_rosetta_case "caller Qz->C LARGE NARROW"  struct_large_narrow_call_main.qz struct_large_narrow_call_lib.c  "$EXPECT_LNARROW"
  run_rosetta_case "callee C->Qz LARGE FLOAT"   struct_large_float_callee.qz     struct_large_float_driver.c     "$EXPECT_LFLOAT_CALLEE"
  run_rosetta_case "caller Qz->C LARGE FLOAT"   struct_large_float_call_main.qz  struct_large_float_call_lib.c   "$EXPECT_LFLOAT"
}

# Every remote op is wrapped in `timeout` and fed </dev/null so a noisy or
# broken remote ~/.bashrc fails fast instead of hanging the suite.
run_sysv_callee() {
  local host="$1"
  echo "== callee C->Qz, sysv x86_64 (cross-llc here, run on $host) =="
  "$QZ" --no-cache --target=x86_64-unknown-linux-gnu "$DIR/struct_params_callee.qz" > "$TMP/callee_x64.ll"
  llc -filetype=obj "$TMP/callee_x64.ll" -o "$TMP/callee_x64.o"
  timeout 30 scp -q "$TMP/callee_x64.o" "$host:/tmp/cabi_callee.o" </dev/null
  timeout 30 scp -q "$DIR/struct_params_driver.c" "$host:/tmp/cabi_driver.c" </dev/null
  local remote='export PATH=/usr/bin:/bin; cd /tmp && gcc -c cabi_driver.c -o cabi_driver.o && gcc -no-pie cabi_callee.o cabi_driver.o -o cabi_test -lm -lpthread && ./cabi_test'
  local out; out="$(timeout 60 ssh -T "$host" "$remote" </dev/null)"
  echo "  $out"
  [[ "$out" == "$EXPECT" ]] || { echo "  FAIL: expected '$EXPECT'"; exit 1; }
  echo "  PASS"
}

run_sysv_caller() {
  local host="$1"
  echo "== caller Qz->C, sysv x86_64 (cross-llc here, run on $host) =="
  "$QZ" --no-cache --target=x86_64-unknown-linux-gnu "$DIR/struct_call_main.qz" > "$TMP/main_x64.ll"
  llc -filetype=obj "$TMP/main_x64.ll" -o "$TMP/main_x64.o"
  timeout 30 scp -q "$TMP/main_x64.o" "$host:/tmp/cabi_main.o" </dev/null
  timeout 30 scp -q "$DIR/struct_call_lib.c" "$host:/tmp/cabi_lib.c" </dev/null
  local remote='export PATH=/usr/bin:/bin; cd /tmp && gcc -c cabi_lib.c -o cabi_lib.o && gcc -no-pie cabi_main.o cabi_lib.o -o cabi_calltest -lm -lpthread && ./cabi_calltest'
  local out; out="$(timeout 60 ssh -T "$host" "$remote" </dev/null)"
  echo "  $out"
  [[ "$out" == "$EXPECT" ]] || { echo "  FAIL: expected '$EXPECT'"; exit 1; }
  echo "  PASS"
}

run_sysv_caller_large() {
  local host="$1"
  echo "== caller Qz->C LARGE >16B, sysv x86_64 (cross-llc here, run on $host) =="
  "$QZ" --no-cache --target=x86_64-unknown-linux-gnu "$DIR/struct_large_call_main.qz" > "$TMP/lmain_x64.ll"
  llc -filetype=obj "$TMP/lmain_x64.ll" -o "$TMP/lmain_x64.o"
  timeout 30 scp -q "$TMP/lmain_x64.o" "$host:/tmp/cabi_lmain.o" </dev/null
  timeout 30 scp -q "$DIR/struct_large_call_lib.c" "$host:/tmp/cabi_llib.c" </dev/null
  local remote='export PATH=/usr/bin:/bin; cd /tmp && gcc -c cabi_llib.c -o cabi_llib.o && gcc -no-pie cabi_lmain.o cabi_llib.o -o cabi_lcalltest -lm -lpthread && ./cabi_lcalltest'
  local out; out="$(timeout 60 ssh -T "$host" "$remote" </dev/null)"
  echo "  $out"
  [[ "$out" == "$EXPECT_LARGE" ]] || { echo "  FAIL: expected '$EXPECT_LARGE'"; exit 1; }
  echo "  PASS"
}

run_sysv_callee_large() {
  local host="$1"
  echo "== callee C->Qz LARGE >16B, sysv x86_64 (cross-llc here, run on $host) =="
  "$QZ" --no-cache --target=x86_64-unknown-linux-gnu "$DIR/struct_large_callee.qz" > "$TMP/lcallee_x64.ll"
  llc -filetype=obj "$TMP/lcallee_x64.ll" -o "$TMP/lcallee_x64.o"
  timeout 30 scp -q "$TMP/lcallee_x64.o" "$host:/tmp/cabi_lcallee.o" </dev/null
  timeout 30 scp -q "$DIR/struct_large_driver.c" "$host:/tmp/cabi_ldriver.c" </dev/null
  local remote='export PATH=/usr/bin:/bin; cd /tmp && gcc -c cabi_ldriver.c -o cabi_ldriver.o && gcc -no-pie cabi_lcallee.o cabi_ldriver.o -o cabi_labitest -lm -lpthread && ./cabi_labitest'
  local out; out="$(timeout 60 ssh -T "$host" "$remote" </dev/null)"
  echo "  $out"
  [[ "$out" == "$EXPECT_LARGE_CALLEE" ]] || { echo "  FAIL: expected '$EXPECT_LARGE_CALLEE'"; exit 1; }
  echo "  PASS"
}

run_sysv_caller_narrow() {
  local host="$1"
  echo "== caller Qz->C NARROW int, sysv x86_64 (cross-llc here, run on $host) =="
  "$QZ" --no-cache --target=x86_64-unknown-linux-gnu "$DIR/struct_narrow_call_main.qz" > "$TMP/nmain_x64.ll"
  llc -filetype=obj "$TMP/nmain_x64.ll" -o "$TMP/nmain_x64.o"
  timeout 30 scp -q "$TMP/nmain_x64.o" "$host:/tmp/cabi_nmain.o" </dev/null
  timeout 30 scp -q "$DIR/struct_narrow_call_lib.c" "$host:/tmp/cabi_nlib.c" </dev/null
  local remote='export PATH=/usr/bin:/bin; cd /tmp && gcc -c cabi_nlib.c -o cabi_nlib.o && gcc -no-pie cabi_nmain.o cabi_nlib.o -o cabi_ncalltest -lm -lpthread && ./cabi_ncalltest'
  local out; out="$(timeout 60 ssh -T "$host" "$remote" </dev/null)"
  echo "  $out"
  [[ "$out" == "$EXPECT_NARROW" ]] || { echo "  FAIL: expected '$EXPECT_NARROW'"; exit 1; }
  echo "  PASS"
}

run_sysv_callee_narrow() {
  local host="$1"
  echo "== callee C->Qz NARROW int, sysv x86_64 (cross-llc here, run on $host) =="
  "$QZ" --no-cache --target=x86_64-unknown-linux-gnu "$DIR/struct_narrow_callee.qz" > "$TMP/ncallee_x64.ll"
  llc -filetype=obj "$TMP/ncallee_x64.ll" -o "$TMP/ncallee_x64.o"
  timeout 30 scp -q "$TMP/ncallee_x64.o" "$host:/tmp/cabi_ncallee.o" </dev/null
  timeout 30 scp -q "$DIR/struct_narrow_driver.c" "$host:/tmp/cabi_ndriver.c" </dev/null
  local remote='export PATH=/usr/bin:/bin; cd /tmp && gcc -c cabi_ndriver.c -o cabi_ndriver.o && gcc -no-pie cabi_ncallee.o cabi_ndriver.o -o cabi_nabitest -lm -lpthread && ./cabi_nabitest'
  local out; out="$(timeout 60 ssh -T "$host" "$remote" </dev/null)"
  echo "  $out"
  [[ "$out" == "$EXPECT_NARROW_CALLEE" ]] || { echo "  FAIL: expected '$EXPECT_NARROW_CALLEE'"; exit 1; }
  echo "  PASS"
}

run_sysv_caller_float() {
  local host="$1"
  echo "== caller Qz->C FLOAT (F32), sysv x86_64 (cross-llc here, run on $host) =="
  "$QZ" --no-cache --target=x86_64-unknown-linux-gnu "$DIR/struct_float_call_main.qz" > "$TMP/fmain_x64.ll"
  llc -filetype=obj "$TMP/fmain_x64.ll" -o "$TMP/fmain_x64.o"
  timeout 30 scp -q "$TMP/fmain_x64.o" "$host:/tmp/cabi_fmain.o" </dev/null
  timeout 30 scp -q "$DIR/struct_float_call_lib.c" "$host:/tmp/cabi_flib.c" </dev/null
  local remote='export PATH=/usr/bin:/bin; cd /tmp && gcc -c cabi_flib.c -o cabi_flib.o && gcc -no-pie cabi_fmain.o cabi_flib.o -o cabi_fcalltest -lm -lpthread && ./cabi_fcalltest'
  local out; out="$(timeout 60 ssh -T "$host" "$remote" </dev/null)"
  echo "  $out"
  [[ "$out" == "$EXPECT_FLOAT" ]] || { echo "  FAIL: expected '$EXPECT_FLOAT'"; exit 1; }
  echo "  PASS"
}

run_sysv_callee_float() {
  local host="$1"
  echo "== callee C->Qz FLOAT (F32), sysv x86_64 (cross-llc here, run on $host) =="
  "$QZ" --no-cache --target=x86_64-unknown-linux-gnu "$DIR/struct_float_callee.qz" > "$TMP/fcallee_x64.ll"
  llc -filetype=obj "$TMP/fcallee_x64.ll" -o "$TMP/fcallee_x64.o"
  timeout 30 scp -q "$TMP/fcallee_x64.o" "$host:/tmp/cabi_fcallee.o" </dev/null
  timeout 30 scp -q "$DIR/struct_float_driver.c" "$host:/tmp/cabi_fdriver.c" </dev/null
  local remote='export PATH=/usr/bin:/bin; cd /tmp && gcc -c cabi_fdriver.c -o cabi_fdriver.o && gcc -no-pie cabi_fcallee.o cabi_fdriver.o -o cabi_fabitest -lm -lpthread && ./cabi_fabitest'
  local out; out="$(timeout 60 ssh -T "$host" "$remote" </dev/null)"
  echo "  $out"
  [[ "$out" == "$EXPECT_FLOAT_CALLEE" ]] || { echo "  FAIL: expected '$EXPECT_FLOAT_CALLEE'"; exit 1; }
  echo "  PASS"
}

# --- B.11b @cImport: generated-bindings caller direction (Quartz -> C) -------
run_host_cimport() {
  echo "== @cImport Qz->C, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/cimport_main.qz" > "$TMP/cim.ll"
  llc -filetype=obj "$TMP/cim.ll" -o "$TMP/cim.o"
  clang -c "$DIR/cimport_lib.c" -o "$TMP/cimlib.o"
  clang "$TMP/cim.o" "$TMP/cimlib.o" -o "$TMP/cimtest" -lm -lpthread
  local out; out="$("$TMP/cimtest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_CIMPORT" ]] || { echo "  FAIL: expected '$EXPECT_CIMPORT'"; exit 1; }
  echo "  PASS"
}

run_rosetta_cimport() {
  echo "== @cImport Qz->C, sysv x86_64 via Rosetta =="
  "$QZ" --no-cache --target=x86_64-apple-macosx "$DIR/cimport_main.qz" > "$TMP/cim_r.ll"
  llc -mtriple=x86_64-apple-macosx -filetype=obj "$TMP/cim_r.ll" -o "$TMP/cim_r.o"
  clang -arch x86_64 -c "$DIR/cimport_lib.c" -o "$TMP/cimlib_r.o"
  clang -arch x86_64 "$TMP/cim_r.o" "$TMP/cimlib_r.o" -o "$TMP/cimrtest" -lm -lpthread
  local out; out="$(arch -x86_64 "$TMP/cimrtest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_CIMPORT" ]] || { echo "  FAIL: expected '$EXPECT_CIMPORT'"; exit 1; }
  echo "  PASS"
}

# --- @repr(C)-only struct-by-value (no @value) regression --------------------
run_host_reprc() {
  echo "== @repr(C)-only struct by value, host ($(uname -m)) =="
  "$QZ" --no-cache "$DIR/reprc_only_main.qz" > "$TMP/reprc.ll"
  llc -filetype=obj "$TMP/reprc.ll" -o "$TMP/reprc.o"
  clang -c "$DIR/reprc_only_lib.c" -o "$TMP/reprclib.o"
  clang "$TMP/reprc.o" "$TMP/reprclib.o" -o "$TMP/reprctest" -lm -lpthread
  local out; out="$("$TMP/reprctest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_REPRC" ]] || { echo "  FAIL: expected '$EXPECT_REPRC'"; exit 1; }
  echo "  PASS"
}

run_rosetta_reprc() {
  echo "== @repr(C)-only struct by value, sysv x86_64 via Rosetta =="
  "$QZ" --no-cache --target=x86_64-apple-macosx "$DIR/reprc_only_main.qz" > "$TMP/reprc_r.ll"
  llc -mtriple=x86_64-apple-macosx -filetype=obj "$TMP/reprc_r.ll" -o "$TMP/reprc_r.o"
  clang -arch x86_64 -c "$DIR/reprc_only_lib.c" -o "$TMP/reprclib_r.o"
  clang -arch x86_64 "$TMP/reprc_r.o" "$TMP/reprclib_r.o" -o "$TMP/reprcrtest" -lm -lpthread
  local out; out="$(arch -x86_64 "$TMP/reprcrtest")"
  echo "  $out"
  [[ "$out" == "$EXPECT_REPRC" ]] || { echo "  FAIL: expected '$EXPECT_REPRC'"; exit 1; }
  echo "  PASS"
}

if [[ "${1:-}" == "--sysv" ]]; then
  host="${2:?usage: run.sh --sysv <ssh-host>}"
  run_sysv_callee "$host"
  run_sysv_caller "$host"
  run_sysv_callee_large "$host"
  run_sysv_caller_large "$host"
  run_sysv_callee_narrow "$host"
  run_sysv_caller_narrow "$host"
  run_sysv_callee_float "$host"
  run_sysv_caller_float "$host"
elif [[ "${1:-}" == "--rosetta" ]]; then
  run_rosetta_all
  run_rosetta_cimport
  run_rosetta_reprc
else
  run_host_callee
  run_host_caller
  run_host_callee_large
  run_host_caller_large
  run_host_callee_narrow
  run_host_caller_narrow
  run_host_callee_float
  run_host_caller_float
  run_host_callee_lnarrow
  run_host_caller_lnarrow
  run_host_callee_lfloat
  run_host_caller_lfloat
  run_host_cimport
  run_host_reprc
fi

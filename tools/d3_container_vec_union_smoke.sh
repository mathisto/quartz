#!/usr/bin/env bash
# D3-container cross-module Vec<union> serialization smoke (R2.3 item 3).
#
# Guards the container-NESTED union/record band-id path: a Vec<Int|String>
# returned from an imported module must round-trip through the warm .qzmod
# cache with the nested union band id remapped. The nested band id lives in a
# ptype ARG slot (arg1), not a blob slot, so it needs (a) the emit collector to
# scan input.ptype_arg1s/arg2s and ship the Int|String union signature, and
# (b) the consumer to build the union/record remap BEFORE the ptype walk so
# _qzmod_remap_arg can resolve the 2000..3999 band id (else the whole module
# advisory-misses on the ptype walk). Sibling of
# tools/d3_crossmodule_union_record_smoke.sh (the direct-VALUE path).
#
# This smoke can NOT live in qspec: qspec/subprocess always compiles with
# --no-cache, so it never exercises the warm-cache inject/remap path. It needs a
# real cold-build -> warm-rebuild cycle across a module boundary.
#
# Exit 0 = correct (both cold and warm produce 42, and the nested union sig
# section is emitted). Exit 1 = regression (wrong output / missing section /
# build fail).
#
# Usage: QUARTZ=./self-hosted/bin/quartz tools/d3_container_vec_union_smoke.sh
set -u

QUARTZ="${QUARTZ:-./self-hosted/bin/quartz}"
LLC="${LLC:-llc}"
CC="${CC:-clang}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qz_d3c_xmod.XXXXXX")"
CACHE="$WORK/.cache"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# lib exports a fn returning a Vec whose element type is a union (Int | String).
cat > "$WORK/lib.qz" <<'EOF'
def make_uv(): Vec<Int | String>
  var v = vec_new<Int | String>()
  v.push(7)
  v.push("hi")
  return v
end
EOF

# main imports lib; reads element 0 (Int-narrow) + element 1 (String-narrow).
# 40 if v[0] is Int, +2 if v[1] is String -> 42.
cat > "$WORK/main.qz" <<'EOF'
import * from lib

def main(): Int
  var v = make_uv()
  var total = 0
  if v[0] is Int
    total = total + 40
  end
  if v[1] is String
    total = total + 2
  end
  return total
end
EOF

build_and_run() { # $1 = output-binary path
  "$QUARTZ" --cache-dir "$CACHE" -I "$WORK" "$WORK/main.qz" > "$WORK/m.ll" 2>"$WORK/m.err" \
    || { cat "$WORK/m.err" >&2; return 2; }
  "$LLC" "$WORK/m.ll" -filetype=obj -o "$WORK/m.o" 2>/dev/null || return 3
  "$CC" "$WORK/m.o" -o "$1" -lm -lpthread 2>/dev/null || return 4
  "$1"; echo "$?"
}

# --- Cold build (empty cache) ---
rm -rf "$CACHE"
cold="$(build_and_run "$WORK/cold")" || fail "cold build failed (rc=$?)"
[ "$cold" = "42" ] || fail "cold output wrong: '$cold' (want 42 = Int-narrow 40 + String-narrow 2)"

# --- Warm rebuild: lib injected from cache; nested band id must remap ---
warm="$(build_and_run "$WORK/warm")" || fail "warm output wrong: '$warm' (nested Vec<union> band id round-trip broke)"
[ "$warm" = "42" ] || fail "warm output wrong: '$warm' (want 42; nested Vec<union> band round-trip broke)"

# --- Confirm the nested Int|String union signature actually shipped ---
usig="$(find "$CACHE" -name 'union_sig_members.bin' -size +0c | head -1)"
[ -n "$usig" ] || fail "union_sig_members.bin missing/empty — nested union signature not serialized"

echo "PASS: cross-module Vec<Int|String> nested-band round-trip (cold=warm=42, nested union sig emitted)"
exit 0

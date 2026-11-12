#!/usr/bin/env bash
# D3 cross-module union/record VALUE serialization smoke (R2.2 item 6).
#
# Guards qzmod cross-module serialization of the TYPE_UNION_BASE..RECORD_BASE
# band: a union value and a record value returned from an imported module must
# round-trip through the warm .qzmod cache with their tag/layout intact. Before
# D3 the band was an "advisory-miss" (unmappable -> source-recompile fallback);
# D3 ships the union arm-set + record field signatures in the module cache and
# re-interns them consumer-side (qzmod_emit/format/load/remap.qz).
#
# This smoke can NOT live in qspec: qspec/subprocess always compiles with
# --no-cache, so it never exercises the warm-cache inject/remap path. It needs a
# real cold-build -> warm-rebuild cycle across a module boundary.
#
# Exit 0 = correct (both cold and warm produce 49, and the D3 cache sections are
# emitted). Exit 1 = regression (wrong output / missing sections / build fail).
#
# Usage: QUARTZ=./self-hosted/bin/quartz tools/d3_crossmodule_union_record_smoke.sh
set -u

QUARTZ="${QUARTZ:-./self-hosted/bin/quartz}"
LLC="${LLC:-llc}"
CC="${CC:-clang}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qz_d3_xmod.XXXXXX")"
CACHE="$WORK/.cache"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# lib exports a fn returning a UNION value and a fn returning a RECORD value.
cat > "$WORK/lib.qz" <<'EOF'
struct Pt
  x: Int
  y: Int
end

def make_u(): Int | String
  return 7
end

def make_r(): { x: Int, y: Int }
  return Pt { x: 40, y: 2 }
end
EOF

# main imports lib and consumes both across the module boundary.
cat > "$WORK/main.qz" <<'EOF'
import * from lib

def main(): Int
  var u = make_u()
  var r = make_r()
  var total = r.x + r.y
  if u is Int
    total = total + u
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
[ "$cold" = "49" ] || fail "cold output wrong: '$cold' (want 49 = r.x+r.y + narrowed u)"

# --- Warm rebuild: lib injected from cache; band ids must remap ---
warm="$(build_and_run "$WORK/warm")" || fail "warm build failed (rc=$?)"
[ "$warm" = "49" ] || fail "warm output wrong: '$warm' (want 49; cross-module union/record value round-trip broke)"

# --- Confirm D3 actually shipped the band signature sections for lib ---
usig="$(find "$CACHE" -name 'union_sig_members.bin' -size +0c | head -1)"
rsig="$(find "$CACHE" -name 'record_sig_blob.bin' -size +0c | head -1)"
[ -n "$usig" ] || fail "D3 union_sig_members.bin missing/empty — union signature not serialized"
[ -n "$rsig" ] || fail "D3 record_sig_blob.bin missing/empty — record signature not serialized"

echo "PASS: cross-module union+record VALUE round-trip through warm cache (cold=warm=49, band sigs emitted)"
exit 0

#!/usr/bin/env bash
# Warm-cache dependency-invalidation regression smoke.
#
# Guards the vec-of-struct-field-fidelity bug (filed 2026-05-23, fixed in the
# resolver dep-edge hoist): when two modules wildcard-import the same struct-
# bearing dependency, the SECOND importer's `importer -> dep` edge was never
# recorded in the dependency graph (it was gated behind `combo_seen_re == 0`).
# Its per-module IR cache then never invalidated when the dependency's struct
# layout changed, so it kept reading fields at stale offsets after a warm
# rebuild -> garbled `vec[i].field` reads.
#
# This smoke can NOT live in qspec: qspec/subprocess always compiles with
# --no-cache, so it never exercises warm-cache invalidation. It needs a real
# cold-build -> edit-dep-layout -> warm-rebuild -> run cycle.
#
# Exit 0 = correct (importer was invalidated). Exit 1 = regression (stale
# offsets / wrong output / build failure).
#
# Usage: QUARTZ=./self-hosted/bin/quartz tools/cache_invalidation_vecstruct_smoke.sh
set -u

QUARTZ="${QUARTZ:-./self-hosted/bin/quartz}"
LLC="${LLC:-llc}"
CC="${CC:-clang}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qz_cache_inval.XXXXXX")"
CACHE="$WORK/.cache"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# reader.qz + main.qz both `import * from lib` — main is the 2nd importer.
cat > "$WORK/reader.qz" <<'EOF'
import * from lib

def read_x(p: Point): Int
  return p.x
end
EOF

cat > "$WORK/main.qz" <<'EOF'
import * from reader
import * from lib

def main(): Int
  var pts = vec_new<Point>()
  pts.push(make_point(111))
  pts.push(make_point(222))
  var i = 0
  while i < pts.size
    puts(str_from_int(pts[i].x))
    i += 1
  end
  return 0
end
EOF

build_and_run() { # $1 = output-binary path
  "$QUARTZ" --cache-dir "$CACHE" -I "$WORK" "$WORK/main.qz" > "$WORK/m.ll" 2>"$WORK/m.err" \
    || { cat "$WORK/m.err" >&2; return 2; }
  "$LLC" "$WORK/m.ll" -filetype=obj -o "$WORK/m.o" 2>/dev/null || return 3
  "$CC" "$WORK/m.o" -o "$1" -lm -lpthread 2>/dev/null || return 4
  "$1"
}

# --- Cold build: Point has a single field x at offset 0 ---
cat > "$WORK/lib.qz" <<'EOF'
struct Point
  x: Int
end

def make_point(v: Int): Point
  return Point { x: v }
end
EOF
rm -rf "$CACHE"
cold="$(build_and_run "$WORK/cold")" || fail "cold build failed (rc=$?)"
[ "$cold" = "$(printf '111\n222')" ] || fail "cold output wrong: '$cold' (want '111/222')"

# --- Warm rebuild: prepend a field so x's offset shifts 0 -> 1. main.qz is
#     UNCHANGED, so a missing dep-edge leaves its cache stale (reads z=999). ---
cat > "$WORK/lib.qz" <<'EOF'
struct Point
  z: Int
  x: Int
end

def make_point(v: Int): Point
  return Point { z: 999, x: v }
end
EOF
warm="$(build_and_run "$WORK/warm")" || fail "warm build failed (rc=$?)"

if [ "$warm" = "$(printf '999\n999')" ]; then
  fail "REGRESSION — 2nd importer's cache not invalidated on dep layout change (stale offsets: read z=999 where x was expected)"
fi
[ "$warm" = "$(printf '111\n222')" ] || fail "warm output unexpected: '$warm' (want '111/222')"

echo "PASS: warm-cache dep-invalidation correct (2nd wildcard-importer re-compiled on dep layout change)"
exit 0

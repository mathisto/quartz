#!/usr/bin/env bash
# UFCS Dispatch Snapshot Check
#
# Extracts the UFCS dispatch table from typecheck_expr_handlers.qz
# into a canonical text representation. The committed snapshot at
# spec/snapshots/ufcs_dispatch.txt is the source of truth for what
# methods every type currently dispatches via UFCS.
#
# Usage:
#   tools/check_ufcs_snapshot.sh                  # check (CI mode)
#   tools/check_ufcs_snapshot.sh --regenerate     # regenerate snapshot
#   tools/check_ufcs_snapshot.sh --print          # print to stdout
#
# This is the minimum-viable enforcement. Phase 10 of the API
# unification sprint. Style guide: docs/COLLECTIONS_STYLE.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$REPO_ROOT/self-hosted/middle/typecheck_expr_handlers.qz"
SNAPSHOT="$REPO_ROOT/spec/snapshots/ufcs_dispatch.txt"

if [ ! -f "$SOURCE" ]; then
  echo "ERROR: dispatch source not found: $SOURCE" >&2
  exit 2
fi

# Extract the dispatch table from typecheck_expr_handlers.qz.
# Single-pass awk:
#   - track current type, set by `(if|elsif) first_arg_type == TYPE_X`
#   - emit "TYPE\tmethod\tintrinsic" for each match arm in that block
#
# Type-name normalization: TYPE_VEC -> Vec, TYPE_STRINGBUILDER ->
# StringBuilder, TYPE_F64 -> F64, TYPE_ATOMIC -> AtomicInt, etc.
extract_dispatch() {
  awk '
    BEGIN { type = "" }
    /(if|elsif) first_arg_type == type_constants::TYPE_/ {
      # Capture the type identifier
      if (match($0, /TYPE_[A-Z0-9_]+/)) {
        raw = substr($0, RSTART + 5, RLENGTH - 5)
        # Hard-coded display names for the types we know about.
        # Keeps output stable and avoids fighting awks regex-replace.
        if      (raw == "STRING")        type = "String"
        else if (raw == "VEC")           type = "Vec"
        else if (raw == "MAP")           type = "Map"
        else if (raw == "STRINGBUILDER") type = "StringBuilder"
        else if (raw == "SET")           type = "Set"
        else if (raw == "RANGE")         type = "Range"
        else if (raw == "INT")           type = "Int"
        else if (raw == "F64")           type = "F64"
        else if (raw == "TASK_GROUP")    type = "TaskGroup"
        else if (raw == "CHANNEL")       type = "Channel"
        else if (raw == "ATOMIC")        type = "AtomicInt"
        else if (raw == "MUTEX")         type = "Mutex"
        else if (raw == "OPTION")        type = "Option"
        else if (raw == "RESULT")        type = "Result"
        else                             type = raw   # unknown — leave raw to surface in diff
      }
      next
    }
    # Match arms: only inside a known type block (skip enum constants etc.)
    type != "" && /^[[:space:]]*"[a-z0-9_?]+"[[:space:]]*=>[[:space:]]*"[a-z0-9_?]+"/ {
      if (match($0, /"[a-z0-9_?]+"[[:space:]]*=>[[:space:]]*"[a-z0-9_?]+"/)) {
        pair = substr($0, RSTART, RLENGTH)
        gsub(/"/, "", pair)
        sub(/[[:space:]]*=>[[:space:]]*/, "|", pair)
        n = split(pair, kv, "|")
        if (n == 2) {
          printf "%s\t%s\t%s\n", type, kv[1], kv[2]
        }
      }
    }
  ' "$SOURCE"
}

# Render extracted data as the canonical snapshot.
render_snapshot() {
  local total
  total=$(extract_dispatch | wc -l | tr -d ' ')

  cat <<EOF
# UFCS Dispatch Snapshot
#
# This file is the canonical record of every UFCS method dispatch
# wired into the Quartz compiler at typecheck_expr_handlers.qz.
# It exists so that any change to the dispatch table — adding,
# renaming, removing — produces a visible diff.
#
# Source: self-hosted/middle/typecheck_expr_handlers.qz
# Generator: tools/check_ufcs_snapshot.sh --regenerate
# Style guide: docs/COLLECTIONS_STYLE.md
# API reference: docs/API_GUIDELINES.md
#
# Format: type sections in source-table order; methods within a
# type also in source order so diffs preserve locality.
#
# To regenerate after an intentional change to the dispatch table:
#   tools/check_ufcs_snapshot.sh --regenerate
#   (then commit the diff alongside your dispatch-table change)
#
# To verify (CI / pre-push hook):
#   tools/check_ufcs_snapshot.sh
#   (exits 1 if the snapshot is stale)

EOF

  # Print sections grouped by type, preserving source order within each
  current_type=""
  extract_dispatch | while IFS=$'\t' read -r type method intrinsic; do
    if [ "$type" != "$current_type" ]; then
      if [ -n "$current_type" ]; then
        echo ""
      fi
      echo "== $type =="
      current_type="$type"
    fi
    printf "%-20s -> %s\n" "$method" "$intrinsic"
  done

  printf "\n# === END OF SNAPSHOT ===\n"
  printf "# Total entries: %s\n" "$total"
}

case "${1:-check}" in
  --regenerate)
    render_snapshot > "$SNAPSHOT"
    echo "Regenerated $SNAPSHOT"
    wc -l "$SNAPSHOT"
    ;;
  --print)
    render_snapshot
    ;;
  check|--check)
    if [ ! -f "$SNAPSHOT" ]; then
      echo "ERROR: snapshot not found: $SNAPSHOT" >&2
      echo "Run: tools/check_ufcs_snapshot.sh --regenerate" >&2
      exit 2
    fi
    if ! diff -u "$SNAPSHOT" <(render_snapshot) > /tmp/ufcs_snapshot_diff.txt; then
      echo "ERROR: UFCS dispatch snapshot is stale." >&2
      echo "" >&2
      echo "The dispatch table in typecheck_expr_handlers.qz has changed" >&2
      echo "but spec/snapshots/ufcs_dispatch.txt was not updated." >&2
      echo "" >&2
      echo "Diff (snapshot vs. current source):" >&2
      cat /tmp/ufcs_snapshot_diff.txt >&2
      echo "" >&2
      echo "If this change is intentional, regenerate the snapshot:" >&2
      echo "  tools/check_ufcs_snapshot.sh --regenerate" >&2
      echo "Then commit the new snapshot alongside your source change." >&2
      exit 1
    fi
    echo "UFCS dispatch snapshot OK"
    ;;
  *)
    echo "Usage: $0 [check|--regenerate|--print]" >&2
    exit 2
    ;;
esac

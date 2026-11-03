#!/usr/bin/env bash
set -euo pipefail

# Static build through luam's shared orchestrator:
# one self-contained bin/tkn, no luam install needed to run it.

cd "$(dirname "$0")/.."

if [ -z "${LUAM_DIR:-}" ]; then
    LUAM_DIR=$(cd ../luam 2>/dev/null && pwd || true)
fi

if [ -z "$LUAM_DIR" ] || [ ! -f "$LUAM_DIR/obj/liblua.a" ]; then
    echo "Error: no built luam checkout found. Set LUAM_DIR to one (obj/liblua.a present)." >&2
    exit 1
fi

# Record the commit (with -dirty for uncommitted changes) for --version.
COMMIT=$(git describe --always --dirty 2>/dev/null || echo unknown)
printf 'return "%s"\n' "$COMMIT" > src/build_commit.lua

exec "$LUAM_DIR/bin/luam" "$LUAM_DIR/lib/static/build.lua" \
    --entry main.lua \
    --bin tkn \
    --with lfs \
    --luamdir "$LUAM_DIR" \
    "$@"

#!/usr/bin/env bash
set -euo pipefail

# Run this project's test suite: Luam unit tests (tst/unit/*.lua,
# standalone scripts that exit non-zero on failure) plus bats
# integration tests (tst/integration/*.bats, driving the built
# bin/tkn against stub tools and a scratch HOME -- see
# tst/integration/test_helper.bash).
#
# Requires `bats` on PATH (apt install bats) and a built luam checkout
# the same way bld/build.sh does.

cd "$(dirname "$0")/.."

if [ -z "${LUAM_DIR:-}" ]; then
    LUAM_DIR=$(cd ../luam && pwd)
fi

if ! command -v bats > /dev/null 2>&1; then
    echo "Error: bats not found on PATH. Install it (e.g. apt install bats) to run tst/integration/*.bats." >&2
    exit 1
fi

echo "Building"
LUAM_DIR="$LUAM_DIR" ./bld/build.sh

echo
echo "Running Luam unit tests (tst/unit/)"
export LUA_PATH="./src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;"
export LUA_CPATH="${LUAM_DIR}/bin/?.so;${LUAM_DIR}/lib/lfs/?.so;;"
for f in tst/unit/*.lua; do
    echo "--- $f ---"
    "$LUAM_DIR/bin/luam" "$f"
done

echo
echo "Running bats integration tests (tst/integration/)"
bats tst/integration/*.bats

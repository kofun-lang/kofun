#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-generic-records.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
. "$ROOT/bootstrap/stage2/build.sh"
kofun_stage2_build "$ROOT" "$WORK/compiler"
node "$ROOT/tests/conformance/generic-records-stage2/check.mjs" \
    "$WORK/compiler" "$ROOT/bootstrap/stage2/compiler.kofun" "$WORK"

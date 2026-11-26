#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-law-declaration-hir.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
. "$ROOT/bootstrap/stage2/build.sh"
kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"
# The bounded host driver delegates only its Unicode primitive to the pinned
# validator. This existing probe exposes it independently of any law parser.
"${CC:-cc}" -std=c11 -O0 "$ROOT/tests/concurrency/places/driver.c" -o "$WORK/unicode-probe"
node "$ROOT/spec/law-declaration-hir-v1/check.mjs" "$WORK/kofun-stage2" "$WORK/unicode-probe" "$WORK"

#!/usr/bin/env sh
# Gate for the generic-ADT HIR v1 contract and its two compiler halves (#1675).
#
# Producer-independent: the oracle recomputes every identity from its preimage
# with the #303 frame and checks the canonical document, the substituted
# constructor payloads and record fields, the limits, the by-value cycle
# classes and the refusals. Then the canonical Kofun half (through the bounded
# host driver) and the maintained C half (the built binary) must both
# reproduce the positive golden byte for byte and refuse every negative fixture
# with its code and no artifact, and the two halves must agree.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/spec/generic-adt-hir-v1"

for tool in node "${CC:-cc}"; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '%s\n' "generic-adt-hir requires $tool" >&2
        exit 1
    }
done

# shellcheck source=/dev/null
. "$ROOT/bootstrap/stage2/build.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-generic-adt-hir.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

node --check "$HERE/model.mjs"
node --check "$HERE/check.mjs"

kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"
"${CC:-cc}" -std=c11 -O0 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/compiler.c" -o "$WORK/kofun-stage2-o0"

KOFUN_GENERIC_ADT_STAGE2="$WORK/kofun-stage2" \
KOFUN_GENERIC_ADT_STAGE2_O0="$WORK/kofun-stage2-o0" \
KOFUN_GENERIC_ADT_WORK="$WORK" \
    node "$HERE/check.mjs"

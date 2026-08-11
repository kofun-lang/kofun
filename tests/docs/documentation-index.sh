#!/bin/sh

set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_DOCUMENTATION_INDEX_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}documentation-index"}
CC=${CC:-cc}
PRODUCER="$WORK/kofun-stage2-kif"
KIF_READER="$WORK/kofun-kif-v1"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

case $WORK in
    */documentation-index|*/documentation-index.*) ;;
    *) fail "work directory must end in documentation-index[.suffix]: $WORK" ;;
esac
command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'Node.js is required'
rm -rf "$WORK"
mkdir -p "$WORK"

kofun_stage2_semantic_inputs "$ROOT" library
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/stage2_kif_producer.c" \
    "$KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_EVENTS_INPUT" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$KOFUN_STAGE2_SEMANTIC_SHA256_INPUT" \
    -o "$PRODUCER"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/kif_v1_tool.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$KIF_READER"

"$PRODUCER" \
    "$ROOT/tests/conformance/modules/stage2-kif-producer/fixtures/interface.kofun" \
    demo/api.kofun "$WORK/interface.kif" 2026 >/dev/null

node --check "$ROOT/tooling/typed-sidecar/documentation-index.mjs"
node --check "$ROOT/tooling/typed-sidecar/documentation-index-cli.mjs"
node --check "$ROOT/tests/docs/documentation_index_test.mjs"
node "$ROOT/tests/docs/documentation_index_test.mjs" \
    "$WORK" "$KIF_READER" "$WORK/interface.kif"

grep -F '## Trust and visibility boundary' \
    "$ROOT/docs/DOCUMENTATION_INDEX.md" >/dev/null ||
    fail 'documentation omits the trust and visibility boundary'
grep -F '## Operating procedure' \
    "$ROOT/docs/DOCUMENTATION_INDEX.md" >/dev/null ||
    fail 'documentation omits the operating procedure'
grep -F '## Limits and failure behavior' \
    "$ROOT/docs/DOCUMENTATION_INDEX.md" >/dev/null ||
    fail 'documentation omits limits and failure behavior'
grep -F 'docs/DOCUMENTATION_INDEX.md' \
    "$ROOT/docs/REPOSITORY_GUIDE.md" >/dev/null ||
    fail 'repository guide does not link the documentation index'

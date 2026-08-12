#!/usr/bin/env sh

set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_ARTIFACT_QUALIFICATION_WORK:-"$ROOT/build/artifact-qualification"}
CC=${CC:-cc}
VALIDATOR="$ROOT/tests/artifact-qualification/validate.mjs"
INVALID="$ROOT/tests/artifact-qualification/make-invalid.mjs"
MEASURE="$ROOT/tests/artifact-qualification/measure.mjs"
KIF_CASES="$ROOT/tests/conformance/modules/kif-v1"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: artifact qualification: $*" >&2
    exit 1
}

case $WORK in
    */artifact-qualification|*/artifact-qualification.*) ;;
    *) fail "work directory must end in artifact-qualification[.suffix]: $WORK" ;;
esac
command -v node >/dev/null 2>&1 || fail 'Node.js is required'
command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
rm -rf "$WORK"
mkdir -p "$WORK/invalid"
kofun_stage2_semantic_common_inputs "$ROOT"

node --check "$VALIDATOR"
node --check "$INVALID"
node --check "$MEASURE"
node "$VALIDATOR"
node "$INVALID" "$WORK/invalid"

negative_count=0
while IFS= read -r name
do
    if node "$VALIDATOR" "$WORK/invalid/$name.json" \
        >"$WORK/invalid/$name.stdout" 2>"$WORK/invalid/$name.stderr"
    then
        fail "negative mutation $name was accepted"
    fi
    if ! grep -F 'Repair:' "$WORK/invalid/$name.stderr" >/dev/null
    then
        fail "negative mutation $name did not name a repair"
    fi
    negative_count=$((negative_count + 1))
done <"$WORK/invalid/names.txt"
if [ "$negative_count" -ne 8 ]
then
    fail "expected 8 negative mutations, ran $negative_count"
fi

KOFUN_STAGE2_COMMON_LINK_ID=artifact-qualification/kif-tool \
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/kif_v1_tool.c" \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
    "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    -o "$WORK/kif-tool"
KOFUN_STAGE2_COMMON_LINK_ID=artifact-qualification/kif-measure \
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/tests/artifact-qualification/kif_measure.c" \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
    "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    -o "$WORK/kif-measure"

printf '%s|%s|%s|%s|%s\n' \
    1111111111111111111111111111111111111111111111111111111111111111 \
    2222222222222222222222222222222222222222222222222222222222222222 \
    3333333333333333333333333333333333333333333333333333333333333333 \
    demo/api.kofun "$KIF_CASES/fixtures/interface.kofun" \
    >"$WORK/interface.inventory"
"$WORK/kif-tool" write "$WORK/interface.inventory" \
    2222222222222222222222222222222222222222222222222222222222222222 \
    edition-1 "$WORK/cold.kif" "$WORK/cold.json"
"$WORK/kif-tool" write "$WORK/interface.inventory" \
    2222222222222222222222222222222222222222222222222222222222222222 \
    edition-1 "$WORK/warm.kif" "$WORK/warm.json"
if ! cmp "$WORK/cold.kif" "$WORK/warm.kif" >/dev/null
then
    fail 'cold and warm KIF bytes differ'
fi

node "$MEASURE" "$WORK/measurements.json" "$WORK/kif-measure" \
    "$WORK/cold.kif" "$WORK/warm.kif"
printf '%s\n' "PASS: $negative_count missing-evidence, widened-authority, future-version, and relaxed-limit mutations fail"

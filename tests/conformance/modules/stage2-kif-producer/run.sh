#!/usr/bin/env sh

set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/modules/stage2-kif-producer"
WORK=${KOFUN_STAGE2_KIF_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}stage2-kif-producer"}
CC=${CC:-cc}
PRODUCER="$WORK/kofun-stage2-kif"
KIF_TOOL="$WORK/kofun-kif-v1"
LOGICAL_PATH=demo/api.kofun
EXTERNAL_PACKAGE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

case $WORK in
    */stage2-kif-producer|*/stage2-kif-producer.*) ;;
    *) fail "work directory must end in stage2-kif-producer[.suffix]: $WORK" ;;
esac
command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
rm -rf "$WORK"
mkdir -p "$WORK/remap-a" "$WORK/remap-b" "$WORK/cli-build"

kofun_stage2_semantic_inputs "$ROOT" library
kofun_stage2_semantic_common_inputs "$ROOT"
KOFUN_STAGE2_COMMON_LINK_ID=stage2-kif-producer/producer \
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/stage2_kif_producer.c" \
    "$KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_EVENTS_INPUT" \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    -o "$PRODUCER"

KOFUN_STAGE2_COMMON_LINK_ID=stage2-kif-producer/reader \
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/kif_v1_tool.c" \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
    "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    -o "$KIF_TOOL"

"$PRODUCER" "$CASES/fixtures/interface.kofun" "$LOGICAL_PATH" \
    "$WORK/interface.kif" 2026
"$PRODUCER" "$CASES/fixtures/interface.kofun" "$LOGICAL_PATH" \
    "$WORK/repeated.kif" 2026
cmp "$WORK/interface.kif" "$WORK/repeated.kif" ||
    fail 'repeated compiler production changed KIF bytes'

"$PRODUCER" "$CASES/fixtures/interface_reordered.kofun" "$LOGICAL_PATH" \
    "$WORK/reordered.kif" 2026
cmp "$WORK/interface.kif" "$WORK/reordered.kif" ||
    fail 'source declaration order changed KIF bytes or digests'

cp "$CASES/fixtures/interface.kofun" "$WORK/remap-a/input.kofun"
cp "$CASES/fixtures/interface.kofun" "$WORK/remap-b/input.kofun"
"$PRODUCER" "$WORK/remap-a/input.kofun" "$LOGICAL_PATH" \
    "$WORK/remap-a/interface.kif" 2026
"$PRODUCER" "$WORK/remap-b/input.kofun" "$LOGICAL_PATH" \
    "$WORK/remap-b/interface.kif" 2026
cmp "$WORK/remap-a/interface.kif" "$WORK/remap-b/interface.kif" ||
    fail 'physical path remap changed KIF bytes or digests'

"$KIF_TOOL" read "$WORK/interface.kif" "$WORK/interface.json"
grep -F '"name": "exported", "visibility": "pub", "parameter_count": 1' \
    "$WORK/interface.json" >/dev/null || fail 'public function fact is absent'
grep -F '"name": "sibling", "visibility": "internal", "parameter_count": 1' \
    "$WORK/interface.json" >/dev/null || fail 'internal function fact is absent'
grep -F '"name": "Some", "visibility": "pub", "payload_count": 1' \
    "$WORK/interface.json" >/dev/null || fail 'public ADT payload fact is absent'
grep -F '"name": "Right", "visibility": "internal", "payload_count": 1' \
    "$WORK/interface.json" >/dev/null || fail 'internal ADT payload fact is absent'
if grep -Eq '"name": "(hidden|HiddenChoice|Invisible|Secret)"' \
    "$WORK/interface.json"
then
    fail 'private compiler fact leaked into KIF'
fi

package_id=$(sed -n \
    's/.*"package_id": "\([0-9a-f]*\)".*/\1/p' \
    "$WORK/interface.json")
if test "${#package_id}" -ne 64; then
    fail 'compiler PackageId is not 32 bytes'
fi
"$KIF_TOOL" resolve "$WORK/interface.kif" "$EXTERNAL_PACKAGE" demo.api \
    "$CASES/fixtures/consumer.kofun" "$WORK/source-free.hir"
grep -F '|qualifier=api|name=exported|' "$WORK/source-free.hir" >/dev/null ||
    fail 'source-free consumer did not resolve the public function'
grep -F '|view=public|' "$WORK/source-free.hir" >/dev/null ||
    fail 'external source-free consumer did not select the public view'

# External labels are semantic signature inputs; internal parameter names are
# deliberately absent. Both facts and both digest views are decoded from KIF,
# so none of these checks can pass by rereading the source.
for variant in base internal_rename public_rename internal_external_rename; do
    "$PRODUCER" "$CASES/fixtures/labels_${variant}.kofun" "$LOGICAL_PATH" \
        "$WORK/labels-${variant}.kif" 2026
    "$KIF_TOOL" read "$WORK/labels-${variant}.kif" \
        "$WORK/labels-${variant}.json"
done
cmp "$WORK/labels-base.kif" "$WORK/labels-internal_rename.kif" ||
    fail 'internal parameter rename changed canonical KIF identity'
grep -F '"parameter_labels": ["in", "from"]' \
    "$WORK/labels-base.json" >/dev/null ||
    fail 'decoded public KIF omitted declaration-order labels'
grep -F '"parameter_labels": ["by"]' "$WORK/labels-base.json" >/dev/null ||
    fail 'decoded internal KIF omitted its external label'
digest_field() {
    field=$1
    file=$2
    sed -n "s/.*\"$field\": \"\([0-9a-f]*\)\".*/\1/p" "$file"
}
base_public=$(digest_field public_semantic_digest "$WORK/labels-base.json")
base_internal=$(digest_field package_internal_semantic_digest \
    "$WORK/labels-base.json")
public_rename_public=$(digest_field public_semantic_digest \
    "$WORK/labels-public_rename.json")
public_rename_internal=$(digest_field package_internal_semantic_digest \
    "$WORK/labels-public_rename.json")
internal_rename_public=$(digest_field public_semantic_digest \
    "$WORK/labels-internal_external_rename.json")
internal_rename_internal=$(digest_field package_internal_semantic_digest \
    "$WORK/labels-internal_external_rename.json")
test "$base_public" != "$public_rename_public" ||
    fail 'public external-label rename preserved the public digest'
test "$base_internal" != "$public_rename_internal" ||
    fail 'public external-label rename preserved the internal digest'
test "$base_public" = "$internal_rename_public" ||
    fail 'internal-only external-label rename changed the public digest'
test "$base_internal" != "$internal_rename_internal" ||
    fail 'internal-only external-label rename preserved the internal digest'

cp "$WORK/interface.kif" "$WORK/prior.kif"
set +e
"$PRODUCER" "$CASES/fixtures/failed.kofun" "$LOGICAL_PATH" \
    "$WORK/interface.kif" 2026 >"$WORK/failed.stdout" 2>"$WORK/failed.stderr"
failed_status=$?
"$PRODUCER" "$CASES/fixtures/unsupported_record.kofun" "$LOGICAL_PATH" \
    "$WORK/interface.kif" 2026 >"$WORK/unsupported.stdout" 2>"$WORK/unsupported.stderr"
unsupported_status=$?
"$PRODUCER" --cancel-after-commit "$CASES/fixtures/interface.kofun" \
    "$LOGICAL_PATH" "$WORK/interface.kif" 2026 \
    >"$WORK/cancel.stdout" 2>"$WORK/cancel.stderr"
cancel_status=$?
set -e
if test "$failed_status" -eq 0; then fail 'failed compile published KIF'; fi
if test "$unsupported_status" -ne 3; then
    fail "unsupported signature status is $unsupported_status, expected 3"
fi
if test "$cancel_status" -ne 1; then
    fail "cancelled compile status is $cancel_status, expected 1"
fi
if test -s "$WORK/cancel.stderr"; then
    fail 'cancelled compile reported a KIF writer error'
fi
grep -F 'error[E2S16]:' "$WORK/failed.stdout" >/dev/null ||
    fail 'failed compile did not retain the compiler diagnostic'
grep -F 'EKI02: KIF v2 does not support record signature publication' \
    "$WORK/unsupported.stderr" >/dev/null ||
    fail 'unsupported signature did not fail explicitly'
cmp "$WORK/prior.kif" "$WORK/interface.kif" ||
    fail 'failure, unsupported publication, or cancellation replaced prior KIF'

set +e
"$PRODUCER" "$CASES/fixtures/failed.kofun" "$LOGICAL_PATH" \
    "$WORK/cold-failed.kif" 2026 >/dev/null 2>&1
"$PRODUCER" "$CASES/fixtures/unsupported_record.kofun" "$LOGICAL_PATH" \
    "$WORK/cold-unsupported.kif" 2026 >/dev/null 2>&1
"$PRODUCER" --cancel-after-commit "$CASES/fixtures/interface.kofun" \
    "$LOGICAL_PATH" "$WORK/cold-cancelled.kif" 2026 >/dev/null 2>&1
set -e
for absent in cold-failed.kif cold-unsupported.kif cold-cancelled.kif; do
    if test -e "$WORK/$absent"; then
        fail "cold unsuccessful production published $absent"
    fi
done

KOFUN_STAGE2_KIF_BUILD_DIR="$WORK/cli-build" \
    "$ROOT/bin/kofun" check "$CASES/fixtures/interface.kofun" \
    --emit-kif "$WORK/cli.kif"
"$KIF_TOOL" read "$WORK/cli.kif" "$WORK/cli.json"
grep -F '"name": "exported", "visibility": "pub"' "$WORK/cli.json" \
    >/dev/null || fail 'normal kofun check path did not emit compiler KIF'

printf '%s\n' \
    'PASS: committed Stage 2 facts publish canonical KIF without an adapter inventory' \
    'PASS: public/internal function and flat-ADT identities are exact and private facts are absent' \
    'PASS: failures, unsupported signatures, and cancellation preserve prior or cold no KIF' \
    'PASS: source order/path remap bytes and source-free resolution are deterministic' \
    'PASS: external labels survive source-free KIF readback and invalidate only their semantic digest views'

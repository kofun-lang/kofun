#!/usr/bin/env sh

set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CASES="$ROOT/tests/diagnostics/fixtures"
POSITIVE="$ROOT/tests/interfaces/fixtures/visibility_ok.kofun"
WORK=${KOFUN_VISIBILITY_DIAGNOSTIC_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}visibility-api-leaks"}
CC=${CC:-cc}
PRODUCER="$WORK/kofun-stage2-kif"
LOGICAL_PATH=demo/api.kofun
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

case $WORK in
    */visibility-api-leaks|*/visibility-api-leaks.*) ;;
    *) fail "work directory must end in visibility-api-leaks[.suffix]: $WORK" ;;
esac
command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
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

"$PRODUCER" "$POSITIVE" "$LOGICAL_PATH" "$WORK/interface.kif" 2026 \
    >/dev/null
cp "$WORK/interface.kif" "$WORK/prior.kif"

for fixture in public_internal_parameter public_private_result \
    internal_private_parameter public_private_payload
do
    set +e
    "$PRODUCER" "$CASES/$fixture.kofun" "$LOGICAL_PATH" \
        "$WORK/interface.kif" 2026 \
        >"$WORK/$fixture.stdout" 2>"$WORK/$fixture.stderr"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$fixture status is $status, expected 1"
    cmp "$CASES/$fixture.expected" "$WORK/$fixture.stdout" ||
        fail "$fixture diagnostic changed"
    test ! -s "$WORK/$fixture.stderr" ||
        fail "$fixture disclosed an internal/tooling error"
    cmp "$WORK/prior.kif" "$WORK/interface.kif" ||
        fail "$fixture replaced the prior interface"
done

for fixture in unsupported_public_record unsupported_ownership \
    unsupported_generic unsupported_effect
do
    set +e
    "$PRODUCER" "$CASES/$fixture.kofun" "$LOGICAL_PATH" \
        "$WORK/interface.kif" 2026 \
        >"$WORK/$fixture.stdout" 2>"$WORK/$fixture.stderr"
    status=$?
    set -e
    test "$status" -eq 3 || fail "$fixture status is $status, expected 3"
    grep -F 'EKI02: KIF v2 does not support' "$WORK/$fixture.stderr" >/dev/null ||
        fail "$fixture was not refused explicitly"
    test ! -s "$WORK/$fixture.stdout" ||
        fail "$fixture reported a misleading language success"
    cmp "$WORK/prior.kif" "$WORK/interface.kif" ||
        fail "$fixture replaced the prior interface"
done

for fixture in public_internal_parameter public_private_result \
    internal_private_parameter public_private_payload \
    unsupported_public_record unsupported_ownership unsupported_generic \
    unsupported_effect
do
    set +e
    "$PRODUCER" "$CASES/$fixture.kofun" "$LOGICAL_PATH" \
        "$WORK/cold-$fixture.kif" 2026 >/dev/null 2>&1
    set -e
    test ! -e "$WORK/cold-$fixture.kif" ||
        fail "$fixture published a cold failure artifact"
done

if grep -Eh 'FileValue|PackageValue' "$WORK"/*.stdout >/dev/null; then
    fail 'visibility diagnostic disclosed a hidden declaration spelling'
fi

printf '%s\n' \
    'PASS: public/internal/private signature leakage matrix is exact' \
    'PASS: E2S145 diagnostics are source-located, deterministic, and non-disclosing' \
    'PASS: record, ownership, generic, and effect publication fail explicitly' \
    'PASS: failed traversal preserves the prior artifact or cold no artifact'

#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CC=${CC:-cc}
WORK=${KOFUN_STAGE2_PROJECTOR_WORK:-"$ROOT/build/stage2-projector"}
FIXTURE="$ROOT/tests/typed-sidecar/fixtures/stage2_events.kofun"
ASSERT_CONTEXT='stage2 projector'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required'
case $WORK in
    */stage2-projector|*/stage2-projector.*) ;;
    *) fail "work directory must end in stage2-projector[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/remap-a" "$WORK/remap-b"

kofun_stage2_semantic_inputs "$ROOT" main
"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_EVENTS_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_SHA256_INPUT" \
    -o "$WORK/kofun-stage2-semantic-events"

"$WORK/kofun-stage2-semantic-events" \
    "$FIXTURE" src/main.kofun "$WORK/complete.kse" 41
"$WORK/kofun-stage2-semantic-events" \
    "$FIXTURE" src/main.kofun "$WORK/generation-a.kse" 42
"$WORK/kofun-stage2-semantic-events" \
    "$FIXTURE" src/main.kofun "$WORK/generation-b.kse" 43
cp "$FIXTURE" "$WORK/remap-a/input.kofun"
cp "$FIXTURE" "$WORK/remap-b/input.kofun"
"$WORK/kofun-stage2-semantic-events" \
    "$WORK/remap-a/input.kofun" src/main.kofun "$WORK/remap-a.kse" 44
"$WORK/kofun-stage2-semantic-events" \
    "$WORK/remap-b/input.kofun" src/main.kofun "$WORK/remap-b.kse" 44

set +e
"$WORK/kofun-stage2-semantic-events" \
    "$ROOT/bootstrap/stage2/function_unknown_error.kofun" \
    src/unknown.kofun "$WORK/partial.kse" 45 >"$WORK/partial.stdout"
partial_status=$?
"$WORK/kofun-stage2-semantic-events" \
    "$ROOT/tests/typed-sidecar/fixtures/stage2_type_error.kofun" \
    src/type-error.kofun "$WORK/type-error.kse" 46 >"$WORK/type-error.stdout"
type_status=$?
"$WORK/kofun-stage2-semantic-events" --check-ownership \
    "$ROOT/bootstrap/stage2/fixtures/borrowed_move_text.kofun" \
    src/ownership.kofun "$WORK/ownership.kse" 47 >"$WORK/ownership.stdout"
ownership_status=$?
"$WORK/kofun-stage2-semantic-events" \
    "$ROOT/tests/conformance/modules/shadowing/duplicate_parameter.kofun" \
    src/duplicate.kofun "$WORK/duplicate.kse" 48 >"$WORK/duplicate.stdout"
duplicate_status=$?
"$WORK/kofun-stage2-semantic-events" --cancel-after-commit \
    "$FIXTURE" src/main.kofun "$WORK/cancelled.kse" 48
cancelled_status=$?
set -e
assert_num "partial status" "$partial_status" -eq 1
assert_num "type status" "$type_status" -eq 1
assert_num "ownership status" "$ownership_status" -eq 1
assert_num "duplicate status" "$duplicate_status" -eq 1
assert_num "cancelled status" "$cancelled_status" -eq 1

node --check "$ROOT/tooling/typed-sidecar/from-stage2.mjs"
node --check "$ROOT/tests/typed-sidecar/stage2_projector_test.mjs"
node "$ROOT/tests/typed-sidecar/stage2_projector_test.mjs" \
    "$WORK" "$FIXTURE"

printf '%s\n' \
    'PASS: Stage 2 semantic events project into canonical typed-sidecar v1'

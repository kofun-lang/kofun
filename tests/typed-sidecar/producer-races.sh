#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CC=${CC:-cc}
WORK=${KOFUN_TYPED_SIDECAR_RACE_WORK:-"$ROOT/build/typed-sidecar-races"}
SOURCE="$ROOT/tests/typed-sidecar/fixtures/stage2_events.kofun"
FAILED_SOURCE="$ROOT/bootstrap/stage2/function_unknown_error.kofun"
ASSERT_CONTEXT='typed-sidecar races'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required'
case $WORK in
    */typed-sidecar-races|*/typed-sidecar-races.*) ;;
    *) fail "work directory must end in typed-sidecar-races[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

kofun_stage2_semantic_inputs "$ROOT" main
"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_EVENTS_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_SHA256_INPUT" \
    -o "$WORK/kofun-stage2-semantic-events"

for generation in 1 2 3
do
    "$WORK/kofun-stage2-semantic-events" \
        "$SOURCE" src/main.kofun \
        "$WORK/generation-$generation.kse" "$generation"
done
"$WORK/kofun-stage2-semantic-events" \
    "$SOURCE" src/other.kofun "$WORK/wrong-file.kse" 4
set +e
"$WORK/kofun-stage2-semantic-events" \
    "$FAILED_SOURCE" src/main.kofun "$WORK/partial-generation-4.kse" 4 \
    >"$WORK/partial.stdout"
partial_status=$?
"$WORK/kofun-stage2-semantic-events" --cancel-after-commit \
    "$SOURCE" src/main.kofun "$WORK/cancelled-generation-5.kse" 5
cancelled_status=$?
set -e
assert_num "partial status" "$partial_status" -eq 1
assert_num "cancelled status" "$cancelled_status" -eq 1

node --check "$ROOT/tests/typed-sidecar/producer_races_test.mjs"
node "$ROOT/tests/typed-sidecar/producer_races_test.mjs" \
    "$WORK" "$SOURCE" "$FAILED_SOURCE"

run_cli() {
    KOFUN_BUILD_DIR="$WORK/cli-build/stage1" \
    KOFUN_STAGE2_BUILD_DIR="$WORK/cli-build/stage2" \
    KOFUN_STAGE2_EVENTS_BUILD_DIR="$WORK/cli-build/events" \
        "$ROOT/bin/kofun" "$@"
}

# Build each compiler before starting contenders so this is a destination-lock
# race, not a compiler-build race.
run_cli check "$SOURCE" \
    --emit-typed-sidecar "$WORK/cli-prewarm.json" --generation 100 \
    >"$WORK/cli-prewarm.stdout" 2>"$WORK/cli-prewarm.stderr"

iteration=1
while test "$iteration" -le 12
do
    low=$((iteration * 10 + 100))
    high=$((low + 1))
    destination="$WORK/cli-race-$iteration.json"
    set +e
    run_cli check "$SOURCE" \
        --emit-typed-sidecar "$destination" --generation "$low" \
        >"$WORK/cli-race-$iteration.low.stdout" \
        2>"$WORK/cli-race-$iteration.low.stderr" &
    low_pid=$!
    run_cli check "$SOURCE" \
        --emit-typed-sidecar "$destination" --generation "$high" \
        >"$WORK/cli-race-$iteration.high.stdout" \
        2>"$WORK/cli-race-$iteration.high.stderr" &
    high_pid=$!
    wait "$low_pid"
    low_status=$?
    wait "$high_pid"
    high_status=$?
    set -e
    test "$high_status" -eq 0 ||
        fail "higher CLI generation exited $high_status"
    case $low_status in
        0) ;;
        3)
            grep -q '^ETS05: ' \
                "$WORK/cli-race-$iteration.low.stderr" ||
                fail "lower CLI generation was not stale"
            ;;
        *)
            fail "lower CLI generation exited $low_status"
            ;;
    esac
    ! grep -q '^ETS06: ' "$WORK/cli-race-$iteration.low.stderr" ||
        fail "lower CLI generation reported a busy lock"
    ! grep -q '^ETS06: ' "$WORK/cli-race-$iteration.high.stderr" ||
        fail "higher CLI generation reported a busy lock"
    node --input-type=module - "$destination" "$high" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import { readTypedSidecar } from "./tooling/typed-sidecar/codec.mjs";
const result = readTypedSidecar(fs.readFileSync(process.argv[2]));
assert.equal(result.ok, true, result.error?.message);
assert.equal(result.document.generation.sequence, Number(process.argv[3]));
NODE
    iteration=$((iteration + 1))
done

printf '%s\n' \
    'PASS: concurrent CLI writers converge on the highest current generation'

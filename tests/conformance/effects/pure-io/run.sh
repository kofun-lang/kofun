#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CC=${CC:-cc}
WORK=${KOFUN_PURE_IO_WORK:-"$ROOT/build/pure-io-effects"}
REPORT="$ROOT/tests/conformance/effects/pure-io/report.mjs"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'Node.js is required'
case $WORK in
    */pure-io-effects|*/pure-io-effects.*) ;;
    *) fail "work directory must end in pure-io-effects[.suffix]: $WORK" ;;
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

project() {
    source=$1
    stem=$2
    logical_path=$3
    "$WORK/kofun-stage2-semantic-events" \
        "$source" "$logical_path" "$WORK/$stem.kse" 1
    node "$ROOT/tooling/typed-sidecar/emit-stage2.mjs" \
        "$WORK/$stem.kse" "$WORK/$stem.json" "$source"
    node "$REPORT" "$WORK/$stem.json" "$source" >"$WORK/$stem.report"
}

project "$ROOT/tests/conformance/effects/pure-io/focus.kofun" \
    focus src/focus.kofun
cmp "$ROOT/tests/conformance/effects/pure-io/focus.expected" \
    "$WORK/focus.report"

project "$ROOT/tests/conformance/effects/pure-io/order-a.kofun" \
    order-a src/order.kofun
project "$ROOT/tests/conformance/effects/pure-io/order-b.kofun" \
    order-b src/order.kofun
cmp "$ROOT/tests/conformance/effects/pure-io/order.expected" \
    "$WORK/order-a.report"
cmp "$WORK/order-a.report" "$WORK/order-b.report"

cp "$ROOT/tests/conformance/effects/pure-io/order-a.kofun" \
    "$WORK/remap-a/input.kofun"
cp "$ROOT/tests/conformance/effects/pure-io/order-a.kofun" \
    "$WORK/remap-b/input.kofun"
project "$WORK/remap-a/input.kofun" remap-a-output src/order.kofun
project "$WORK/remap-b/input.kofun" remap-b-output src/order.kofun
cmp "$WORK/remap-a-output.report" "$WORK/remap-b-output.report"

"$WORK/kofun-stage2-semantic-events" \
    "$ROOT/bootstrap/stage2/functions_fixture.kofun" \
    src/functions.kofun "$WORK/inventory.kse" 1
node "$ROOT/tooling/typed-sidecar/emit-stage2.mjs" \
    "$WORK/inventory.kse" "$WORK/inventory.json" \
    "$ROOT/bootstrap/stage2/functions_fixture.kofun"
node "$REPORT" --inventory "$WORK/inventory.json" \
    "$ROOT/bootstrap/stage2/functions_fixture.kofun" \
    >"$WORK/inventory.report"
cmp "$ROOT/tests/conformance/effects/pure-io/inventory.expected" \
    "$WORK/inventory.report"

set +e
"$WORK/kofun-stage2-semantic-events" \
    "$ROOT/bootstrap/stage2/function_unknown_error.kofun" \
    src/unknown.kofun "$WORK/unknown.kse" 1 \
    >"$WORK/unknown.stdout" 2>"$WORK/unknown.stderr"
unknown_status=$?
set -e
test "$unknown_status" -eq 1 || fail "unknown call exited $unknown_status"
if grep -a 'effect-io-' "$WORK/unknown.kse" >/dev/null 2>&1; then
    fail 'failed unknown-call stream fabricated an effect fact'
fi

printf '%s\n' \
    'PASS: bounded pure/io effects propagate through calls and recursive SCCs' \
    'PASS: effect reports are declaration-order and absolute-path independent' \
    'PASS: tracked Stage 2 corpus is 5 pure / 1 io / 6 total (83.33% pure)' \
    'PASS: typed-sidecar facts retain root/callee explanations'

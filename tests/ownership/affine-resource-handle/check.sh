#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/ownership/affine-resource-handle"
SOURCE="$CASES/transport.kofun"
CC=${CC:-cc}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-affine-resource-handle.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
    printf '%s\n' "affine resource handle: FAIL: $*" >&2
    exit 1
}

compare() {
    label=$1
    expected=$2
    actual=$3
    cmp "$expected" "$actual" || fail "$label differs"
}

require() {
    label=$1
    needle=$2
    file=$3
    grep -Fq -- "$needle" "$file" || fail "$label"
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'

# ---------------------------------------------------------- closed table

test "$(grep -c '^fn affine_transport_' "$SOURCE")" -eq 5 ||
    fail 'the transition table is not exactly read/write/drain/close/cancel'
for transition in read write drain close cancel; do
    require "the closed table lost $transition" \
        "fn affine_transport_$transition(" "$SOURCE"
done
require 'the observing transition is not a read borrow' \
    '    read handle: AffineTransport' "$SOURCE"
test "$(grep -c '    take handle: AffineTransport' "$SOURCE")" -eq 4 ||
    fail 'write/drain/close/cancel do not all receive take authority'
test "$(grep -c '^    take handle$' "$SOURCE")" -eq 4 ||
    fail 'a consuming transition did not end its local handle authority'
if grep -Fq 'edit handle' "$SOURCE"; then
    fail 'the table gained an in-place edit transition'
fi
if grep -Eq 'let own|general ownership' "$SOURCE"; then
    fail 'the bounded table claims the unimplemented general ownership pass'
fi

# ----------------------------------------- reference and Stage 2 execution

. "$ROOT/bootstrap/stage2/build.sh"
kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"

"$WORK/kofun-stage2" \
    "$SOURCE" \
    "$WORK/transport.c" \
    "$WORK/transport.ir" \
    "$WORK/transport.tokens" \
    >"$WORK/compile.stdout" 2>"$WORK/compile.stderr" ||
    fail "Stage 2 rejected the handle: $(cat "$WORK/compile.stdout" "$WORK/compile.stderr")"
test -s "$WORK/transport.c" || fail 'Stage 2 emitted no C11 artifact'
test ! -s "$WORK/compile.stderr" || fail 'Stage 2 wrote internal stderr'

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$WORK/transport.c" -o "$WORK/transport"
"$WORK/transport" >"$WORK/transport.stdout" 2>"$WORK/transport.stderr" ||
    fail 'the Stage 2 C11 handle exited non-zero'
compare 'Stage 2 terminal observations' \
    "$CASES/transport.stdout" "$WORK/transport.stdout"
test ! -s "$WORK/transport.stderr" ||
    fail 'the successful Stage 2 C11 handle wrote stderr'
"$WORK/transport" >"$WORK/transport.repeat.stdout" \
    2>"$WORK/transport.repeat.stderr" ||
    fail 'the repeated Stage 2 C11 handle exited non-zero'
compare 'repeated Stage 2 stdout' \
    "$WORK/transport.stdout" "$WORK/transport.repeat.stdout"
compare 'repeated Stage 2 stderr' \
    "$WORK/transport.stderr" "$WORK/transport.repeat.stderr"

# The standalone record evaluator is the reference backend for this bounded
# source. It does not implement `print`, so derive the library projection by
# deleting only main; every type and transition stays byte-for-byte identical.
sed '/^fn main()/,$d' "$SOURCE" >"$WORK/transport.reference.kofun"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/record_frontend.c" \
    -o "$WORK/record-frontend"
"$WORK/record-frontend" \
    "$WORK/transport.reference.kofun" \
    "$WORK/transport.reference.ir" \
    "$WORK/transport.reference.layout" \
    "$WORK/transport.reference.run" \
    >"$WORK/reference.stdout" 2>"$WORK/reference.stderr" ||
    fail "the reference backend rejected the handle: $(cat "$WORK/reference.stdout" "$WORK/reference.stderr")"
test ! -s "$WORK/reference.stdout" || fail 'the reference backend wrote stdout'
test ! -s "$WORK/reference.stderr" || fail 'the reference backend wrote stderr'
compare 'reference transition observations' \
    "$CASES/transport.reference" "$WORK/transport.reference.run"

# -------------------------------------------- host-boundary runtime backstop

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$CASES/runtime_model.c" -o "$WORK/runtime-model"
"$WORK/runtime-model" normal \
    >"$WORK/model.stdout" 2>"$WORK/model.stderr" ||
    fail 'the host-boundary model rejected the valid table'
compare 'runtime model and generated C11 observations' \
    "$CASES/transport.stdout" "$WORK/model.stdout"
test ! -s "$WORK/model.stderr" || fail 'the valid runtime model wrote stderr'

expect_runtime_refusal() {
    mode=$1
    set +e
    "$WORK/runtime-model" "$mode" \
        >"$WORK/$mode.stdout" 2>"$WORK/$mode.stderr"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$mode exited $status instead of 1"
    test ! -s "$WORK/$mode.stdout" || fail "$mode published partial stdout"
    compare "$mode EARH01" "$CASES/earh01.stderr" "$WORK/$mode.stderr"
}

expect_runtime_refusal dead-generation
expect_runtime_refusal duplicate-owner

# ----------------------------------------------- existing static refusals

expect_stage2_refusal() {
    stem=$1
    set +e
    "$WORK/kofun-stage2" \
        "$CASES/$stem.kofun" \
        "$WORK/$stem.c" \
        "$WORK/$stem.ir" \
        "$WORK/$stem.tokens" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$stem exited $status instead of 1"
    compare "$stem E2S123" "$CASES/$stem.diagnostic" "$WORK/$stem.stdout"
    test ! -s "$WORK/$stem.stderr" || fail "$stem wrote internal stderr"
    test ! -e "$WORK/$stem.c" || fail "$stem emitted rejected C"
    require "$stem did not use the registered move code" \
        'error[E2S123]:' "$WORK/$stem.stdout"
}

expect_stage2_refusal use_after_write
expect_stage2_refusal double_terminal
expect_stage2_refusal read_after_cancel

printf '%s\n' \
    'PASS: read/write/drain/close/cancel form one closed per-type affine table' \
    'PASS: reference evaluation, Stage 2 C11, and the host model agree on terminal and reuse observations' \
    'PASS: use after write, double terminal transition, and read after cancel refuse as E2S123' \
    'PASS: dead and adversarially duplicated generations refuse as EARH01 with no partial output'

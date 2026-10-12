#!/usr/bin/env sh
# #1698. The HTTP headers carrier: `Header = {name: Bytes, value: Bytes}` and a
# bounded `List[Header]` at the capacity-128 profile row #1695 added, now with
# a validated append.
#
# `stage2_list_append(list, element)` edits the list in place and moves the
# element record into the next slot by value. It has no source value, like the
# Bytes mutations, and a full list is the runtime diagnostic R038, so the
# 129th entry is never written.
#
# What is proved, one block per acceptance line:
#
#   1. an empty annotated list takes appends in order; `len` and `headers[i]`
#      read them back, and a `Bytes` field reads through the borrowed view;
#   2. a lookup by name finds the first matching entry and reads its value;
#   3. a list built by appends moves whole through a function parameter;
#   4. exactly 128 appends fill the list, and the 129th is R038 with exit 1
#      and nothing printed after it;
#   5. a bound result (E2S179), a `List[Int]` target (E2S15), and an element of
#      another record type (E2S15) are refused before any C;
#   6. both halves of the pair agree on outcome, emitted C, and scope HIR for
#      every source above.
#
# The carrier measures nothing for the 65,536-byte header-block total: #1258
# Q3(b) charges that on the wire, in the #1261/#1262 producers.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/http-client-headers"
WORK=${KOFUN_HTTP_CLIENT_HEADERS_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}http-client-headers"}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: http client headers: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the pair check'
case $WORK in
    */http-client-headers|*/http-client-headers.*) ;;
    *) fail "work directory must end in http-client-headers[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

COMPILER="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$COMPILER"

build() {
    program=$1
    source=$2
    "$COMPILER" --compile-outcome \
        "$source" "$program.c" "$program.ir" "$program.tokens" \
        >"$program.build.stdout" 2>"$program.build.stderr" ||
        fail "$(basename "$source") did not compile: $(head -n 1 "$program.build.stdout")"
    if test -s "$program.build.stderr"; then
        fail "$(basename "$source") wrote internal stderr"
    fi
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        "$program.c" -o "$program" 2>"$program.cc" ||
        fail "$(basename "$source") emitted C that does not compile: $(head -n 1 "$program.cc")"
}

expect_stdout() {
    stem=$1
    shift
    printf '%s\n' "$@" >"$WORK/$stem.expected"
    "$WORK/$stem" >"$WORK/$stem.stdout" ||
        fail "$stem exited non-zero"
    if ! cmp -s "$WORK/$stem.expected" "$WORK/$stem.stdout"; then
        diff "$WORK/$stem.expected" "$WORK/$stem.stdout" >&2 || true
        fail "$stem printed the wrong output"
    fi
}

# 1. Append, length, index, and a borrowed field read.
build "$WORK/append_index" "$CASES/append_index.kofun"
grep -Fq '((KofunRecordList_Header){0})' "$WORK/append_index.c" ||
    fail 'the empty annotated list did not lower to the empty carrier'
grep -Fq 'error[R038]' "$WORK/append_index.c" ||
    fail 'the append did not lower with its R038 capacity check'
expect_stdout append_index 0 2 host accept

# 2. Lookup by name.
build "$WORK/lookup" "$CASES/lookup.kofun"
expect_stdout lookup 1 '*/*'

# 3. Move whole after appends.
build "$WORK/move" "$CASES/move.kofun"
expect_stdout move 3

# 4. Capacity: 128 fit, the 129th is R038.
build "$WORK/full" "$CASES/full.kofun"
expect_stdout full 128
build "$WORK/over_capacity" "$CASES/over_capacity.kofun"
over_status=0
"$WORK/over_capacity" >"$WORK/over_capacity.stdout" \
    2>"$WORK/over_capacity.stderr" || over_status=$?
test "$over_status" -eq 1 ||
    fail "the 129th append exited $over_status, not 1"
if test -s "$WORK/over_capacity.stdout"; then
    fail 'the program printed after the R038 refusal'
fi
cmp -s "$CASES/over_capacity.stderr" "$WORK/over_capacity.stderr" ||
    fail "the 129th append did not report R038: $(head -n 1 "$WORK/over_capacity.stderr")"

# 5. Compile-time refusals, with no C emitted.
refuse() {
    stem=$1
    code=$2
    status=0
    "$COMPILER" --compile-outcome \
        "$CASES/$stem.kofun" "$WORK/$stem.c" "$WORK/$stem.ir" "$WORK/$stem.tokens" \
        >"$WORK/$stem.out" 2>"$WORK/$stem.err" || status=$?
    test "$status" -ne 0 || fail "$stem was accepted"
    grep -Fq "error[$code]" "$WORK/$stem.out" ||
        fail "$stem was not refused $code: $(head -n 1 "$WORK/$stem.out")"
    if test -e "$WORK/$stem.c"; then
        fail "$stem emitted C despite the refusal"
    fi
}
refuse value_refused E2S179
refuse int_list_refused E2S15
refuse element_refused E2S15
grep -Fq 'cannot append Other to List[Header]' "$WORK/element_refused.out" ||
    fail "the element refusal does not name both types: $(head -n 1 "$WORK/element_refused.out")"

# 6. Both halves agree.
node "$ROOT/tests/conformance/record-list/pair.mjs" "$COMPILER" "$WORK/pair" \
    "$CASES/append_index.kofun" \
    "$CASES/lookup.kofun" \
    "$CASES/move.kofun" \
    "$CASES/full.kofun" \
    "$CASES/over_capacity.kofun" \
    "$CASES/value_refused.kofun" \
    "$CASES/int_list_refused.kofun" \
    "$CASES/element_refused.kofun" ||
    fail 'the two halves disagree'

printf '%s\n' 'PASS: List[Header] appends to capacity 128, reads, indexes, looks up by name, moves whole, refuses the 129th with R038, and both halves agree'

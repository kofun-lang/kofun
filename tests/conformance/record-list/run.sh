#!/usr/bin/env sh
# #1695. A bounded list of nominal records at capacity 128: it constructs,
# indexes, moves whole, and refuses a copy.
#
# The profile row #1258 Q3(a) chose is per element type: `List[Int]` keeps
# capacity 64, `List[Header]` gets capacity 128, so the carrier is
# `{ uint64_t length; KofunRecord_Header elements[128]; }` (6,152 bytes,
# 8-aligned, managed). Capacity stays part of type identity by naming it in the
# element type's profile row.
#
# Four things are proved, one per acceptance line:
#
#   1. `List[Header]` at capacity 128 constructs and `len` reads its length;
#   2. `headers[i]` yields the element record and `headers[i].name` reads the
#      field as a borrowed `read` view;
#   3. the list moves whole through a function parameter;
#   4. a copy is refused `E2S170` with no C emitted, and both halves of the
#      pair agree on outcome, emitted C, and scope HIR.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/record-list"
WORK=${KOFUN_RECORD_LIST_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}record-list"}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: record list: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the pair check'
case $WORK in
    */record-list|*/record-list.*) ;;
    *) fail "work directory must end in record-list[.suffix]: $WORK" ;;
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
    test ! -s "$program.build.stderr" ||
        fail "$(basename "$source") wrote internal stderr"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        "$program.c" -o "$program" 2>"$program.cc" ||
        fail "$(basename "$source") emitted C that does not compile: $(head -n 1 "$program.cc")"
}

# 1. Construction and length, with the profile's capacity-128 carrier.
build "$WORK/construct" "$CASES/construct.kofun"
grep -Fq 'KofunRecordList_Header' "$WORK/construct.c" ||
    fail 'the record-list carrier was not emitted'
grep -Fq 'elements[128]' "$WORK/construct.c" ||
    fail 'the record-list capacity is not 128'
"$WORK/construct" >"$WORK/construct.stdout"
test "$(cat "$WORK/construct.stdout")" = "2" ||
    fail 'the list length was not 2'

# 2. Index and a borrowed field read.
build "$WORK/index" "$CASES/index.kofun"
grep -Fq 'elements[INT64_C(0)].f_name' "$WORK/index.c" ||
    fail 'the field read did not lower through the indexed element'
"$WORK/index" >"$WORK/index.stdout"
printf '2\n0\n' >"$WORK/index.expected"
cmp "$WORK/index.expected" "$WORK/index.stdout" ||
    fail 'the indexed field read printed the wrong bytes'

# 3. Move whole through a function parameter.
build "$WORK/move" "$CASES/move.kofun"
"$WORK/move" >"$WORK/move.stdout"
test "$(cat "$WORK/move.stdout")" = "2" ||
    fail 'the moved list did not reach the callee'

# 4. Copy refused.
"$COMPILER" --compile-outcome \
    "$CASES/copy_refused.kofun" "$WORK/copy.c" "$WORK/copy.ir" "$WORK/copy.tokens" \
    >"$WORK/copy.out" 2>"$WORK/copy.err" &&
    fail 'a managed record-list copy was accepted'
grep -Fq 'error[E2S170]' "$WORK/copy.out" ||
    fail "the copy was not refused E2S170: $(head -n 1 "$WORK/copy.out")"
test ! -e "$WORK/copy.c" ||
    fail 'the copy emitted C despite the refusal'

node "$CASES/pair.mjs" "$COMPILER" "$WORK/pair" \
    "$CASES/construct.kofun" \
    "$CASES/index.kofun" \
    "$CASES/move.kofun" \
    "$CASES/copy_refused.kofun" ||
    fail 'the two halves disagree'

printf '%s\n' 'PASS: a bounded record list at capacity 128 constructs, indexes, moves whole, and refuses a copy; both halves agree'

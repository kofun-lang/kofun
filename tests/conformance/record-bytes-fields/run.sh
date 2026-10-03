#!/usr/bin/env sh
# #1694. A `Bytes` field in a nominal record: it constructs, is read through a
# borrowed `read` view, moves whole, and cleans up; a copy is refused.
#
# The owner decision recorded on #1694 is that a read of a `Bytes` record field
# lowers as a non-escaping `read` view of the carrier the record still owns. So
# `stage2_bytes_len(header.name)` emits `&<record>.<field>` and leaves the
# record the owner, and a second binding initialized from the record is an
# alias of unique-owner storage, refused `E2S170`.
#
# Four things are proved, and each is one acceptance line:
#
#   1. the field declaration and construction lower, with the AggregateLayout
#      field offsets (0, 24) and record size (48) asserted in the emitted C;
#   2. the field reads as a borrowed view and the program runs;
#   3. the record moves whole through a `take` parameter and the callee reads
#      the field it now owns;
#   4. both the inferred and the annotated copy spellings are refused `E2S170`
#      with no C emitted, and both halves of the pair agree on outcome, emitted
#      C, and scope HIR.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/record-bytes-fields"
WORK=${KOFUN_RECORD_BYTES_FIELDS_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}record-bytes-fields"}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: record bytes fields: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the pair check'
case $WORK in
    */record-bytes-fields|*/record-bytes-fields.*) ;;
    *) fail "work directory must end in record-bytes-fields[.suffix]: $WORK" ;;
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

# 1. Construction and layout.
build "$WORK/construct_read" "$CASES/construct_read.kofun"
grep -Fq 'offsetof(KofunRecord_Header, f_name) == 0' "$WORK/construct_read.c" ||
    fail 'the first Bytes field is not at offset 0'
grep -Fq 'offsetof(KofunRecord_Header, f_value) == 24' "$WORK/construct_read.c" ||
    fail 'the second Bytes field is not at offset 24'
grep -Fq 'sizeof(KofunRecord_Header) == 48' "$WORK/construct_read.c" ||
    fail 'the record size is not 48'

# 2. Read through a borrowed view: the address of the field, not a copy.
grep -Fq 'stage2_bytes_len(&k_b2.f_name)' "$WORK/construct_read.c" ||
    fail 'the field read did not lower to a borrowed view address'
"$WORK/construct_read" >"$WORK/construct_read.stdout"
test "$(cat "$WORK/construct_read.stdout")" = "0" ||
    fail 'the borrowed read did not print the empty carrier length'

# 3. Move whole through a take parameter.
build "$WORK/move_whole" "$CASES/move_whole.kofun"
"$WORK/move_whole" >"$WORK/move_whole.stdout"
test "$(cat "$WORK/move_whole.stdout")" = "0" ||
    fail 'the moved record did not read its field'

# 4. Both copy spellings refuse E2S170 before any C.
for stem in copy_refused copy_annotated_refused; do
    "$COMPILER" --compile-outcome \
        "$CASES/$stem.kofun" "$WORK/$stem.c" "$WORK/$stem.ir" "$WORK/$stem.tokens" \
        >"$WORK/$stem.out" 2>"$WORK/$stem.err" && \
        fail "$stem was accepted, but a managed-record copy must be refused"
    grep -Fq 'error[E2S170]' "$WORK/$stem.out" ||
        fail "$stem did not report E2S170: $(head -n 1 "$WORK/$stem.out")"
    test ! -e "$WORK/$stem.c" ||
        fail "$stem emitted C despite the refusal"
done

node "$CASES/pair.mjs" "$COMPILER" "$WORK/pair" \
    "$CASES/construct_read.kofun" \
    "$CASES/move_whole.kofun" \
    "$CASES/copy_refused.kofun" \
    "$CASES/copy_annotated_refused.kofun" ||
    fail 'the two halves disagree'

printf '%s\n' 'PASS: a Bytes record field constructs, reads as a borrowed view, moves whole, and refuses a copy; both halves agree'

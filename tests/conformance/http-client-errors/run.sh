#!/usr/bin/env sh
# #1697. The closed HttpError ADT on C11 Stage 2, and the flat record-payload
# slice it needed (spec/adt-record-payload-v1.md, carved out under #30 by
# #1258's Q1(c)).
#
# `HttpError` is four constructors (the #1257 oracle's `protocol`,
# `limit-exceeded`, `body-truncated`, and `transport`), each carrying one flat
# record that holds an `Int` phase code and a `Bool` `retry_safe` beside the
# fields its kind needs. Stage 2 carried a constructor payload of exactly one
# `Int`; this gate proves the widening it received and where that widening stops.
#
# What is proved, one block per acceptance line:
#
#   1. the carrier declaration in every fixture is byte-identical to the one the
#      contract's `http_carrier.error` rows render, and that registry is the
#      oracle's own kind and phase vocabulary;
#   2. all four kinds construct, match, and read their phase, `retry_safe`, and
#      kind-specific fields back, across function boundaries, in a value-position
#      match, beside a one-`Int` enum, and with one record seeding two errors;
#   3. the emitted C widens the enum value only for a source that declares a
#      record payload: every other enum is emitted exactly as before;
#   4. every error the #1257 oracle can produce, deadline included, projects onto
#      an `HttpError` whose compiled program prints exactly what the oracle's own
#      results and the registry say;
#   5. each edge of the slice is refused with its exact diagnostic and no C: a
#      wrong record, an `Int` or an inline construction for a record, a missing
#      payload or binding, a missing kind, a payload record with a `Text` or
#      `List[Int]` field, a two-field payload, and an enum-typed record field;
#   6. the checked-capture HIR emitters refuse a record payload on both sides
#      rather than typing it as an `Int`;
#   7. both halves of the pair agree on outcome, emitted C, and scope HIR for
#      every source above, generated projection included. The value-position
#      match is the exception, held on outcome, emitted C, and tokens only,
#      because the halves already differ on value matches on origin/main.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/http-client-errors"
WORK=${KOFUN_HTTP_CLIENT_ERRORS_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}http-client-errors"}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: http client errors: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the registry and pair checks'
case $WORK in
    */http-client-errors|*/http-client-errors.*) ;;
    *) fail "work directory must end in http-client-errors[.suffix]: $WORK" ;;
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

# 1. The declaration every fixture carries is the contract's, and the registry
#    is the oracle's vocabulary.
node "$CASES/check-registry.mjs" block \
    "$CASES/construct_match.kofun" \
    "$CASES/payload_fields.kofun" \
    "$CASES/function_boundary.kofun" \
    "$CASES/value_match.kofun" \
    "$CASES/mixed_int_payload.kofun" \
    "$CASES/detail_reuse.kofun" \
    "$CASES/payload_wrong_record_refused.kofun" \
    "$CASES/payload_int_refused.kofun" \
    "$CASES/payload_inline_construction_refused.kofun" \
    "$CASES/payload_missing_refused.kofun" \
    "$CASES/pattern_arity_refused.kofun" \
    "$CASES/non_exhaustive_refused.kofun" ||
    fail 'a fixture declares an HttpError other than the contract'"'"'s'

# The block check is not decorative: a field edited by hand is refused.
sed 's/    offset: Int,/    offset: Bool,/' "$CASES/construct_match.kofun" >"$WORK/drifted.kofun"
if cmp -s "$CASES/construct_match.kofun" "$WORK/drifted.kofun"; then
    fail 'the drifted declaration is identical to the fixture, so it proves nothing'
fi
if node "$CASES/check-registry.mjs" block "$WORK/drifted.kofun" >"$WORK/drifted.out" 2>&1; then
    fail 'a fixture with a hand-edited HttpError field was accepted'
fi

# 2. Construction, match, and the fields each kind carries.
build "$WORK/construct_match" "$CASES/construct_match.kofun"
expect_stdout construct_match 1 2 0 2 2 0 3 3 0 4 1 1
build "$WORK/payload_fields" "$CASES/payload_fields.kofun"
expect_stdout payload_fields 17 5 38 3 6553665537 -1
build "$WORK/function_boundary" "$CASES/function_boundary.kofun"
expect_stdout function_boundary 2 1 3 1 0 0 4
build "$WORK/value_match" "$CASES/value_match.kofun"
expect_stdout value_match 17 200 1 2
build "$WORK/mixed_int_payload" "$CASES/mixed_int_payload.kofun"
expect_stdout mixed_int_payload 5 100 17
build "$WORK/detail_reuse" "$CASES/detail_reuse.kofun"
expect_stdout detail_reuse 17 17 34
build "$WORK/two_enums" "$CASES/two_enums.kofun"
expect_stdout two_enums 7 70 7 9 -1 7 2

# 3. The widened enum value, and only where a record payload asks for it.
grep -Fq 'KofunRecord_ProtocolDetail payload_Protocol;' "$WORK/construct_match.c" ||
    fail 'the enum value does not carry the Protocol record as a union member'
grep -Fq '{.tag = INT64_C(0), .payload_Protocol = k_b' "$WORK/construct_match.c" ||
    fail 'the constructor did not lower to a named record initializer'
grep -Fq '= kofun_match_value.payload_Protocol;' "$WORK/construct_match.c" ||
    fail 'a match arm did not read the record back from its union member'
grep -Fq '.tag = INT64_C(1), .payload = kofun_add(' "$WORK/mixed_int_payload.c" ||
    fail 'a one-Int constructor beside a record payload did not use the named initializer'
build "$WORK/classic" "$ROOT/tests/conformance/adt/enum_payload_functions.kofun"
grep -Fq '    int64_t payload;' "$WORK/classic.c" ||
    fail 'a source with no record payload lost its two-word enum value'
if grep -Fq 'union' "$WORK/classic.c" || grep -Fq '.tag = INT64_C' "$WORK/classic.c"; then
    fail 'a source with no record payload was emitted with the widened enum value'
fi

# 4. Every oracle error, deadline included, as an HttpError.
node "$CASES/check-registry.mjs" project "$WORK/projection" ||
    fail 'the oracle projection could not be generated'
build "$WORK/projection/projection" "$WORK/projection/projection.kofun"
"$WORK/projection/projection" >"$WORK/projection/projection.stdout" ||
    fail 'the projection program exited non-zero'
cmp -s "$WORK/projection/projection.expected" "$WORK/projection/projection.stdout" ||
    fail 'the projection printed something other than the oracle and the registry say'
build "$WORK/projection/distinct" "$WORK/projection/distinct.kofun"
"$WORK/projection/distinct" >"$WORK/projection/distinct.stdout" ||
    fail 'the distinct projection program exited non-zero'
cmp -s "$WORK/projection/distinct.expected" "$WORK/projection/distinct.stdout" ||
    fail 'the distinct projection printed something other than the oracle and the registry say'

# 5. Every edge of the slice, with its exact diagnostic and no C.
refused=0
while IFS="$(printf '\t')" read -r stem expected; do
    status=0
    "$COMPILER" --compile-outcome \
        "$CASES/$stem.kofun" "$WORK/$stem.c" "$WORK/$stem.ir" "$WORK/$stem.tokens" \
        >"$WORK/$stem.out" 2>"$WORK/$stem.err" || status=$?
    test "$status" -ne 0 || fail "$stem was accepted"
    test "$(cat "$WORK/$stem.out")" = "$expected" ||
        fail "$stem was refused with: $(head -n 1 "$WORK/$stem.out")"
    if test -s "$WORK/$stem.err"; then
        fail "$stem wrote internal stderr"
    fi
    if test -e "$WORK/$stem.c"; then
        fail "$stem emitted C despite the refusal"
    fi
    refused=$((refused + 1))
done <"$CASES/refusals.tsv"
test "$refused" -eq 10 || fail "expected 10 refusals, ran $refused"

# 6 and 7. The capture HIR refusal, and both halves of the pair.
node "$CASES/capture.mjs" "$COMPILER" "$WORK/capture" \
    "$CASES/construct_match.kofun" \
    "$CASES/function_boundary.kofun" ||
    fail 'the capture HIR emitters disagree about a record payload'
node "$CASES/value_match_pair.mjs" "$COMPILER" "$WORK/value-match-pair" \
    "$CASES/value_match.kofun" ||
    fail 'the two halves disagree on the value-position match'
node "$ROOT/tests/conformance/record-list/pair.mjs" "$COMPILER" "$WORK/pair" \
    "$CASES/construct_match.kofun" \
    "$CASES/payload_fields.kofun" \
    "$CASES/function_boundary.kofun" \
    "$CASES/mixed_int_payload.kofun" \
    "$CASES/detail_reuse.kofun" \
    "$CASES/two_enums.kofun" \
    "$CASES/payload_wrong_record_refused.kofun" \
    "$CASES/payload_int_refused.kofun" \
    "$CASES/payload_inline_construction_refused.kofun" \
    "$CASES/payload_missing_refused.kofun" \
    "$CASES/pattern_arity_refused.kofun" \
    "$CASES/non_exhaustive_refused.kofun" \
    "$CASES/payload_text_field_refused.kofun" \
    "$CASES/payload_list_field_refused.kofun" \
    "$CASES/payload_two_fields_refused.kofun" \
    "$CASES/payload_enum_field_refused.kofun" \
    "$ROOT/tests/conformance/adt/enum_payload_functions.kofun" \
    "$WORK/projection/distinct.kofun" ||
    fail 'the two halves disagree'

printf '%s\n' 'PASS: HttpError is the four-kind closed ADT, each kind carrying phase, retry_safe, and its own fields; every oracle error projects onto it; the record-payload slice stops where it says; and both halves agree'

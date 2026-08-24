#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/records"
CC=${CC:-cc}
WORK=${KOFUN_RECORD_FRONTEND_WORK:-"$ROOT/build/record-frontend"}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
case $WORK in
    */record-frontend|*/record-frontend.*) ;;
    *) fail "work directory must end in record-frontend[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/record_frontend.c" \
    -o "$WORK/kofun-record-frontend"

frontend() {
    stem=$1
    label=$2
    "$WORK/kofun-record-frontend" "$CASES/$stem.kofun" \
        "$WORK/$label.ir" "$WORK/$label.layout" "$WORK/$label.run"
}

require_line() {
    file=$1
    needle=$2
    grep -Fq "$needle" "$file" || fail "$file does not contain: $needle"
}

# ------------------------------------------------------------------ tokens
# The Token-shaped record is the accepted proof: an enumeration, a `Text`, and
# an `Int` field constructed, passed, returned, and read by a real scanner.

frontend token_pipeline token_pipeline
frontend token_pipeline token_pipeline.second
for artifact in ir layout run; do
    cmp "$WORK/token_pipeline.$artifact" \
        "$WORK/token_pipeline.second.$artifact" ||
        fail "repeated record $artifact differs"
    cmp "$CASES/token_pipeline.$artifact" \
        "$WORK/token_pipeline.$artifact" ||
        fail "token pipeline $artifact golden differs"
done

require_line "$WORK/token_pipeline.ir" \
    'record|record-id=record:Token|name=Token'
require_line "$WORK/token_pipeline.ir" \
    'field|field-id=field:record:Token:0|record-id=record:Token|name=kind|index=0|type=TokenKind'
require_line "$WORK/token_pipeline.ir" \
    'field|field-id=field:record:Token:2|record-id=record:Token|name=start|index=2|type=Int'

# Written field order is free; declaration order is the stored order.
require_line "$WORK/token_pipeline.ir" \
    'written=kind,text,start|declared=kind,text,start'
require_line "$WORK/token_pipeline.ir" \
    'written=start,kind,text|declared=kind,text,start'

# Every field read carries the declared field type, not an inferred one.
require_line "$WORK/token_pipeline.ir" \
    'read|function=describe|record-id=record:Token|field-id=field:record:Token:0|name=kind|type=TokenKind'
require_line "$WORK/token_pipeline.ir" \
    'read|function=width|record-id=record:Token|field-id=field:record:Token:1|name=text|type=Text'
require_line "$WORK/token_pipeline.ir" \
    'read|function=last_start|record-id=record:Token|field-id=field:record:Token:2|name=start|type=Int'

# Records pass and return across function boundaries under `read` access.
require_line "$WORK/token_pipeline.ir" \
    'param|function=describe|index=0|name=token|type=Token|access=read'
require_line "$WORK/token_pipeline.ir" \
    'function|name=scan|params=1|result=List[Token]'

# ------------------------------------------------------------------ layout
# Layout is untagged, declaration ordered, and named per target data layout.

for target in x86_64-linux aarch64-linux; do
    require_line "$WORK/token_pipeline.layout" \
        "target|name=$target|data-layout=little-endian LP64;"
    require_line "$WORK/token_pipeline.layout" \
        "record|target=$target|record-id=record:Token|size=32|align=8|payload=25|tagged=false|fields=3"
    require_line "$WORK/token_pipeline.layout" \
        "field|target=$target|record-id=record:Token|index=0|name=kind|type=TokenKind|offset=0|size=1|align=1"
    require_line "$WORK/token_pipeline.layout" \
        "field|target=$target|record-id=record:Token|index=2|name=start|type=Int|offset=24|size=8|align=8"
done
require_line "$WORK/token_pipeline.layout" \
    'agreement|record-id=record:Token|targets=x86_64-linux,aarch64-linux|identical=true'

# The agreement line is a claim; recompute it from the emitted rows instead of
# trusting it.
grep -E '^(record|field)\|target=x86_64-linux\|' "$WORK/token_pipeline.layout" |
    sed 's/|target=x86_64-linux|/|/' >"$WORK/layout.x86_64"
grep -E '^(record|field)\|target=aarch64-linux\|' "$WORK/token_pipeline.layout" |
    sed 's/|target=aarch64-linux|/|/' >"$WORK/layout.aarch64"
cmp "$WORK/layout.x86_64" "$WORK/layout.aarch64" ||
    fail 'x86-64 and AArch64 record layout disagree'
test -s "$WORK/layout.x86_64" || fail 'no per-target layout rows were emitted'

# ------------------------------------------------------------- evaluation
# Construct, pass, return, and read are observed, not asserted.

require_line "$WORK/token_pipeline.run" \
    'call|function=first_token|result=Token(kind: TokenKind.Identifier, text: "let", start: 0)'
require_line "$WORK/token_pipeline.run" \
    'call|function=scanned|result=[Token(kind: TokenKind.Identifier, text: "let", start: 0), Token(kind: TokenKind.Identifier, text: "x", start: 4), Token(kind: TokenKind.Symbol, text: "=", start: 6), Token(kind: TokenKind.Number, text: "42", start: 8)]'
require_line "$WORK/token_pipeline.run" \
    'call|function=summary|result="id:let id:x sym:= num:42 "'
require_line "$WORK/token_pipeline.run" 'call|function=total_width|result=7'
require_line "$WORK/token_pipeline.run" 'call|function=final_start|result=8'

# ------------------------------------------------------------- ambiguity
# Blocks, conditions, loop iterables, list literals, and flat constructors stay
# separable from record construction.

frontend ambiguity ambiguity
frontend declaration_order declaration_order
cmp "$CASES/ambiguity.run" "$WORK/ambiguity.run" ||
    fail 'ambiguity evaluation golden differs'
cmp "$CASES/ambiguity.layout" "$WORK/ambiguity.layout" ||
    fail 'ambiguity layout golden differs'
cmp "$CASES/declaration_order.run" "$WORK/declaration_order.run" ||
    fail 'declaration order evaluation golden differs'
require_line "$WORK/ambiguity.run" 'call|function=counted|result=3'
require_line "$WORK/ambiguity.run" \
    'call|function=pair|result=[Point(x: 1, y: 2), Point(x: 6, y: 8)]'
require_line "$WORK/ambiguity.run" 'call|function=flagged|result=1'

# Nominal identity does not depend on declaration order, and a construction
# written out of order still stores fields in declaration order.
for stem in ambiguity declaration_order; do
    grep -E '^(record|field)\|' "$WORK/$stem.ir" |
        sed 's/|span=[0-9][0-9]*\.\.[0-9][0-9]*//' >"$WORK/$stem.ids"
done
cmp "$WORK/ambiguity.ids" "$WORK/declaration_order.ids" ||
    fail 'declaration order changed nominal record or field identities'
require_line "$WORK/declaration_order.run" \
    'call|function=shifted|result=Point(x: 2, y: 1)'

# ------------------------------------------------------------ diagnostics

expect_failure() {
    stem=$1
    code=$2
    set +e
    "$WORK/kofun-record-frontend" "$CASES/$stem.kofun" \
        "$WORK/$stem.ir" "$WORK/$stem.layout" "$WORK/$stem.run" \
        >"$WORK/$stem.actual" 2>"$WORK/$stem.internal.stderr"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$stem exited $status instead of 1"
    test ! -s "$WORK/$stem.internal.stderr" ||
        fail "$stem wrote internal stderr"
    test ! -e "$WORK/$stem.ir" || fail "$stem emitted rejected IR"
    test ! -e "$WORK/$stem.layout" || fail "$stem emitted rejected layout"
    test ! -e "$WORK/$stem.run" || fail "$stem emitted rejected evaluation"
    cmp "$CASES/$stem.stderr" "$WORK/$stem.actual" ||
        fail "$stem diagnostic differs"
    grep -F "error[$code]:" "$WORK/$stem.actual" >/dev/null ||
        fail "$stem expected $code"
    printf '%s\n' "PASS record diagnostic: $stem"
}

expect_failure bound_exceeded E2S106
expect_failure malformed_return E2S107
expect_failure duplicate_type E2S108
expect_failure duplicate_declared_field E2S109
expect_failure unknown_field_type E2S110
expect_failure generic_record E2S111
expect_failure recursive_record E2S112
expect_failure unknown_name E2S113
expect_failure duplicate_construction_field E2S114
expect_failure missing_field E2S115
expect_failure unknown_field E2S116
expect_failure wrong_field_type E2S117
expect_failure positional_construction E2S118
expect_failure brace_construction E2S119
expect_failure unknown_field_read E2S120
expect_failure field_assignment E2S121
expect_failure edit_parameter E2S121
expect_failure partial_move E2S122
expect_failure use_after_move E2S123
expect_failure double_take E2S123
expect_failure move_borrowed E2S122
expect_failure argument_type_mismatch E2S124
expect_failure map_literal E2S125
expect_failure evaluation_failure E2S126

# Every diagnostic case must be exercised: an unlisted fixture is a gap.
for source in "$CASES"/*.stderr; do
    stem=$(basename "$source" .stderr)
    test -f "$WORK/$stem.actual" || fail "diagnostic fixture $stem is not run"
done

test -z "$(find "$WORK" -type f \
    \( -name '*.generated.c' -o -name '*.o' -o -name '*.native' \) -print)" ||
    fail 'record frontend emitted a backend/runtime artifact'

# ------------------------------------------------------- Stage 2 C11 slice
# Start with the nominal Int/Bool core: construction in either written label
# order, whole-record pass/return, and reads of both field types. The Text and
# List[Int] increments below extend this same bounded backend slice.

kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"
"$WORK/kofun-stage2" \
    "$CASES/record_functions.kofun" \
    "$WORK/record_functions.c" \
    "$WORK/record_functions.stage2.ir" \
    "$WORK/record_functions.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$WORK/record_functions.c" \
    -o "$WORK/record_functions"
"$WORK/record_functions" \
    >"$WORK/record_functions.stdout" \
    2>"$WORK/record_functions.stderr"
cmp "$CASES/record_functions.stdout" "$WORK/record_functions.stdout" ||
    fail 'Stage 2 nominal record output differs'
test ! -s "$WORK/record_functions.stderr" ||
    fail 'Stage 2 nominal record program wrote unexpected stderr'
grep -F \
    '_Static_assert(offsetof(KofunRecord_Packet, f_count) == 0,' \
    "$WORK/record_functions.c" >/dev/null ||
    fail 'Stage 2 record count offset disagrees with AggregateLayout'
grep -F \
    '_Static_assert(offsetof(KofunRecord_Packet, f_enabled) == 8,' \
    "$WORK/record_functions.c" >/dev/null ||
    fail 'Stage 2 record Bool offset disagrees with AggregateLayout'
grep -F \
    '_Static_assert(sizeof(KofunRecord_Packet) == 16,' \
    "$WORK/record_functions.c" >/dev/null ||
    fail 'Stage 2 record size disagrees with AggregateLayout'
enabled_line=$(grep -n 'k_b4.f_enabled = true;' \
    "$WORK/record_functions.c" | cut -d: -f1)
count_line=$(grep -n 'k_b4.f_count = INT64_C(41);' \
    "$WORK/record_functions.c" | cut -d: -f1)
test "$enabled_line" -lt "$count_line" ||
    fail 'Stage 2 reordered labelled record field evaluation'
grep '^static int64_t kofun_fn_score(KofunRecord_Packet ' \
    "$WORK/record_functions.c" >/dev/null ||
    fail 'Stage 2 did not lower the nominal record parameter'
grep '^static KofunRecord_Packet kofun_fn_make_packet' \
    "$WORK/record_functions.c" >/dev/null ||
    fail 'Stage 2 did not lower the nominal record result'

# #1555. `record_c_type_name` is unbounded, so the two result spellings must be
# too. The old 512-byte arrays accepted this source and silently dropped the
# close of the zero value (and part of the function result), leaving generated
# C that failed only when cc saw it.
long_record=R
long_index=0
while [ "$long_index" -lt 600 ]; do
    long_record="${long_record}a"
    long_index=$((long_index + 1))
done
printf 'type %s = {\n    value: Int,\n}\n\nfn relay(report: %s) -> %s {\n    return report\n}\n\nfn main() -> Int {\n    let constructed: %s = %s(value: 3)\n    let returned: %s = relay(constructed)\n    print(returned.value)\n    return 0\n}\n' \
    "$long_record" "$long_record" "$long_record" "$long_record" \
    "$long_record" "$long_record" >"$WORK/long_record_name.kofun"
"$WORK/kofun-stage2" \
    "$WORK/long_record_name.kofun" \
    "$WORK/long_record_name.c" \
    "$WORK/long_record_name.ir" \
    "$WORK/long_record_name.tokens" >/dev/null ||
    fail 'Stage 2 refused the long record type name'
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$WORK/long_record_name.c" -o "$WORK/long_record_name" ||
    fail 'the long record type name produced malformed C'
"$WORK/long_record_name" >"$WORK/long_record_name.stdout" \
    2>"$WORK/long_record_name.stderr" ||
    fail 'the long record type program did not run'
test "$(cat "$WORK/long_record_name.stdout")" = 3 ||
    fail 'the long record type program printed unexpected output'
test ! -s "$WORK/long_record_name.stderr" ||
    fail 'the long record type program wrote unexpected stderr'
grep -F "static KofunRecord_${long_record} kofun_fn_relay" \
    "$WORK/long_record_name.c" >/dev/null ||
    fail 'the long record result spelling disagrees with its typedef'

expect_stage2_failure() {
    stem=$1
    set +e
    "$WORK/kofun-stage2" \
        "$CASES/$stem.kofun" \
        "$WORK/$stem.c" \
        "$WORK/$stem.stage2.ir" \
        "$WORK/$stem.tokens" \
        >"$WORK/$stem.stage2.actual" \
        2>"$WORK/$stem.stage2.internal.stderr"
    stage2_status=$?
    set -e
    test "$stage2_status" -eq 1 ||
        fail "$stem exited $stage2_status instead of 1"
    cmp "$CASES/$stem.diagnostic" "$WORK/$stem.stage2.actual" ||
        fail "$stem Stage 2 diagnostic differs"
    test ! -s "$WORK/$stem.stage2.internal.stderr" ||
        fail "$stem wrote internal Stage 2 stderr"
    test ! -e "$WORK/$stem.c" ||
        fail "$stem emitted rejected C"
}

expect_stage2_failure stage2_unsupported_field

# #1181: `Text` joined the field slice, so the boundary fixture above moved to
# `List[Int]` rather than being deleted, and the admitted shape owes execution
# evidence here — construction, both field reads, a Text field passed to a
# function taking Text, and a record mixing all three carriers.
"$ROOT/bin/kofun" run "$CASES/text_field.kofun" \
    >"$WORK/text_field.stdout" 2>"$WORK/text_field.stderr" ||
    fail 'text_field did not run'
test ! -s "$WORK/text_field.stderr" ||
    fail 'text_field wrote stderr'
cmp "$CASES/text_field.stdout" "$WORK/text_field.stdout" ||
    fail 'text_field output differs from the golden'

# #1183 / RFC-0011: a bounded `List[Int]` record field, stored inline by value.
#
# `Reading` is the load-bearing case, not `Bag`. It puts a 1-byte `Bool` before
# the 520-byte list, so the list lands at offset 8 — which is only true because
# a field's alignment comes from its type rather than its size. Reintroduce
# that coupling and the emitted C stops compiling: the offsets become 520 and
# 1560, and `_Static_assert` rejects them. The layout claim is therefore made
# by building this fixture, not by anything it prints.
"$ROOT/bin/kofun" run "$CASES/list_field.kofun" \
    >"$WORK/list_field.stdout" 2>"$WORK/list_field.stderr" ||
    fail 'list_field did not run'
test ! -s "$WORK/list_field.stderr" ||
    fail 'list_field wrote stderr'
cmp "$CASES/list_field.stdout" "$WORK/list_field.stdout" ||
    fail 'list_field output differs from the golden'

# #1197: the same field read back out as a `List[Int]` value — passed to a
# function, measured by `len`, and indexed.
#
# The golden's last two lines are the ones that matter. The fixture mutates
# what it read and then prints the record's own element, so a read that ever
# became a view into the record rather than a copy of its carrier prints 99
# where the golden says 10. The two cannot both pass.
"$ROOT/bin/kofun" run "$CASES/list_field_read.kofun" \
    >"$WORK/list_field_read.stdout" 2>"$WORK/list_field_read.stderr" ||
    fail 'list_field_read did not run'
test ! -s "$WORK/list_field_read.stderr" ||
    fail 'list_field_read wrote stderr'
cmp "$CASES/list_field_read.stdout" "$WORK/list_field_read.stdout" ||
    fail 'list_field_read output differs from the golden'
expect_stage2_failure stage2_direct_construction
expect_stage2_failure stage2_labelled_call

# #946: the whole-binding move rule reaching the compiler a user runs. The
# fixtures beside these — `use_after_move.kofun`, `double_take.kofun`, and
# `partial_move.kofun` — pin the standalone frontend's wording, so the two
# producers stay one language. The split is about which frontend is under test,
# not about which field types the slice admits: those three carry a `Text`
# field and reach their ownership diagnostics today. This comment used to say
# the slice refused them first, which stopped being true when #1181 admitted
# `Text` and is doubly untrue now that #1183 admits `List[Int]`.
#
expect_stage2_failure production_use_after_move
expect_stage2_failure production_double_take
expect_stage2_failure production_partial_move

# #881 retired the old E2S35 boundary: an ownership-mode parameter now binds
# its internal name in the production HIR and lowering path. Compile and run a
# record read so a parser-only change cannot satisfy that claim.
"$WORK/kofun-stage2" \
    "$CASES/production_read_parameter.kofun" \
    "$WORK/production_read_parameter.c" \
    "$WORK/production_read_parameter.stage2.ir" \
    "$WORK/production_read_parameter.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$WORK/production_read_parameter.c" \
    -o "$WORK/production_read_parameter"
"$WORK/production_read_parameter" \
    >"$WORK/production_read_parameter.stdout" \
    2>"$WORK/production_read_parameter.stderr"
cmp "$CASES/production_read_parameter.stdout" \
    "$WORK/production_read_parameter.stdout" ||
    fail 'read parameter output differs'
test ! -s "$WORK/production_read_parameter.stderr" ||
    fail 'read parameter wrote unexpected stderr'

# The accepted half of the move rule. A rule that refuses every `take` is
# indistinguishable from having no rule at all, so one legal whole-binding move
# is compiled, built under the same -Wall -Wextra -Werror as every other
# accepted record program, and run.
"$WORK/kofun-stage2" \
    "$CASES/production_take_accepted.kofun" \
    "$WORK/production_take_accepted.c" \
    "$WORK/production_take_accepted.stage2.ir" \
    "$WORK/production_take_accepted.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$WORK/production_take_accepted.c" \
    -o "$WORK/production_take_accepted"
"$WORK/production_take_accepted" \
    >"$WORK/production_take_accepted.stdout" \
    2>"$WORK/production_take_accepted.stderr"
cmp "$CASES/production_take_accepted.stdout" \
    "$WORK/production_take_accepted.stdout" ||
    fail 'accepted whole-binding move output differs'
test ! -s "$WORK/production_take_accepted.stderr" ||
    fail 'accepted whole-binding move wrote unexpected stderr'

# A record argument that is not a whole record binding.  Each of these three
# once exited 0 and wrote the diagnostic text into the emitted C as if it were
# an expression, so `kofun check` reported `ok:` and only `cc` failed.  The
# field read was worse than a broken artifact: it lowered to the record the
# field was read from, so it compiled and ran, and the program computed
# something the source never said.  `expect_stage2_failure` asserts the
# property that was lost — status 1, the exact diagnostic, and no emitted C.
expect_stage2_failure stage2_argument_field_read
expect_stage2_failure stage2_argument_wrong_record
expect_stage2_failure stage2_argument_not_a_record

# The same rejected call in five statement positions.  Propagation was per
# site, so each position had to be reached before it refused, and arithmetic
# hid the rejection a second way: wrapping it as `kofun_add(error[...], 1)`
# produced a string that no longer began with `error[`, so every check above
# the operator saw a well-formed expression.
expect_stage2_failure stage2_argument_in_let
expect_stage2_failure stage2_argument_in_return
expect_stage2_failure stage2_argument_in_arithmetic
expect_stage2_failure stage2_argument_in_condition

# spec/records-v1.md tells an implementer which code each condition raises, so
# it is wrong in the way that matters if it disagrees with the registry the
# compiler is actually gated against. The table drifted by one once already,
# silently, because nothing compared the two.
#
# E2S106 and E2S107 are excluded by name: they are limits of the bounded
# frontend surface (input length, unparseable token), not conditions of the
# record semantics the document specifies.
SPEC_TABLE="$ROOT/spec/records-v1.md"
REGISTRY="$ROOT/tests/diagnostics/registry.tsv"
grep -oE '\| `E2S[0-9]+` \|' "$SPEC_TABLE" | tr -d '|` ' >"$WORK/spec-codes"
awk -F'\t' '$2 == "record" { print $1 }' "$REGISTRY" \
    | grep -vxE 'E2S10[67]' >"$WORK/registry-codes"
if ! cmp -s "$WORK/spec-codes" "$WORK/registry-codes"; then
    row=$(cmp "$WORK/spec-codes" "$WORK/registry-codes" 2>/dev/null \
        | sed -n 's/.*line \([0-9]*\).*/\1/p')
    row=${row:-1}
    fail "spec/records-v1.md disagrees with tests/diagnostics/registry.tsv at table row $row: \
the document says $(sed -n "${row}p" "$WORK/spec-codes" || echo 'nothing'), \
the registry gates $(sed -n "${row}p" "$WORK/registry-codes" || echo 'nothing')
      the table must list every record-family code except E2S106 and E2S107, in
      registry order; update the table, or register the code the compiler emits"
fi

printf '%s\n' \
    'PASS: Token-shaped records construct, pass, return, and read' \
    'PASS: written field order is free and storage follows declaration order' \
    'PASS: nominal record and field identities ignore declaration order' \
    'PASS: layout is untagged and identical on x86-64 and AArch64' \
    'PASS: blocks, conditions, loops, and lists stay separable from records' \
    'PASS: duplicate, missing, unknown, wrong-type, mutation, and move diagnostics are exact' \
    'PASS: Stage 2 executes nominal Int/Bool/Text/List[Int] records in AggregateLayout order' \
    'PASS: record result and failure spellings grow with an unbounded source type name' \
    'PASS: a bounded List[Int] field lands at its aligned offset, not its size' \
    'PASS: a rejected record argument fails the compile instead of reaching the C' \
    'PASS: the rejection survives let, return, arithmetic, and condition positions' \
    'PASS: the compiler a user runs accepts, lowers, and runs a whole-binding move' \
    'PASS: partial move, second move, and use after move refuse with the standalone wording' \
    'PASS: a read parameter binds its internal name, lowers, and runs' \
    'PASS: the specification names the same diagnostic codes the registry gates'

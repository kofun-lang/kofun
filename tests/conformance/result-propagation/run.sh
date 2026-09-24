#!/usr/bin/env sh
set -eu

# Result propagation, refusal slice (#1662, spec/result-propagation-v1.md).
# The contract this gate holds the Stage 2 pair to:
#
#   - postfix `?` parses at the level of a call or field read, in every
#     expression position, beside optional types `T?` that are never read as
#     propagation, and each `?` is a typed scope-HIR `propagate` node;
#   - Stage 2 has no `Result` type yet, so every `?` it sees is refused with a
#     registered code, exit 1, no C, the primary span on the `?` token and the
#     secondary span on its operand:
#       E2S189  the operand is not a `Result[T, E]` (names the operand type)
#       E2S190  the operand is an optional (suggests `ok_or(error)?`)
#       E2S191  the `?` sits directly on a pipeline stage (suggests
#               `(a |> f())?`), checked before `E2S158`;
#   - the check order is syntactic (E2S191, while parsing), then operand
#     (E2S190 before E2S189), and each fixture pins whether the IR and token
#     checkpoints exist;
#   - no `?` reaches the `E2S10` unsupported-statement path or exit 3, and
#     `bin/kofun` answers with the same line instead of falling back to
#     Stage 1;
#   - both halves of the pair answer identically.
#
# Mutations at the end prove the gate is not green by accident: each restores
# one piece of the old path in a rebuilt compiler and requires a named
# fixture to stop answering the way its golden says.
#
# Positive lowering is #1250's, and so are the non-Result enclosing function
# refusal and the hand-desugared twin corpus. The error-type mismatch refusal
# is unreachable until two `Result` error types exist.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/result-propagation"
SOURCE="$ROOT/bootstrap/stage2/compiler.c"
CC=${CC:-cc}
WORK=${KOFUN_RESULT_PROPAGATION_WORK:-"$ROOT/build/result-propagation"}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the pair check'
case $WORK in
    */result-propagation|*/result-propagation.*) ;;
    *) fail "work directory must end in result-propagation[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/positions" "$WORK/cli/tmp"

COMPILER="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$COMPILER"

# The byte at offset $2 of file $1, as one character.
byte_at() {
    dd if="$1" bs=1 skip="$2" count=1 2>/dev/null
}

# One refusal, held to the whole contract. $4 is `present` or `absent`: the IR
# and token checkpoints an operand refusal leaves behind (written before
# lowering) and a syntactic one does not (refused while parsing).
check_refusal() {
    source=$1
    code=$2
    checkpoints=$3
    golden=$4
    stem=$(basename "${source%.kofun}")
    set +e
    "$COMPILER" --compile-outcome "$source" \
        "$WORK/$stem.c" "$WORK/$stem.ir" "$WORK/$stem.tokens" \
        >"$WORK/$stem.actual" 2>"$WORK/$stem.internal"
    status=$?
    set -e
    test "$status" -ne 3 ||
        fail "$stem took the unsupported-lowering exit 3 (Stage 1 fallback)"
    test "$status" -eq 1 || fail "$stem exited $status instead of 1"
    test ! -s "$WORK/$stem.internal" || fail "$stem wrote internal stderr"
    test ! -e "$WORK/$stem.c" || fail "$stem emitted C"
    ! grep -F 'error[E2S10]' "$WORK/$stem.actual" >/dev/null ||
        fail "$stem reached the E2S10 unsupported-statement path"
    test "$(wc -l <"$WORK/$stem.actual" | tr -d ' ')" -eq 1 ||
        fail "$stem printed more than one diagnostic line"
    if test -n "$golden"; then
        cmp "$golden" "$WORK/$stem.actual" ||
            fail "$stem diagnostic differs from its golden"
    fi
    grep -F "error[$code]: " "$WORK/$stem.actual" >/dev/null ||
        fail "$stem did not emit $code"
    case $code in
        E2S189)
            grep -E '^error\[E2S189\]: `\?` propagates only a `Result\[T, E\]`, and this operand is `[^`]+` at byte [0-9]+; operand at byte [0-9]+$' \
                "$WORK/$stem.actual" >/dev/null ||
                fail "$stem E2S189 does not name the operand type"
            ;;
        E2S190)
            grep -F 'optionals do not propagate' "$WORK/$stem.actual" \
                >/dev/null && grep -F '`ok_or(error)?`' "$WORK/$stem.actual" \
                >/dev/null || fail "$stem E2S190 lost its ok_or suggestion"
            ;;
        E2S191)
            grep -F '`(a |> f())?`' "$WORK/$stem.actual" >/dev/null ||
                fail "$stem E2S191 lost its parenthesize suggestion"
            ;;
    esac
    # The primary span is the `?` token and the secondary span its operand,
    # which starts before it.
    primary=$(sed -n 's/.* at byte \([0-9][0-9]*\); operand at byte [0-9][0-9]*$/\1/p' \
        "$WORK/$stem.actual")
    secondary=$(sed -n 's/.*; operand at byte \([0-9][0-9]*\)$/\1/p' \
        "$WORK/$stem.actual")
    test -n "$primary" && test -n "$secondary" ||
        fail "$stem lacks a primary and a secondary span"
    test "$(byte_at "$source" "$primary")" = '?' ||
        fail "$stem primary span $primary is not a \`?\` token"
    test "$secondary" -lt "$primary" ||
        fail "$stem operand span $secondary does not precede the \`?\`"
    case $checkpoints in
        present)
            test -s "$WORK/$stem.ir" && test -s "$WORK/$stem.tokens" ||
                fail "$stem did not keep its IR and token checkpoints"
            ! grep -F 'kofun-scope-hir/v1' "$WORK/$stem.ir" >/dev/null ||
                fail "$stem wrote scope HIR into a refused IR checkpoint"
            ;;
        absent)
            test ! -e "$WORK/$stem.ir" && test ! -e "$WORK/$stem.tokens" ||
                fail "$stem wrote a checkpoint for a parse-time refusal"
            ;;
        *) fail "unknown checkpoint policy '$checkpoints' for $stem" ;;
    esac
}

# stem:code:checkpoints. The first seven are the measured rows of #1662 in its
# order; the rest pin optional operands, the suggested fix shape, the check
# order, operands that end in a `}` (a value `if` and a value `match`), and the
# grammar corpus.
refusals='
let_call:E2S189:present
statement_call:E2S189:present
pipeline_call_stage:E2S191:absent
pipeline_bare_stage:E2S191:absent
optional_binding:E2S190:present
decimal_round:E2S189:present
decimal_division:E2S189:present
optional_call:E2S190:present
optional_null:E2S190:present
parenthesized_pipeline:E2S189:present
order_stage_before_optional:E2S191:absent
order_syntactic_first:E2S191:absent
order_first_question:E2S189:present
value_if_operand:E2S189:present
match_operand:E2S189:present
grammar:E2S189:present
'

previous_ifs=$IFS
IFS='
'
for entry in $refusals; do
    test -n "$entry" || continue
    stem=${entry%%:*}
    rest=${entry#*:}
    code=${rest%%:*}
    checkpoints=${rest#*:}
    check_refusal "$CASES/$stem.kofun" "$code" "$checkpoints" \
        "$CASES/$stem.stderr"
done
IFS=$previous_ifs

# An operand whose callee resolves to nothing has no type to name, so it is
# not refused as E2S189 with an invented one. It keeps its own E2S16 at the
# callee, and the gate holds that to be byte for byte the line the same source
# gives without the `?`. Exit 1 all the same: never E2S10, never Stage 1.
set +e
"$COMPILER" --compile-outcome "$CASES/unknown_callee.kofun" \
    "$WORK/unknown_callee.c" "$WORK/unknown_callee.ir" \
    "$WORK/unknown_callee.tokens" >"$WORK/unknown_callee.actual" \
    2>"$WORK/unknown_callee.internal"
unknown_status=$?
sed 's/nope()?/nope()/' "$CASES/unknown_callee.kofun" \
    >"$WORK/unknown_callee_plain.kofun"
"$COMPILER" --compile-outcome "$WORK/unknown_callee_plain.kofun" \
    "$WORK/unknown_callee_plain.c" "$WORK/unknown_callee_plain.ir" \
    "$WORK/unknown_callee_plain.tokens" >"$WORK/unknown_callee_plain.actual" \
    2>"$WORK/unknown_callee_plain.internal"
plain_status=$?
set -e
test "$unknown_status" -eq 1 ||
    fail "unknown_callee exited $unknown_status instead of 1"
test "$plain_status" -eq 1 ||
    fail "unknown_callee without its ? exited $plain_status instead of 1"
test ! -s "$WORK/unknown_callee.internal" ||
    fail 'unknown_callee wrote internal stderr'
test ! -e "$WORK/unknown_callee.c" || fail 'unknown_callee emitted C'
cmp "$CASES/unknown_callee.stderr" "$WORK/unknown_callee.actual" ||
    fail 'unknown_callee diagnostic differs from its golden'
grep -F 'error[E2S16]: unknown Core function `nope` at byte ' \
    "$WORK/unknown_callee.actual" >/dev/null ||
    fail 'unknown_callee did not keep its own E2S16'
cmp "$WORK/unknown_callee_plain.actual" "$WORK/unknown_callee.actual" ||
    fail 'the ? changed the unknown callee diagnostic'

# The corpus is globbed as well as listed, so a fixture added without a gate
# entry stops the build. `unknown_callee` is the one fixture checked above
# rather than in the refusal table.
declared=$(( $(printf '%s' "$refusals" | grep -c ':') + 1 ))
present=$(find "$CASES" -name '*.stderr' -type f | wc -l | tr -d ' ')
test "$declared" -eq "$present" ||
    fail "gate lists $declared refusals but $present fixtures exist"

# The typed nodes. Every `?` in expression position is one `propagate` record
# and no optional type's `?` is: `grammar.propagate` is the exact list, in
# source order, with each operand span and type.
"$COMPILER" --emit-scope-hir "$CASES/grammar.kofun" "$WORK/grammar.scope-hir" \
    >"$WORK/grammar.scope-stdout"
test ! -s "$WORK/grammar.scope-stdout" || fail 'grammar scope HIR was refused'
grep '^propagate|' "$WORK/grammar.scope-hir" >"$WORK/grammar.propagate"
cmp "$CASES/grammar.propagate" "$WORK/grammar.propagate" ||
    fail 'grammar propagate nodes differ from grammar.propagate'
while IFS='|' read -r kind question operand operand_end scope operand_type; do
    test "$kind" = propagate || fail "unexpected record kind $kind"
    test "$(byte_at "$CASES/grammar.kofun" "$question")" = '?' ||
        fail "propagate node $question is not a \`?\` token"
    test "$operand" -lt "$operand_end" && test "$operand_end" -le "$question" ||
        fail "propagate node $question has an operand that is not before it"
    test -n "$scope" && test -n "$operand_type" ||
        fail "propagate node $question is untyped or unscoped"
done <"$WORK/grammar.propagate"
# `origin()?.x`: the operand is `origin()` alone, so `?` bound tighter than
# the field read that follows it.
grep -Fx 'propagate|1062|1054|1062|7|Point' "$WORK/grammar.propagate" \
    >/dev/null || fail 'f(x)?.name did not parse as (f(x)?).name'
optional_types=$(grep -c ': Int?' "$CASES/grammar.kofun")
test "$optional_types" -eq 2 ||
    fail "grammar.kofun should hold two Int? annotations, saw $optional_types"

# Every expression position, one `?` each. None may reach E2S10 or exit 3.
positions='
let-initializer|    let value = one()?
statement|    one()?
return|    return one()?
call-argument|    print(one()?)
labelled-argument|    print(add(left: one()?, right: 2))
if-condition|    if one()? == 1 {\n        total = 1\n    }
left-operand|    let value = one()? + 1
right-operand|    let value = 1 + one()?
group|    let value = (one())?
inner-group|    let value = 1 + (one()?)
assignment|    total = one()?
lambda-body|    let apply = fn(value: Int) => one()? + value
field-continuation|    let value = one()?.x
value-if|    let value = if total == 0 { 1 } else { 2 }?
else-if-statement|    if total == 0 {\n        total = 1\n    } else if total == 1 {\n        total = 2\n    } else {\n        total = 3\n    }?
bool-match|    let value = match total == 0 {\n        true => { 1 },\n        false => { 2 },\n    }?
'
position_sources=
IFS='
'
for entry in $positions; do
    test -n "$entry" || continue
    name=${entry%%|*}
    statement=${entry#*|}
    source="$WORK/positions/$name.kofun"
    {
        printf '%s\n' 'fn one() -> Int {' '    return 1' '}' ''
        printf '%s\n' 'fn add(left a: Int, right b: Int) -> Int {' \
            '    return a + b' '}' ''
        printf '%s\n' 'fn main() -> Int {' '    let mut total = 0'
        printf '%b\n' "$statement"
        printf '%s\n' '    return total' '}'
    } >"$source"
    test "$(grep -o '?' "$source" | wc -l | tr -d ' ')" -eq 1 ||
        fail "position $name must hold exactly one ?"
    check_refusal "$source" E2S189 present ''
    question=$(grep -bo '?' "$source" | cut -d: -f1)
    grep -F "at byte $question; operand at byte" "$WORK/$name.actual" \
        >/dev/null || fail "position $name did not report its own ?"
    position_sources="$position_sources
$source"
done
IFS=$previous_ifs

# The public CLI: `check` and `build --emit-c` answer with the same line on
# stderr, exit 1, write nothing, and never run the Stage 1 compiler.
cli() {
    TMPDIR="$WORK/cli/tmp" \
    KOFUN_BUILD_DIR="$WORK/cli/stage1" \
    KOFUN_STAGE2_BUILD_DIR="$WORK/cli/stage2" \
        "$ROOT/bin/kofun" "$@"
}
for stem in let_call statement_call pipeline_call_stage pipeline_bare_stage \
    optional_binding decimal_round decimal_division; do
    set +e
    cli check "$CASES/$stem.kofun" >"$WORK/cli/$stem.check.stdout" \
        2>"$WORK/cli/$stem.check.stderr"
    check_status=$?
    cli build "$CASES/$stem.kofun" -o "$WORK/cli/$stem" \
        --emit-c "$WORK/cli/$stem.c" >"$WORK/cli/$stem.build.stdout" \
        2>"$WORK/cli/$stem.build.stderr"
    build_status=$?
    set -e
    test "$check_status" -eq 1 || fail "kofun check $stem exited $check_status"
    test "$build_status" -eq 1 || fail "kofun build $stem exited $build_status"
    test ! -s "$WORK/cli/$stem.check.stdout" &&
        test ! -s "$WORK/cli/$stem.build.stdout" ||
        fail "kofun check/build $stem wrote stdout"
    cmp "$CASES/$stem.stderr" "$WORK/cli/$stem.check.stderr" ||
        fail "kofun check $stem did not print the Stage 2 refusal"
    cmp "$CASES/$stem.stderr" "$WORK/cli/$stem.build.stderr" ||
        fail "kofun build --emit-c $stem did not print the Stage 2 refusal"
    test ! -e "$WORK/cli/$stem.c" && test ! -e "$WORK/cli/$stem" ||
        fail "kofun build $stem committed an artifact"
done
test -z "$(find "$WORK/cli/stage1" -type f 2>/dev/null)" ||
    fail 'a refusal fell back to the Stage 1 compiler'

# Both halves of the pair, on every fixture and every generated position.
# shellcheck disable=SC2086
node "$CASES/pair.mjs" "$COMPILER" "$WORK/pair" "$CASES"/*.kofun \
    $position_sources

# ------------------------------------------------------------------ mutations
#
# Each mutation rebuilds the compiler with one piece of the old path restored
# and requires a named fixture to stop answering the way its golden says.

mutate() {
    mutate_label=$1
    mutate_expression=$2
    sed "$mutate_expression" "$SOURCE" >"$WORK/mutant-$mutate_label.mutated"
    if cmp -s "$SOURCE" "$WORK/mutant-$mutate_label.mutated"; then
        fail "mutation $mutate_label changed nothing"
    fi
    sed 's|"\.\./\.\./unicode/|"'"$ROOT"'/unicode/|' \
        "$WORK/mutant-$mutate_label.mutated" >"$WORK/mutant-$mutate_label.c"
    "$CC" -std=c11 -O0 -w -I"$ROOT/bootstrap/stage2" \
        "$WORK/mutant-$mutate_label.c" -o "$WORK/mutant-$mutate_label"
}

# Prints the mutant's answer for one fixture as `STATUS DIAGNOSTIC`.
mutant_answer() {
    answer_label=$1
    answer_stem=$2
    set +e
    "$WORK/mutant-$answer_label" --compile-outcome "$CASES/$answer_stem.kofun" \
        "$WORK/mutant-$answer_label-$answer_stem.c" \
        "$WORK/mutant-$answer_label-$answer_stem.ir" \
        "$WORK/mutant-$answer_label-$answer_stem.tokens" \
        >"$WORK/mutant-$answer_label-$answer_stem.actual" 2>&1
    answer_status=$?
    set -e
    ! cmp -s "$CASES/$answer_stem.stderr" \
        "$WORK/mutant-$answer_label-$answer_stem.actual" ||
        fail "mutation $answer_label left $answer_stem answering identically"
    printf '%s %s\n' "$answer_status" \
        "$(cat "$WORK/mutant-$answer_label-$answer_stem.actual")"
}

unread_nodes='s/int64_t line = hir_record_start(hir, "propagate", 0);/int64_t line = -1;/'
reader_stops='s/int64_t question = skip_trivia(source, chain);/int64_t question = source_length(source);/'

# The old path itself: the reader stops at `?` and the typed nodes are never
# read. This is the compiler before #1662, and the refusal table above cannot
# pass on it: the measured rows answer `E2S10` with exit 3 again, and the
# optional row `E2S147`.
mutate old-path "$unread_nodes;$reader_stops"
answer=$(mutant_answer old-path let_call)
case $answer in
    '3 error[E2S10]: unsupported Core statement at byte '*) ;;
    *) fail "old-path mutant did not restore E2S10 for let_call: $answer" ;;
esac
answer=$(mutant_answer old-path optional_binding)
case $answer in
    '1 error[E2S147]: '*) ;;
    *) fail "old-path mutant did not restore E2S147 for optional_binding: $answer" ;;
esac

# The nodes alone unread, with the reader still stepping over `?`: nothing
# else refuses it, and `one()?` compiles with the `?` dropped. This is why the
# refusal runs ahead of every lowering validator, and what it prevents.
mutate unread-nodes "$unread_nodes"
answer=$(mutant_answer unread-nodes let_call)
case $answer in
    '0 '*) ;;
    *) fail "unread-nodes mutant did not show the refusal is load-bearing: $answer" ;;
esac

# The pipeline-stage refusal is skipped: the bare stage falls back to E2S158.
mutate no-stage-check \
    's/int64_t stage_question = pipeline_stage_question(source, cursor);/int64_t stage_question = -1;/'
answer=$(mutant_answer no-stage-check pipeline_bare_stage)
case $answer in
    '1 error[E2S158]: a pipeline target must be a direct call written with its parentheses at byte '*) ;;
    *) fail "no-stage-check mutant did not restore E2S158: $answer" ;;
esac

# The shared expression reader alone stops at `?` again: the lambda body in
# the grammar corpus is measured short and its parameter leaves its scope.
mutate reader-stops "$reader_stops"
answer=$(mutant_answer reader-stops grammar)
case $answer in
    '1 error[E2S35]: binding `value` is outside its lexical scope at byte '*) ;;
    *) fail "reader-stops mutant did not mis-span the lambda body: $answer" ;;
esac

# A value `if` or `match` is never an operand primary: the `?` after its `}`
# falls through every refusal to the E2S10 statement path, exit 3, and Stage 1.
mutate no-block-operand \
    's/block_end = construct_end;/block_end = -1;/'
answer=$(mutant_answer no-block-operand value_if_operand)
case $answer in
    '3 error[E2S10]: unsupported Core statement at byte '*) ;;
    *) fail "no-block-operand mutant did not restore E2S10 for value_if_operand: $answer" ;;
esac

# Every callee counts as resolved: the unknown one is typed by the historical
# `Int` default and its own E2S16 is hidden behind an invented type.
mutate every-callee-resolves 's/    return !resolved;/    return false;/'
answer=$(mutant_answer every-callee-resolves unknown_callee)
case $answer in
    '1 error[E2S189]: '*'this operand is `Int` at byte '*) ;;
    *) fail "every-callee-resolves mutant did not invent Int for unknown_callee: $answer" ;;
esac

printf '%s\n' \
    'PASS: postfix ? parses at call/field level beside T? annotations, as typed propagate nodes' \
    'PASS: E2S189/E2S190/E2S191 fire on the ? token with an operand span, exit 1, no C' \
    'PASS: check order is syntactic (E2S191), then operand (E2S190 before E2S189)' \
    'PASS: no ? reaches E2S10 or exit 3, and bin/kofun check/build answer without Stage 1' \
    'PASS: both halves of the pair agree, and six mutations toward the old path are caught'

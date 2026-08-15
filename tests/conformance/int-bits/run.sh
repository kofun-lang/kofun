#!/bin/sh
set -eu

# RFC-0013's eight bit operations on `Int`, spelled as postfix methods (#1348).
#
# The gate is written so that a wrong implementation fails by producing a
# different number, not by crashing. C leaves a shift by the operand width
# undefined and leaves a signed right shift implementation-defined; the whole
# reason these operations were named was to give them answers the language
# states, so the observations below are the statement.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/int-bits"
CC=${CC:-cc}
ASSERT_CONTEXT='int bits'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/build.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-int-bits.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

command -v "$CC" >/dev/null 2>&1 ||
    assert_fail 'a C11 compiler is required'

kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"
node --check "$CASES/check-pair.mjs"
node "$CASES/check-pair.mjs" \
    "$ROOT/bootstrap/stage2/compiler.c" \
    "$ROOT/bootstrap/stage2/compiler.kofun" check
node "$CASES/check-pair.mjs" \
    "$ROOT/bootstrap/stage2/compiler.c" \
    "$ROOT/bootstrap/stage2/compiler.kofun" self-test
mkdir -p "$WORK/remapped"
cp "$CASES/behavior.kofun" "$WORK/remapped/behavior.kofun"

compile_case() {
    source=$1
    label=$2
    "$WORK/kofun-stage2" --compile-outcome "$source" \
        "$WORK/$label.c" "$WORK/$label.ir" "$WORK/$label.tokens" \
        >"$WORK/$label.compile.stdout" 2>"$WORK/$label.compile.stderr" ||
        assert_fail "$label did not lower"
    assert_file_empty "$label wrote internal stderr" \
        "$WORK/$label.compile.stderr"
}

run_case() {
    label=$1
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        "$WORK/$label.c" -o "$WORK/$label" ||
        assert_fail "$label emitted invalid C11"
    "$WORK/$label" >"$WORK/$label.stdout" 2>"$WORK/$label.stderr" ||
        assert_fail "$label exited nonzero"
    cmp "$CASES/$label.stdout" "$WORK/$label.stdout" ||
        assert_fail "$label observation changed"
    assert_file_empty "$label wrote runtime stderr" "$WORK/$label.stderr"
}

# The same source and the same bytes at another path must emit byte-identical C.
compile_case "$CASES/behavior.kofun" behavior
compile_case "$CASES/behavior.kofun" behavior.second
compile_case "$WORK/remapped/behavior.kofun" behavior.remapped
cmp "$WORK/behavior.c" "$WORK/behavior.second.c" ||
    assert_fail 'two identical compilations emitted different C'
cmp "$WORK/behavior.c" "$WORK/behavior.remapped.c" ||
    assert_fail 'emitted C depends on the source path'

run_case behavior
compile_case "$CASES/names_free.kofun" names_free
run_case names_free

# The observations that carry the semantics the RFC fixes, named one at a time
# so a regression says which rule moved rather than "output changed". Line
# numbers are the fixture's print order.
behavior_line() {
    sed -n "$1p" "$WORK/behavior.stdout"
}
assert_eq 'complement is two-s complement' "$(behavior_line 5)" '-1'
assert_eq 'a negative operand masks rather than refusing' \
    "$(behavior_line 6)" '255'
assert_eq 'shr replicates the sign bit' "$(behavior_line 10)" '-4'
assert_eq 'an arithmetic shr of -1 stays -1' "$(behavior_line 11)" '-1'
assert_eq 'rotr moves the low bit to the width-th place' \
    "$(behavior_line 15)" '2147483648'
assert_eq 'rotr reduces its operand modulo the width' \
    "$(behavior_line 19)" '4294967295'
assert_eq 'a 64-bit rotation produces the signed pattern' \
    "$(behavior_line 20)" '-9223372036854775808'
assert_eq 'the width-64 all-ones pattern maps to signed Int -1' \
    "$(behavior_line 21)" '-1'
assert_eq 'wrapping_add wraps at the width rather than trapping' \
    "$(behavior_line 18)" '0'
assert_eq 'a rotation count is reduced within the width' \
    "$(behavior_line 23)" '2147483648'
# sigma0(1) = ROTR7(1) ^ ROTR18(1) ^ SHR3(1) = 0x02000000 ^ 0x4000 ^ 0
assert_eq 'the SHA-256 sigma0 round produces its published value' \
    "$(behavior_line 27)" '33570816'

# Every operation lowers to a checked helper emitted by this Stage 2 C11
# backend, never to a bare C operator. The RFC is the authority; these helpers
# implement that contract for this backend rather than defining it globally.
emitted="$WORK/behavior.c"
for helper in and or xor not shl shr rotr wrapping_add; do
    assert_grep "$helper lowers to its Stage2 C11 checked helper" \
        -Fq -- "kofun_bit_$helper(" "$emitted"
done
assert_grep 'the pattern conversion is defined rather than cast' \
    -Fq -- 'return -(int64_t)(~bits) - 1;' "$emitted"
# The `<<`/`>>` in the emitted file belong to the runtime helpers and to
# nothing else: lowered user code names bindings (`k_b`) and functions
# (`kofun_fn_`), so a bare shift on one of those lines would be an operation
# that skipped its count check.
grep -E '(k_b|kofun_fn_)' "$emitted" | grep -E '<<|>>' >"$WORK/bare_shifts" ||
    true
assert_file_empty 'a shift reached lowered code without its count check' \
    "$WORK/bare_shifts"

# Traps. Each fails at its own bound, with nothing on stdout: an operation that
# computed a wrong answer and then trapped would still have printed.
for stem in shl_overflow shl_count_high shr_count_negative \
            rotr_width_low rotr_count_high rotr_width_before_count \
            wrapping_add_width_high; do
    compile_case "$CASES/$stem.kofun" "$stem"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        "$WORK/$stem.c" -o "$WORK/$stem" ||
        assert_fail "$stem emitted invalid C11"
    set +e
    "$WORK/$stem" >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    status=$?
    set -e
    assert_num "$stem runtime status" "$status" -eq 1
    assert_file_empty "$stem wrote stdout" "$WORK/$stem.stdout"
    cmp "$CASES/$stem.stderr" "$WORK/$stem.stderr" ||
        assert_fail "$stem runtime diagnostic changed"
done
assert_grep 'overflow stays R010, the code checked arithmetic already uses' \
    -Fq -- 'error[R010]:' "$CASES/shl_overflow.stderr"
for stem in shl_count_high shr_count_negative rotr_width_low \
            rotr_count_high rotr_width_before_count \
            wrapping_add_width_high; do
    assert_grep "$stem is R011, not R010" \
        -Fq -- 'error[R011]:' "$CASES/$stem.stderr"
done
assert_grep 'rotr validates width before its simultaneously bad count' \
    -Fq -- 'bit width for `rotr`' \
    "$CASES/rotr_width_before_count.stderr"
assert_grep 'shl validates count before mathematical overflow' \
    -Fq -- 'shift count for `shl`' "$CASES/shl_count_high.stderr"

# Refusals. Each fails before a C artifact exists and keeps its parsed IR and
# token checkpoints, so "no backend artifact" is not read as "no output".
for stem in arity_short arity_long float_receiver float_receiver_used \
            text_argument labelled_argument trailing_lambda \
            unknown_member bool_receiver bool_argument \
            list_receiver list_argument record_receiver record_argument \
            enum_receiver enum_argument unknown_receiver unknown_argument \
            unknown_after_bit label_before_type type_before_label \
            type_before_trailing_lambda trailing_before_arity \
            optional_receiver optional_argument receiver_before_unknown \
            type_before_unknown label_before_unknown \
            nested_receiver_before_unknown nested_label_before_unknown \
            callable_named_argument callable_direct_argument \
            block_trailing_lambda; do
    set +e
    "$WORK/kofun-stage2" --compile-outcome "$CASES/$stem.kofun" \
        "$WORK/$stem.c" "$WORK/$stem.ir" "$WORK/$stem.tokens" \
        >"$WORK/$stem.actual" 2>"$WORK/$stem.internal.stderr"
    status=$?
    set -e
    assert_num "$stem compile status" "$status" -eq 1
    assert_file_empty "$stem wrote internal stderr" \
        "$WORK/$stem.internal.stderr"
    assert_absent "$stem emitted a C artifact" "$WORK/$stem.c"
    assert_file_nonempty "$stem lost its parsed IR checkpoint" \
        "$WORK/$stem.ir"
    assert_file_nonempty "$stem lost its token checkpoint" \
        "$WORK/$stem.tokens"
    cmp "$CASES/$stem.stderr" "$WORK/$stem.actual" ||
        assert_fail "$stem diagnostic changed"
done
# A parser-owned refusal fires before the IR/token checkpoints exist, and must
# still be atomic: no C and no partial checkpoint. `block_trailing_lambda` held
# this case until #1398 admitted the block body — it now reaches the ordinary
# loop above with `E2S169`, because `and` has no functional parameter, which is
# the diagnostic that shape always deserved. A block-bodied lambda *outside*
# the trailing position is still parser-owned, so it holds the case now.
stem=block_lambda_position
set +e
"$WORK/kofun-stage2" --compile-outcome "$CASES/$stem.kofun" \
    "$WORK/$stem.c" "$WORK/$stem.ir" "$WORK/$stem.tokens" \
    >"$WORK/$stem.actual" 2>"$WORK/$stem.internal.stderr"
status=$?
set -e
assert_num "$stem compile status" "$status" -eq 1
assert_file_empty "$stem wrote internal stderr" \
    "$WORK/$stem.internal.stderr"
assert_absent "$stem emitted a C artifact" "$WORK/$stem.c"
assert_absent "$stem emitted a partial IR checkpoint" "$WORK/$stem.ir"
assert_absent "$stem emitted a partial token checkpoint" "$WORK/$stem.tokens"
cmp "$CASES/$stem.stderr" "$WORK/$stem.actual" ||
    assert_fail "$stem diagnostic changed"
assert_grep 'a wrong argument count is an arity refusal' \
    -Fq -- 'error[E2S169]:' "$CASES/arity_short.stderr"
assert_grep 'a non-Int operand is a type refusal, not an arity one' \
    -Fq -- 'error[E2S168]:' "$CASES/float_receiver.stderr"
# The labelled-call grammar reaches these calls, and the operations have no
# parameter names. Unrefused, `a.and(value: 2)` lowered to
# `kofun_bit_and(k_b0, k_b)`: invalid C the compiler exited 0 on.
assert_grep 'a labelled argument is refused rather than lowered' \
    -Fq -- 'takes positional arguments' "$CASES/labelled_argument.stderr"
# A trailing lambda binds to the call it follows. Unconsumed, it made the
# argument counter read the enclosing `to_text` as malformed and blamed a call
# the author did not get wrong; the refusal is anchored at the lambda's `fn`.
assert_grep 'a trailing lambda is refused at its own `fn`' \
    -Fq -- 'takes no trailing lambda' "$CASES/trailing_lambda.stderr"
# A member call on an `Int` receiver is a member of `Int`. Answering `unknown
# nominal record field read` sent the reader to a record they never wrote, and
# inside another call the member was left unconsumed so the *enclosing* call was
# blamed instead.
assert_grep 'an unknown Int member is named as one' \
    -Fq -- 'unknown `Int` member `frobnicate`' "$CASES/unknown_member.stderr"
assert_not_grep 'an unknown Int member still blames a record' \
    -Fq -- 'unknown nominal record field read' "$CASES/unknown_member.stderr"
# The two receiver fixtures are the same mistake with and without a downstream
# reader, and both must name the receiver. `float_receiver` never uses its
# result — before the receiver query was bounded, that program compiled and
# emitted `kofun_bit_and` with a `double` argument. `float_receiver_used` does
# read it — before a whole-initializer chain bound `Int`, that program blamed
# `to_text` for a mistake in the receiver.
assert_not_grep 'the unused-result receiver fixture gained a use' \
    -Fq -- 'to_text(masked)' "$CASES/float_receiver.kofun"
assert_grep 'the read-result receiver fixture still reads its result' \
    -Fq -- 'to_text(masked)' "$CASES/float_receiver_used.kofun"
assert_grep 'a read result does not move the refusal to the reader' \
    -Fq -- 'error[E2S168]:' "$CASES/float_receiver_used.stderr"

# A01's Int-only boundary is exhaustive over the actual types this Core slice
# can resolve. Unknown bindings are earlier lexical errors; a known Int chain
# followed by an unknown suffix is instead the exact unknown-Int-member error.
for stem in bool_receiver list_receiver record_receiver enum_receiver; do
    assert_grep "$stem names the non-Int receiver's actual type" \
        -Fq -- 'bit operations are defined on `Int`' "$CASES/$stem.stderr"
done
for stem in bool_argument list_argument record_argument enum_argument; do
    assert_grep "$stem is refused as a non-Int ordinary argument" \
        -Fq -- 'takes `Int` arguments' "$CASES/$stem.stderr"
done
for stem in unknown_receiver unknown_argument; do
    assert_grep "$stem keeps lexical resolution precedence" \
        -Fq -- 'error[E2S35]: unknown lexical binding `mystery`' \
        "$CASES/$stem.stderr"
done
assert_grep 'a known bit chain gives its unknown suffix Int authority' \
    -Fq -- 'error[E2S168]: unknown `Int` member `frobnicate`' \
    "$CASES/unknown_after_bit.stderr"
assert_grep 'Optional(Int) receiver is owned by the Int-bit boundary' \
    -Fq -- 'this receiver is `Int?`' "$CASES/optional_receiver.stderr"
assert_grep 'Optional(Int) argument is owned by the Int-bit boundary' \
    -Fq -- 'takes `Int` arguments' "$CASES/optional_argument.stderr"

# Per ordinary argument: bind/check its label, then type-check its expression;
# after all ordinary arguments: expression trailing lambda, then arity. A
# block trailing lambda remains parser-owned E2S158.
assert_grep 'an earlier bad type outranks a later label' \
    -Fq -- 'error[E2S168]: `rotr` takes `Int` arguments' \
    "$CASES/type_before_label.stderr"
assert_grep 'an earlier bad type outranks a trailing lambda' \
    -Fq -- 'error[E2S168]: `and` takes `Int` arguments' \
    "$CASES/type_before_trailing_lambda.stderr"
assert_grep 'a receiver error outranks the receiver call label' \
    -Fq -- 'this receiver is `Bool`' "$CASES/bool_receiver.stderr"
assert_grep 'a label outranks the labelled value type' \
    -Fq -- 'takes positional arguments' "$CASES/label_before_type.stderr"
assert_grep 'an expression trailing lambda outranks wrong arity' \
    -Fq -- 'takes no trailing lambda' \
    "$CASES/trailing_before_arity.stderr"
# The two block-lambda shapes are different boundaries and are asserted
# separately. The trailing one is admitted and refused here only because the
# receiver has no functional parameter; the position one is refused for being
# written where a block body is not recognized.
assert_grep 'a block trailing lambda on a bit receiver is an arity refusal' \
    -Fq -- 'error[E2S169]:' "$CASES/block_trailing_lambda.stderr"
assert_grep 'a block lambda outside the trailing position keeps E2S158' \
    -Fq -- 'error[E2S158]:' "$CASES/block_lambda_position.stderr"
assert_grep 'a bad receiver outranks a later unresolved argument' \
    -Fq -- 'this receiver is `Bool`' \
    "$CASES/receiver_before_unknown.stderr"
assert_grep 'an earlier bad type outranks a later unresolved argument' \
    -Fq -- '`rotr` takes `Int` arguments' \
    "$CASES/type_before_unknown.stderr"
assert_grep 'a label outranks resolution of its value' \
    -Fq -- 'takes positional arguments' \
    "$CASES/label_before_unknown.stderr"
assert_grep 'a nested bad receiver outranks its unresolved argument' \
    -Fq -- 'this receiver is `Bool`' \
    "$CASES/nested_receiver_before_unknown.stderr"
assert_grep 'a nested label outranks resolution of its value' \
    -Fq -- 'takes positional arguments' \
    "$CASES/nested_label_before_unknown.stderr"
assert_grep 'a declared function value is not an Int argument' \
    -Fq -- '`and` takes `Int` arguments' \
    "$CASES/callable_named_argument.stderr"
assert_grep 'a direct lambda is not an Int argument' \
    -Fq -- '`and` takes `Int` arguments' \
    "$CASES/callable_direct_argument.stderr"

# The eight names stay ordinary identifiers. This is checked against the
# compiler pair rather than only by fixture, because a future implementation
# that reserved them would still pass `names_free.kofun` if the gate did not
# say what it is protecting.
for name in and or xor not shl shr rotr wrapping_add; do
    assert_grep "$name is declarable as a function" \
        -Eq -- "^fn $name\\(" "$CASES/names_free.kofun"
done
assert_grep 'a record field may be named for an operation' \
    -Eq -- '^    xor: Int,' "$CASES/names_free.kofun"
assert_grep 'the eight are a member table, not a keyword list' \
    -Fq -- 'fn int_bit_method_arity(name: Text) -> Int {' \
    "$ROOT/bootstrap/stage2/compiler.kofun"
assert_not_grep 'no operation became a reserved word' \
    -Eq -- '"(and|xor|shl|shr|rotr|wrapping_add)"[^)]*reserved' \
    "$ROOT/bootstrap/stage2/compiler.kofun"

# RFC-0013 step 3 is the backends. Until then a backend must refuse rather than
# miscompile, and the native and wasm32 Core parsers do: measured on this tree,
# `return x + 15` builds for `x86_64-linux` and `return x.and(15)` is refused at
# its byte, while wasm32 refuses the token. What makes that safe is that neither
# has an implementation to get wrong — so that is what is asserted here, rather
# than the refusal text, which belongs to those backends' own gates.
assert_not_grep 'the native backend gained an ungated bit implementation' \
    -Fq -- 'kofun_bit_' "$ROOT/bootstrap/native/core_compiler.c"
assert_not_grep 'the wasm32 backend gained an ungated bit implementation' \
    -Fq -- 'kofun_bit_' "$ROOT/bootstrap/wasm/compiler.c"

# Both diagnostics are registered identities, and the runtime code is new.
assert_grep 'E2S168 remains a registered diagnostic identity' \
    -Eq -- '^E2S168[[:space:]]+int-bit-operations[[:space:]]+frontend' \
    "$ROOT/tests/diagnostics/registry.tsv"
assert_grep 'E2S169 remains a registered diagnostic identity' \
    -Eq -- '^E2S169[[:space:]]+int-bit-operations[[:space:]]+frontend' \
    "$ROOT/tests/diagnostics/registry.tsv"
assert_grep 'R011 remains a registered runtime identity' \
    -Eq -- '^R011[[:space:]]+int-bit-runtime[[:space:]]+runtime' \
    "$ROOT/tests/diagnostics/registry.tsv"
assert_grep 'R010 registers the Stage2 shl producer and checked runtime trap' \
    -Eq -- '^R010[[:space:]]+integer-runtime[[:space:]]+runtime[[:space:]]+bootstrap/stage2/compiler\.kofun;bootstrap/stage2/compiler\.c;bootstrap/selfhost/c11/trap_division\.c' \
    "$ROOT/tests/diagnostics/registry.tsv"
assert_grep 'R010 registers both the runtime owner and int-bits observer' \
    -Eq -- 'runtime,int-bits$' "$ROOT/tests/diagnostics/registry.tsv"
assert_grep 'R010 keeps its canonical runtime diagnostic report' \
    -Eq -- '^R010[[:space:]]+runtime[[:space:]]' \
    "$ROOT/tests/diagnostics/reports/runtime.tsv"
assert_grep 'R010 is also observed by the int-bits adapter' \
    -Eq -- '^R010[[:space:]]+int-bits[[:space:]]' \
    "$ROOT/tests/diagnostics/reports/int-bits.tsv"

# Adding a fixture without adding it to this gate must fail the count.
present_count=$(find "$CASES" -name '*.kofun' -type f | wc -l | tr -d ' ')
golden_count=$(find "$CASES" \( -name '*.stdout' -o -name '*.stderr' \) \
    -type f | wc -l | tr -d ' ')
assert_num 'every source fixture is exercised' "$present_count" -eq 43
assert_num 'every source fixture has one golden' "$golden_count" -eq 43

printf '%s\n' \
    'PASS: eight Int bit operations execute with the semantics RFC-0013 fixes' \
    'PASS: shr is arithmetic, rotr and wrapping_add carry their width' \
    'PASS: width/count precedence is fixed; shl overflow is R010 and ranges are R011' \
    'PASS: every resolved non-Int operand and wrong shape refuses before any artifact' \
    'PASS: the eight names remain ordinary functions, fields, and identifiers' \
    'PASS: emitted C is deterministic strict C11 through checked helpers only'

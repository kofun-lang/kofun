#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
cases="$root/tests/conformance/call-arguments"
diagnostics="$root/tests/diagnostics/stage2"
temporary=${TMPDIR:-/tmp}/kofun-call-arguments.$$
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary"

compiler=${CC:-cc}

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    "$cases/observer_test.c" -o "$temporary/observer"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

observations=$(
    "$temporary/observer" "$cases/typed_and_owned.kofun"
)
expected_observations='call-argument|choose|1|0|174|180|text|label|Text|copy
call-argument|choose|0|1|188|196|number|amount|Int|copy
call-argument|consume|0|0|218|224|into|file|Int|take'
actual_observations=$(printf '%s\n' "$observations" |
    grep '^call-argument|')
test "$actual_observations" = "$expected_observations" ||
    fail 'labelled arguments did not retain source order and fixed HIR slots'

scope_hir=$(
    "$temporary/observer" "$cases/typed_and_owned.kofun" scope
)
printf '%s\n' "$scope_hir" |
    grep -F '|amount|immutable|Int|copy|initialized|' >/dev/null ||
    fail 'the first internal parameter name did not bind in HIR'
printf '%s\n' "$scope_hir" |
    grep -F '|label|immutable|Text|copy|initialized|' >/dev/null ||
    fail 'the second internal parameter name did not bind in HIR'
printf '%s\n' "$scope_hir" |
    grep -F '|file|immutable|Int|take|initialized|' >/dev/null ||
    fail 'the take mode did not reach the bound HIR slot'
if printf '%s\n' "$scope_hir" |
    grep -E '\|(number|text|into)\|immutable\|' >/dev/null; then
    fail 'an external label became a lexical body binding'
fi

mismatch=$(
    "$temporary/observer" \
        "$cases/reordered_optional_mismatch.kofun" diagnostic
)
test "$mismatch" = \
    'error[E2S147]: `input` is `Int?`; narrow it with a `null` comparison before using it as `Int` at byte 167' ||
    fail 'the existing optional type check did not use the bound label slot'

duplicate=$(
    "$temporary/observer" "$cases/label_only_duplicate.kofun" diagnostic
)
printf '%s\n' "$duplicate" |
    grep -F 'error[E2S16]: duplicate Core function `identity`' >/dev/null ||
    fail 'external labels participated in callable selection'

"$temporary/observer" \
    "$diagnostics/e2s162_unknown_call_label.kofun" E2S162 - ||
    fail 'E2S162 structured primary span changed'
"$temporary/observer" \
    "$diagnostics/e2s163_duplicate_call_label.kofun" E2S163 in ||
    fail 'E2S163 declaration-related span changed'
"$temporary/observer" \
    "$diagnostics/e2s164_missing_call_argument.kofun" E2S164 from ||
    fail 'E2S164 declaration-related span changed'
"$temporary/observer" \
    "$diagnostics/e2s165_positional_after_label.kofun" E2S165 - ||
    fail 'E2S165 structured primary span changed'
"$temporary/observer" \
    "$diagnostics/e2s166_internal_name_as_label.kofun" E2S166 text ||
    fail 'E2S166 declaration-related span changed'

# Compile the canonical Stage 2 seed itself, then make source order disagree
# with declaration order. C11's comma operator must assign the fixed
# temporaries as written before the ABI-ordered call runs.
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    "$root/bootstrap/stage2/compiler.c" -o "$temporary/stage2"

# Lower one case and run it against its golden. `stem` names the fixture and
# the artifacts, so a second case cannot silently assert against the first
# one's output.
executes_case() {
    stem=$1
    label=$2
    "$temporary/stage2" "$cases/$stem.kofun" \
        "$temporary/$stem.c" "$temporary/$stem.ir" \
        "$temporary/$stem.tokens" >"$temporary/$stem.compiler"
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -I "$root/unicode" \
        "$temporary/$stem.c" -o "$temporary/$stem.program"
    "$temporary/$stem.program" >"$temporary/$stem.stdout"
    cmp "$cases/$stem.stdout" "$temporary/$stem.stdout" ||
        fail "$label did not evaluate once in source order"
}

# The emitted artifact must carry no trace of the surface labels and no
# runtime machinery to resolve them.
no_runtime_dispatch() {
    emitted=$1
    labels=$2
    label=$3
    if grep -E "$labels"'|label_(map|dictionary)|malloc|calloc|realloc' \
        "$emitted" >/dev/null; then
        fail "$label retained labels, runtime dispatch, or allocation"
    fi
}

# The call-start byte keys every temporary at one call site. Reading it from
# slot 0 and interpolating it into the other patterns is what makes these
# assertions describe a single call rather than three unrelated sites.
call_site_key() {
    sed -n 's/.*kofun_call_arg_\([0-9][0-9]*\)_0 .*/\1/p' "$1" | sed -n 1p
}

# #1097: the all-Int slice.
executes_case source_order_int 'labelled Int call'
temporary_count=$(grep -c 'int64_t kofun_call_arg_[0-9][0-9]*_[01] = INT64_C(0);' \
    "$temporary/source_order_int.c")
test "$temporary_count" -eq 2 ||
    fail 'labelled Int call did not reserve exactly two fixed temporaries'
int_key=$(call_site_key "$temporary/source_order_int.c")
test -n "$int_key" ||
    fail 'labelled Int call reserved no keyed temporary'
grep -F "(kofun_call_arg_${int_key}_1 = " "$temporary/source_order_int.c" \
    >/dev/null ||
    fail 'labelled Int call did not key both temporaries to one call site'
grep -E "kofun_call_arg_${int_key}_1 = .*kofun_call_arg_${int_key}_0 = .*kofun_fn_combine\(kofun_call_arg_${int_key}_0, kofun_call_arg_${int_key}_1\)" \
    "$temporary/source_order_int.c" >/dev/null ||
    fail 'generated C did not sequence source order before ABI order'
no_runtime_dispatch "$temporary/source_order_int.c" 'as_first|as_second' \
    'generated C'

# #1107 widened the same fixed-slot lowering to the Text and List[Int]
# carriers the positional path already executes. Mixing all three in one call,
# written in an order that is not the declaration order, is what distinguishes
# source-order evaluation from ABI order: `1` and `3` print before the callee
# body's `42`, and each marker prints exactly once.
#
# The per-slot declaration assertions below pin the carrier each slot is
# reserved with. A carrier regression would also fail the `-Werror` build two
# lines up, but as an opaque diagnostic inside generated C; these name the
# defect instead.
executes_case source_order_carriers 'mixed-carrier labelled call'
carriers_key=$(call_site_key "$temporary/source_order_carriers.c")
test -n "$carriers_key" ||
    fail 'mixed-carrier call reserved no keyed temporary'
grep -F "const char *kofun_call_arg_${carriers_key}_0 = \"\";" \
    "$temporary/source_order_carriers.c" >/dev/null ||
    fail 'the Text slot did not reserve a const char * temporary'
grep -F "KofunIntListValue kofun_call_arg_${carriers_key}_1 = KOFUN_LIST_INT_ZERO;" \
    "$temporary/source_order_carriers.c" >/dev/null ||
    fail 'the List[Int] slot did not reserve a KofunIntListValue temporary'
grep -F "int64_t kofun_call_arg_${carriers_key}_2 = INT64_C(0);" \
    "$temporary/source_order_carriers.c" >/dev/null ||
    fail 'the Int slot did not reserve an int64_t temporary'
# Newlines are squeezed out first: the sequencing property is about operator
# order, not about the emitter keeping the expression on one physical line.
tr -d '\n' <"$temporary/source_order_carriers.c" |
    grep -E "kofun_call_arg_${carriers_key}_2 = .*kofun_call_arg_${carriers_key}_0 = .*kofun_call_arg_${carriers_key}_1 = .*kofun_fn_describe\(kofun_call_arg_${carriers_key}_0, kofun_call_arg_${carriers_key}_1, kofun_call_arg_${carriers_key}_2\)" \
    >/dev/null ||
    fail 'mixed-carrier C did not sequence source order before ABI order'
no_runtime_dispatch "$temporary/source_order_carriers.c" \
    'as_label|as_values|as_count' 'mixed-carrier C'

# #1189 completes the bounded carrier matrix. Optional[Int], concrete enum,
# and nominal record values each reserve their actual C carrier; the written
# order 3, 2, 0, 1 is sequenced once before the declaration-order ABI vector.
executes_case reordered_optional 'reordered Optional[Int] labelled call'
executes_case source_order_wide 'Optional/enum/record labelled call'
wide_key=$(call_site_key "$temporary/source_order_wide.c")
test -n "$wide_key" ||
    fail 'wide-carrier call reserved no keyed temporary'
grep -F "KofunOptionalInt kofun_call_arg_${wide_key}_0 = KOFUN_OPTIONAL_INT_NONE;" \
    "$temporary/source_order_wide.c" >/dev/null ||
    fail 'the Optional[Int] slot did not reserve its aggregate carrier'
grep -F "KofunEnumValue kofun_call_arg_${wide_key}_1 = KOFUN_ENUM_ZERO;" \
    "$temporary/source_order_wide.c" >/dev/null ||
    fail 'the enum slot did not reserve KofunEnumValue'
grep -F "KofunRecord_Ticket kofun_call_arg_${wide_key}_2 = ((KofunRecord_Ticket){0});" \
    "$temporary/source_order_wide.c" >/dev/null ||
    fail 'the nominal record slot did not reserve its record carrier'
grep -F "int64_t kofun_call_arg_${wide_key}_3 = INT64_C(0);" \
    "$temporary/source_order_wide.c" >/dev/null ||
    fail 'the Int companion slot changed carrier'
tr -d '\n' <"$temporary/source_order_wide.c" |
    grep -E "kofun_call_arg_${wide_key}_3 = .*kofun_call_arg_${wide_key}_2 = .*kofun_call_arg_${wide_key}_0 = .*kofun_call_arg_${wide_key}_1 = .*kofun_fn_inspect\(kofun_call_arg_${wide_key}_0, kofun_call_arg_${wide_key}_1, kofun_call_arg_${wide_key}_2, kofun_call_arg_${wide_key}_3\)" \
    >/dev/null ||
    fail 'wide-carrier C did not sequence source order before ABI order'
no_runtime_dispatch "$temporary/source_order_wide.c" \
    'as_number|as_ticket|as_optional|as_reply' 'wide-carrier C'

# A bare binding placed in a `take` parameter slot is one semantic move even
# though C implements the fixed slot as an ordinary assignment. Reusing it in
# a second call must reach the existing registered E2S123 producer.
executes_case owned_carrier 'ownership-bearing labelled call'
owned_key=$(call_site_key "$temporary/owned_carrier.c")
test -n "$owned_key" ||
    fail 'ownership-bearing call reserved no keyed temporary'
test "$(grep -c "kofun_call_arg_${owned_key}_0 = k_b" \
    "$temporary/owned_carrier.c")" -eq 1 ||
    fail 'ownership-bearing value did not move into its slot exactly once'

# Wider carriers and lexical callable bindings remain explicit unsupported
# lowering. They may retain parsed IR/tokens, but must not commit C. The
# shadow case is particularly important: spelling alone must never redirect a
# callable parameter to a same-named top-level function.
unsupported_case() {
    source=$1
    expected=$2
    label=$3
    rm -f "$temporary/unsupported.c" "$temporary/unsupported.ir" \
        "$temporary/unsupported.tokens" "$temporary/unsupported.stdout" \
        "$temporary/unsupported.stderr"
    set +e
    "$temporary/stage2" "$source" \
        "$temporary/unsupported.c" "$temporary/unsupported.ir" \
        "$temporary/unsupported.tokens" \
        >"$temporary/unsupported.stdout" 2>"$temporary/unsupported.stderr"
    unsupported_status=$?
    set -e
    test "$unsupported_status" -eq 1 ||
        fail "$label did not retain its exact refusal status"
    test ! -s "$temporary/unsupported.stderr" ||
        fail "$label wrote stderr"
    test "$(cat "$temporary/unsupported.stdout")" = "$expected" ||
        fail "$label diagnostic changed"
    test ! -e "$temporary/unsupported.c" ||
        fail "$label committed C"
}

unsupported_case "$cases/double_move_carrier.kofun" \
    "$(cat "$cases/double_move_carrier.diagnostic")" \
    'double move through a take-labelled slot'
unsupported_case "$cases/shadowed_callable.kofun" \
    'error[E2S158]: labelled-call ABI lowering is owned by #882; fixed-slot checked HIR is available at byte 212' \
    'shadowed callable parameter'
unsupported_case "$cases/lifted_lambda_call.kofun" \
    'error[E2S158]: labelled-call ABI lowering is owned by #882; fixed-slot checked HIR is available at byte 140' \
    'labelled call inside a lifted lambda'

printf '%s\n' \
    'PASS: labelled calls bind fixed HIR slots and the Int/Text/List[Int]/Optional/enum/record C11 slice evaluates once in source order; take slots move once and refuse double transfer as E2S123; #882 retains pipeline/trailing/lambda-body forms and other backends'

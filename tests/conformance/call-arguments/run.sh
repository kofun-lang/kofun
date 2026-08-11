#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
cases="$root/tests/conformance/call-arguments"
diagnostics="$root/tests/diagnostics/stage2"
. "$root/bootstrap/stage2/build.sh"
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
kofun_stage2_build "$root" "$temporary/stage2"

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

# #1191 admits the accepted trailing-lambda form: `callee(...) fn(p) => e`.
# The lambda binds the final functional parameter without being written
# between the parentheses, so this case proves the two orders stay separate
# while an argument sits outside them — the labelled `2`, `1` still evaluate
# in source order, the ABI vector is still declaration order (`12`), and the
# trailing lambda runs last over the result (`112`).
executes_case trailing_lambda 'trailing lambda after labelled arguments'
trailing_key=$(call_site_key "$temporary/trailing_lambda.c")
test -n "$trailing_key" ||
    fail 'trailing-lambda call reserved no keyed temporary'
# Two carriers, not three. The trailing lambda is a lifted function's address:
# there is nothing to sequence ahead of the call, and an `int64_t` carrier
# would both mistype the slot and be passed unassigned.
trailing_count=$(grep -c "int64_t kofun_call_arg_${trailing_key}_[0-9][0-9]* = INT64_C(0);" \
    "$temporary/trailing_lambda.c")
test "$trailing_count" -eq 2 ||
    fail 'the trailing lambda slot reserved a carrier instead of an address'
# The lifted name is keyed by the `(` of the lambda's parameter list, so the
# walk that emits the definition and the walk that emits the reference agree.
trailing_lifted=$(sed -n \
    's/.*\(kofun_lambda_at[0-9][0-9]*\)(int64_t .*/\1/p' \
    "$temporary/trailing_lambda.c" | sed -n 1p)
test -n "$trailing_lifted" ||
    fail 'the trailing lambda was not lifted to a top-level function'
tr -d '\n' <"$temporary/trailing_lambda.c" |
    grep -E "kofun_call_arg_${trailing_key}_1 = .*kofun_call_arg_${trailing_key}_0 = .*kofun_fn_combine\(kofun_call_arg_${trailing_key}_0, kofun_call_arg_${trailing_key}_1, ${trailing_lifted}\)" \
    >/dev/null ||
    fail 'trailing-lambda C did not place the lifted address in the final slot'
no_runtime_dispatch "$temporary/trailing_lambda.c" 'as_first|as_second|then' \
    'trailing-lambda C'

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
# The two remaining E2S158 shapes are different boundaries, so they are
# asserted separately rather than through one pattern. The case above is about
# where a labelled call may appear; this one is about what a trailing lambda's
# body may be. #1191 admitted the expression body and held this one, so a
# slice that later admits the block body must move this assertion and leave
# the lifted-lambda wording untouched.
unsupported_case "$cases/trailing_lambda_block.kofun" \
    'error[E2S158]: a trailing lambda with a block body is specified by call-arguments v1 but not implemented at byte 116' \
    'trailing lambda with a block body'

# #1190 recognizes `subject |> callee(arguments)` as one production and fails
# closed before slot binding. What it buys is the diagnostic: before it, every
# one of these reported an argument list the author did not get wrong —
# `E2S164 missing argument \`base\`` or `E2S17 expects 2, got 1` — and never
# mentioned the pipeline that was actually unsupported. Each shape outside the
# production gets its own wording, so a later slice admitting one leaves the
# others' evidence standing.
unsupported_case "$cases/pipeline_subject.kofun" \
    'error[E2S158]: a pipeline subject binds slot 0; call-arguments v1 pipeline lowering is owned by #1228 at byte 127' \
    'direct-call pipeline subject'
unsupported_case "$cases/pipeline_coalescing_subject.kofun" \
    'error[E2S158]: a pipeline subject binds slot 0; call-arguments v1 pipeline lowering is owned by #1228 at byte 139' \
    'pipeline subject containing a coalescing expression'
unsupported_case "$cases/pipeline_bare_target.kofun" \
    'error[E2S158]: a pipeline target must be a direct call written with its parentheses at byte 105' \
    'pipeline with a bare callee'
# A member target has its parentheses, so the bare-callee wording would name the
# wrong defect. These two are separate assertions because they are separate
# boundaries, and the corpus row that motivated it — tests/usability row 8 —
# is a member pipeline, not a bare one.
unsupported_case "$cases/pipeline_member_target.kofun" \
    'error[E2S158]: a pipeline target must be a top-level function, not a member call at byte 84' \
    'pipeline with a member target'
unsupported_case "$cases/pipeline_chain.kofun" \
    'error[E2S158]: a pipeline chain is specified by call-arguments v1 but not recognized at byte 105' \
    'pipeline chain'
unsupported_case "$cases/pipeline_trailing_lambda.kofun" \
    'error[E2S158]: a pipeline with a trailing lambda is specified by call-arguments v1 but not recognized at byte 131' \
    'pipeline with a trailing lambda'

# #1226 binds the subject to slot 0 before any explicit argument is read. Both
# halves of that are asserted, because either alone would pass while the call
# was still wrong: the subject must take slot 0 at source index 0, and the
# explicit arguments must then start at slot 1 rather than overwrite it.
#
# The externally labelled case is the one that proves the rule rather than a
# coincidence: `into` is slot 0's declared label, and the subject binds it
# without the label being written anywhere in the call.
subject_binding=$(
    "$temporary/observer" "$cases/pipeline_subject.kofun" |
        grep '^call-argument|'
)
test "$subject_binding" = 'call-argument|add|0|0|121|121|unlabelled|base|Int|copy
call-argument|add|1|1|134|141|delta|amount|Int|copy' ||
    fail 'pipeline subject did not bind slot 0 ahead of the labelled argument'

# The positional case is where a missing slot-0 binding would be invisible:
# without it the written `2` binds slot 0 and the call looks well formed.
positional_binding=$(
    "$temporary/observer" "$cases/pipeline_positional_rest.kofun" |
        grep '^call-argument|'
)
test "$positional_binding" = 'call-argument|add|0|0|115|115|unlabelled|base|Int|copy
call-argument|add|1|1|128|128|unlabelled|amount|Int|copy' ||
    fail 'positional explicit arguments did not start at slot 1'

# Supplying slot 0 again by its declared label is an ordinary duplicate, and
# reaches the existing E2S163 producer with the declaration as its related span
# — the subject binding is a binding like any other, not a special case beside
# the binder.
unsupported_case "$cases/pipeline_duplicate_slot_zero.kofun" \
    'error[E2S163]: duplicate call label `into` at byte 139' \
    'pipeline subject and an explicit argument for slot 0'

# #1227 checks the bound call. Effective arity is one subject plus the written
# arguments, so this reports 3 for a two-parameter callee — the count is now
# right, rather than merely kept away by an earlier refusal. Asserting the
# overflow is what distinguishes those two: the four canonical shapes stopped
# reaching E2S17 the moment #1190 refused them, whether or not anything counted.
unsupported_case "$cases/pipeline_effective_arity.kofun" \
    'error[E2S17]: Core function `add` expects 2 arguments, got 3 at byte 124' \
    'pipeline effective arity counts the subject'

# The subject is checked against slot 0 and reported at its own span. Pointing
# at the callee would name the one token that is not wrong.
unsupported_case "$cases/pipeline_subject_type_mismatch.kofun" \
    'error[E2S15]: Core function `add` expects Int for argument 1, got Text at byte 126' \
    'pipeline subject type is checked against slot 0'

# RFC-0010, reached without a label: the subject flows into a `take` slot 0, so
# it moves exactly once and the later use is the existing E2S123 with both
# spans. `move_call_binding` admits it on the declared mode of slot 0 rather
# than on how it was written, because a subject is never written with a label.
unsupported_case "$cases/pipeline_take_subject.kofun" \
    'error[E2S123]: `ticket` was moved by `take` and cannot be used again at bytes 280..286; moved by `take` at bytes 241..247' \
    'pipeline subject moves once into a take slot'

# A compound subject transfers nothing: there is no binding for a move to
# invalidate, so no synthetic move is recorded and the call reaches the
# boundary. This is the half that a looser bare-binding test would break —
# and it nearly did, because the pipeline production made `expression_end`
# swallow the whole call, so the subject's extent must be measured with
# `coalescing_expression_end`.
unsupported_case "$cases/pipeline_compound_subject.kofun" \
    'error[E2S158]: a pipeline subject binds slot 0; call-arguments v1 pipeline lowering is owned by #1228 at byte 162' \
    'compound pipeline subject records no move'

# The spans the binder in #1226 inherits. Asserting them here is what makes the
# production reviewable before anything consumes it: a recognizer that refuses
# everything looks identical to one that recognizes nothing, unless it publishes
# what it saw.
#
# `subject end` is the subject's own end, not the pipe's offset — they differ by
# the trivia between them, and a field repeating another one would be worth
# nothing to its reader.
pipeline_spans=$(
    "$temporary/observer" "$cases/pipeline_subject.kofun" |
        grep '^pipeline|'
)
test "$pipeline_spans" = 'pipeline|add|121|126|127|130|133|142|121|143' ||
    fail 'pipeline spans changed'

# `??` binds inside the subject, so `|>` is the lowest-precedence boundary
# rather than an operator competing with it. The subject span covering
# `left ?? 4` is the whole of that claim.
coalescing_spans=$(
    "$temporary/observer" "$cases/pipeline_coalescing_subject.kofun" |
        grep '^pipeline|'
)
test "$coalescing_spans" = 'pipeline|add|129|138|139|142|145|154|129|155' ||
    fail 'coalescing pipeline subject did not bind `??` first'

printf '%s\n' \
    'PASS: labelled calls bind fixed HIR slots and the Int/Text/List[Int]/Optional/enum/record C11 slice evaluates once in source order; take slots move once and refuse double transfer as E2S123; the expression-bodied trailing lambda binds the final parameter as a lifted address; the direct-call pipeline is one production whose spans are published and whose subject binds slot 0 ahead of the explicit arguments and is then counted, type-checked, and moved once into a take slot; #882 retains pipeline lowering, block-bodied trailing, and lambda-body forms and other backends'

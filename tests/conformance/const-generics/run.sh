#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CORPUS="$ROOT/tests/conformance/const-generics"
CASES="$CORPUS/cases"
PRODUCT="$CORPUS/product"
CC=${CC:-cc}
ANALYZER_CC=${ANALYZER_CC:-gcc}
WORK=${KOFUN_CONST_GENERICS_FRONTEND_WORK:-"$ROOT/build/const-generics-frontend"}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v "$ANALYZER_CC" >/dev/null 2>&1 ||
    fail 'GCC is required for the static analyzer gate'
case $WORK in
    */const-generics-frontend|*/const-generics-frontend.*) ;;
    *) fail "work directory must end in const-generics-frontend[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/remapped"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/const_generics_frontend.c" \
    -o "$WORK/kofun-const-generics-frontend"
"$ANALYZER_CC" -std=c11 -O0 -g -Wall -Wextra -Werror -pedantic \
    -fanalyzer "$ROOT/bootstrap/stage2/const_generics_frontend.c" \
    -o "$WORK/kofun-const-generics-analyzer"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/stage2/const_generics_frontend.c" \
    -o "$WORK/kofun-const-generics-sanitize"

cp "$CASES/positive.kofun" "$WORK/remapped/positive.kofun"
for suffix in first second remapped; do
    source="$CASES/positive.kofun"
    test "$suffix" = remapped && source="$WORK/remapped/positive.kofun"
    "$WORK/kofun-const-generics-frontend" "$source" \
        "$WORK/positive.$suffix.ir" "$WORK/positive.$suffix.tokens" \
        >"$WORK/positive.$suffix.stdout" \
        2>"$WORK/positive.$suffix.stderr"
    test ! -s "$WORK/positive.$suffix.stdout" ||
        fail "$suffix positive run wrote stdout"
    test ! -s "$WORK/positive.$suffix.stderr" ||
        fail "$suffix positive run wrote stderr"
done
cmp "$WORK/positive.first.ir" "$WORK/positive.second.ir" ||
    fail 'repeated const generic IR differs'
cmp "$WORK/positive.first.tokens" "$WORK/positive.second.tokens" ||
    fail 'repeated const generic token tape differs'
cmp "$WORK/positive.first.ir" "$WORK/positive.remapped.ir" ||
    fail 'const generic IR depends on the host source path'
cmp "$WORK/positive.first.tokens" "$WORK/positive.remapped.tokens" ||
    fail 'const generic token tape depends on the host source path'
cmp "$CASES/positive.ir" "$WORK/positive.first.ir" ||
    fail 'positive const generic typed IR differs from its golden'

# The bounded frontend's wider surface: an ordinary type parameter, a nominal
# with no parameter, a declaration used before it is written, and an
# instantiation in a field. The product path refuses this whole source, and
# that boundary is measured below rather than assumed.
"$WORK/kofun-const-generics-frontend" "$CASES/frontend_surface.kofun" \
    "$WORK/frontend_surface.ir" "$WORK/frontend_surface.tokens" \
    >"$WORK/frontend_surface.stdout" 2>"$WORK/frontend_surface.stderr"
test ! -s "$WORK/frontend_surface.stdout" ||
    fail 'frontend surface run wrote stdout'
test ! -s "$WORK/frontend_surface.stderr" ||
    fail 'frontend surface run wrote stderr'
cmp "$CASES/frontend_surface.ir" "$WORK/frontend_surface.ir" ||
    fail 'frontend surface typed IR differs from its golden'
grep -F \
    'instantiation-id=nominal:Boxed/args=builtin:Int' \
    "$WORK/frontend_surface.ir" >/dev/null ||
    fail 'an ordinary type argument lost its builtin namespace'
grep -F \
    'instantiation-id=nominal:Boxed/args=nominal:Money' \
    "$WORK/frontend_surface.ir" >/dev/null ||
    fail 'a nominal type argument lost its nominal namespace'
grep -F 'name=T|index=0|ownership-kind=substituted' \
    "$WORK/frontend_surface.ir" >/dev/null ||
    fail 'an ordinary type parameter must still propagate a kind'

# A literal argument reaches the identity in a `const:` namespace of its own,
# so it can never be confused with a type argument by anything that embeds a
# normalized argument — including the `args=` component #936 assembles an
# ImplementationId, and from it a DictionaryId, out of.
grep -F \
    'const-parameter-id=const-parameter:nominal:Fixed:0' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'the const parameter identity is missing'
grep -F \
    'type=builtin:Int|index=0|minimum=0|maximum=65535|ownership-kind=neutral' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'the const parameter did not record its Int type, range, and kind'
grep -F \
    'instantiation-id=nominal:Fixed/args=const:Int:2' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'Fixed[2] has no instantiation identity'
grep -F \
    'instantiation-id=nominal:Fixed/args=const:Int:3' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'Fixed[3] has no instantiation identity'
if grep -F 'args=const:Int:02' "$WORK/positive.first.ir" >/dev/null; then
    fail 'a const argument was normalized by digits instead of by value'
fi
distinct=$(grep -c '^instantiation|' "$WORK/positive.first.ir" || true)
test "$distinct" -eq 2 ||
    fail "expected 2 distinct instantiations, saw $distinct"
folded=$(sed -n \
    's/^instantiation|instantiation-id=nominal:Fixed\/args=const:Int:2|.*|uses=\([0-9]*\)|.*/\1/p' \
    "$WORK/positive.first.ir")
test -n "$folded" ||
    fail 'the Fixed[2] instantiation row is missing its use count'
test "$folded" -eq 6 ||
    fail "Fixed[2] and Fixed[02] did not fold into one instantiation: uses=$folded"

failures='
argument_on_plain_type:E2S150
const_argument_for_type_parameter:E2S149
const_argument_out_of_range:E2S149
const_parameter_as_field_type:E2S148
const_parameter_as_value:E2S148
instantiation_limit:E2S152
missing_const_argument:E2S150
multiple_parameters:E2S148
negative_const_argument:E2S149
non_int_const_parameter:E2S148
non_literal_const_argument:E2S149
scale_mismatch_annotation:E2S151
scale_mismatch_argument:E2S151
too_many_const_arguments:E2S150
type_argument_for_const_parameter:E2S149
'

previous_ifs=$IFS
IFS='
'
for entry in $failures; do
    test -n "$entry" || continue
    stem=${entry%%:*}
    code=${entry#*:}
    set +e
    "$WORK/kofun-const-generics-frontend" "$CASES/$stem.kofun" \
        "$WORK/$stem.ir" "$WORK/$stem.tokens" \
        >"$WORK/$stem.actual" 2>"$WORK/$stem.internal.stderr"
    status=$?
    set -e
    test "$status" -eq 1 ||
        fail "$stem exited $status instead of 1"
    cmp "$CASES/$stem.stderr" "$WORK/$stem.actual" ||
        fail "$stem diagnostic differs"
    grep -F "error[$code]:" "$WORK/$stem.actual" >/dev/null ||
        fail "$stem expected $code"
    test ! -s "$WORK/$stem.internal.stderr" ||
        fail "$stem wrote internal stderr"
    test ! -e "$WORK/$stem.ir" ||
        fail "$stem emitted rejected typed IR"
    test ! -e "$WORK/$stem.tokens" ||
        fail "$stem emitted rejected tokens"
done
IFS=$previous_ifs

ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/kofun-const-generics-sanitize" "$CASES/positive.kofun" \
    "$WORK/sanitize.ir" "$WORK/sanitize.tokens" \
    >"$WORK/sanitize.stdout" 2>"$WORK/sanitize.stderr"
test ! -s "$WORK/sanitize.stdout" ||
    fail 'sanitized positive run wrote stdout'
test ! -s "$WORK/sanitize.stderr" ||
    fail 'ASan/UBSan reported a positive-path finding'
cmp "$CASES/positive.ir" "$WORK/sanitize.ir" ||
    fail 'sanitized const generic IR differs'

IFS='
'
for entry in $failures; do
    test -n "$entry" || continue
    stem=${entry%%:*}
    set +e
    ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/kofun-const-generics-sanitize" "$CASES/$stem.kofun" \
        "$WORK/$stem.sanitize.ir" "$WORK/$stem.sanitize.tokens" \
        >"$WORK/$stem.sanitize.actual" \
        2>"$WORK/$stem.sanitize.internal.stderr"
    status=$?
    set -e
    test "$status" -eq 1 ||
        fail "sanitized $stem exited $status instead of 1"
    cmp "$CASES/$stem.stderr" "$WORK/$stem.sanitize.actual" ||
        fail "sanitized $stem diagnostic differs"
    test ! -s "$WORK/$stem.sanitize.internal.stderr" ||
        fail "ASan/UBSan reported a finding for $stem"
    test ! -e "$WORK/$stem.sanitize.ir" ||
        fail "sanitized $stem emitted rejected typed IR"
    test ! -e "$WORK/$stem.sanitize.tokens" ||
        fail "sanitized $stem emitted rejected tokens"
done
IFS=$previous_ifs

test -z "$(find "$WORK" -type f \
    \( -name '*.generated.c' -o -name '*.o' -o -name '*.wasm' \
       -o -name '*.elf' -o -name '*.native' \) -print)" ||
    fail 'const generic frontend emitted a backend/runtime artifact'

# The ordinary compile path. A frontend-only fact does not complete #916: the
# capability has to be reachable through the compiler the CLI actually runs,
# which is `bootstrap/stage2/compiler.c` under `--compile-outcome`.
kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"

"$WORK/kofun-stage2" --compile-outcome "$CASES/positive.kofun" \
    "$WORK/product.c" "$WORK/product.ir" "$WORK/product.tokens" \
    >"$WORK/product.stdout" 2>"$WORK/product.stderr"
test ! -s "$WORK/product.stderr" ||
    fail 'the product path wrote stderr for the shared positive'
test -s "$WORK/product.c" ||
    fail 'the product path emitted no C for the shared positive'

# Per-literal monomorphization, measured rather than described: two literals,
# two emitted structs. A backend that shared one struct between them would make
# the C type system stop separating what the Kofun type system separated, which
# is the defect `validate_struct_identity` refuses and the falsification below
# demonstrates.
grep -F '} KofunRecord_Fixed__2;' "$WORK/product.c" >/dev/null ||
    fail 'Fixed[2] did not reach its own emitted struct'
grep -F '} KofunRecord_Fixed__3;' "$WORK/product.c" >/dev/null ||
    fail 'Fixed[3] did not reach its own emitted struct'
if grep -F '} KofunRecord_Fixed;' "$WORK/product.c" >/dev/null; then
    fail 'a shared unspecialized Fixed struct survived'
fi
if grep -F 'Fixed[' "$WORK/product.c" >/dev/null; then
    fail 'a const argument survived into a C identifier'
fi
# `-Wno-unused-function` only: the fixture declares signatures its entry point
# does not call. Every other warning stays fatal.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-function \
    -I"$ROOT/bootstrap/stage2" "$WORK/product.c" -o "$WORK/product" ||
    fail 'the specialized C the product path emitted does not build'
"$WORK/product" >"$WORK/product.run.stdout" 2>"$WORK/product.run.stderr" ||
    fail 'the program the product path built does not run'
test ! -s "$WORK/product.run.stderr" ||
    fail 'the program the product path built wrote stderr'

# The #725 Part B handoff: two scales constructed, kept apart by the type
# system, and observed running. This is the evidence #916's final criterion
# asks for, so it is executed here and not only described.
"$WORK/kofun-stage2" --compile-outcome "$CORPUS/fixed_scale_instantiation.kofun" \
    "$WORK/handoff.c" "$WORK/handoff.ir" "$WORK/handoff.tokens" \
    >"$WORK/handoff.stdout" 2>"$WORK/handoff.stderr"
test ! -s "$WORK/handoff.stderr" ||
    fail 'the Part B handoff wrote stderr'
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    -I"$ROOT/bootstrap/stage2" "$WORK/handoff.c" -o "$WORK/handoff" ||
    fail 'the constructed const generic program does not build'
"$WORK/handoff" >"$WORK/handoff.run.stdout" 2>"$WORK/handoff.run.stderr"
test ! -s "$WORK/handoff.run.stderr" ||
    fail 'the constructed const generic program wrote stderr'
printf '%s\n' 250 2500 >"$WORK/handoff.expected"
cmp "$WORK/handoff.expected" "$WORK/handoff.run.stdout" ||
    fail 'the two constructed scales did not both reach the output'

# Falsification of the identity guard: collapse the specialization exactly the
# way the earlier revision did — drop the const argument on the way to the C
# struct name — and the guard must refuse the source instead of silently
# sharing one struct between two types.
sed 's/KofunRecord_%s__%s/KofunRecord_%s%.0s/' \
    "$ROOT/bootstrap/stage2/compiler.c" >"$WORK/collapsed.c"
cmp -s "$ROOT/bootstrap/stage2/compiler.c" "$WORK/collapsed.c" &&
    fail 'the specialization could not be collapsed, so the guard is untested'
"$CC" -std=c11 -O2 -w -I"$ROOT/bootstrap/stage2" \
    "$WORK/collapsed.c" -o "$WORK/kofun-stage2-collapsed"
set +e
"$WORK/kofun-stage2-collapsed" --compile-outcome "$CASES/positive.kofun" \
    "$WORK/collapsed.out.c" "$WORK/collapsed.ir" "$WORK/collapsed.tokens" \
    >"$WORK/collapsed.actual" 2>/dev/null
collapsed_status=$?
set -e
test "$collapsed_status" -ne 0 ||
    fail 'a collapsed specialization was accepted: two types shared one struct'
grep -F 'error[E2S153]:' "$WORK/collapsed.actual" >/dev/null ||
    fail 'the identity guard did not fire on a collapsed specialization'
test ! -e "$WORK/collapsed.out.c" ||
    fail 'the identity guard refused but C was still written'

product_failures='
const_argument_out_of_range:E2S149
const_argument_reaches_layout:E2S148
const_parameter_on_enum:E2S148
missing_const_argument:E2S150
negative_const_argument:E2S149
non_literal_const_argument:E2S149
scale_mismatch:E2S151
struct_identity_collision:E2S153
type_parameter_record:E2S148
'

IFS='
'
for entry in $product_failures; do
    test -n "$entry" || continue
    stem=${entry%%:*}
    code=${entry#*:}
    set +e
    "$WORK/kofun-stage2" --compile-outcome "$PRODUCT/$stem.kofun" \
        "$WORK/$stem.product.c" "$WORK/$stem.product.ir" \
        "$WORK/$stem.product.tokens" \
        >"$WORK/$stem.product.actual" 2>"$WORK/$stem.product.stderr"
    status=$?
    set -e
    test "$status" -ne 0 ||
        fail "the product path accepted $stem"
    cmp "$PRODUCT/$stem.stdout" "$WORK/$stem.product.actual" ||
        fail "product $stem diagnostic differs"
    grep -F "error[$code]:" "$WORK/$stem.product.actual" >/dev/null ||
        fail "product $stem expected $code"
    test ! -s "$WORK/$stem.product.stderr" ||
        fail "product $stem wrote internal stderr"
    test ! -e "$WORK/$stem.product.c" ||
        fail "product $stem emitted rejected C"
done
IFS=$previous_ifs

# The erasure sentinel. An annotation reader that returns only the head token
# makes `Fixed[3]` and `Fixed[2]` the same type, and `scale_mismatch` compiles
# with every other check still green. Naming it here is what stops that
# specific defect coming back unnoticed.
grep -F 'Fixed[3]` is not `Fixed[2]' \
    "$PRODUCT/scale_mismatch.stdout" >/dev/null ||
    fail 'the erasure sentinel no longer names both instantiations'

# The bounded frontend accepts an ordinary type parameter; the product path
# refuses it by name. Neither is allowed to drift into the other silently.
set +e
"$WORK/kofun-stage2" --compile-outcome "$CASES/frontend_surface.kofun" \
    "$WORK/frontend_surface.product.c" "$WORK/frontend_surface.product.ir" \
    "$WORK/frontend_surface.product.tokens" \
    >"$WORK/frontend_surface.product.actual" 2>/dev/null
surface_status=$?
set -e
test "$surface_status" -ne 0 ||
    fail 'the product path accepted a surface only the bounded frontend models'
grep -F 'error[E2S148]:' "$WORK/frontend_surface.product.actual" >/dev/null ||
    fail 'the product path must refuse the wider surface by name'
test ! -e "$WORK/frontend_surface.product.c" ||
    fail 'the product path emitted C for a surface it refuses'
# The ordinary type parameter itself is pinned on its own fixture above, so
# whichever refusal this wider source reaches first, that one stays measured.
grep -F 'error[E2S148]: type parameters on a nominal type are unsupported' \
    "$PRODUCT/type_parameter_record.stdout" >/dev/null ||
    fail 'the product path must refuse an ordinary type parameter by name'

# Backend honesty. Monomorphizing per distinct literal is the other admissible
# answer; until a backend does it, each one must say so where the manifest
# records it, and the runner must report that refusal rather than executing a
# corpus nobody lowers.
declared=0
specializing=0
refusing=0
for adapter in "$ROOT/tests/conformance/backends"/*.sh; do
    test -f "$adapter" || continue
    backend=$(basename "${adapter%.sh}")
    declared=$((declared + 1))
    row=$(awk -F '\t' -v backend="$backend" \
        '$1 == backend && $2 == "const-generics" { print; exit }' \
        "$ROOT/tests/conformance/capabilities.tsv")
    test -n "$row" ||
        fail "$backend has no const-generics capability row"
    state=$(printf '%s\n' "$row" | awk -F '\t' '{ print $3 }')
    reason=$(printf '%s\n' "$row" | awk -F '\t' '{ print $5 }')
    case $state in
        unsupported)
            if test -z "$reason" || test "$reason" = '-'; then
                fail "$backend refuses const-generics without a reason"
            fi
            refusing=$((refusing + 1))
            ;;
        supported)
            # Only the C11 Stage 2 backend specializes, and the assertions
            # above are what prove it: two literals, two emitted structs, a
            # program that builds and runs. Any other backend claiming this
            # corpus has to earn the same evidence first.
            test "$backend" = c11-stage2 ||
                fail "$backend claims const-generics: prove per-literal monomorphization in this gate before declaring it"
            specializing=$((specializing + 1))
            ;;
        *)
            fail "$backend has an unknown const-generics state: $state"
            ;;
    esac
done
test "$declared" -gt 0 ||
    fail 'no backend adapters were found to hold to a capability row'
test "$specializing" -eq 1 ||
    fail "expected exactly one specializing backend, saw $specializing"
test "$refusing" -eq "$((declared - 1))" ||
    fail "expected $((declared - 1)) explicit refusals, saw $refusing"

sh "$ROOT/tests/conformance/run.sh" "$CORPUS" \
    >"$WORK/backends.stdout" 2>"$WORK/backends.stderr" ||
    fail 'the conformance runner did not accept the const-generics corpus'
refusals=$(grep -c '^UNSUPPORTED \[' "$WORK/backends.stdout" || true)
test "$refusals" -eq "$refusing" ||
    fail "expected $refusing explicit backend refusals, saw $refusals"
grep -F 'PASS [c11-stage2]' "$WORK/backends.stdout" >/dev/null ||
    fail 'the specializing backend did not execute the corpus'

printf '%s\n' \
    'PASS: a literal Int type argument type-checks in declarations and annotations' \
    'PASS: Fixed[2] and Fixed[3] are distinct types and Fixed[02] normalizes to Fixed[2]' \
    'PASS: the ordinary compile path specializes per literal and its C builds and runs' \
    'PASS: two scales are constructed, kept apart, and observed running' \
    'PASS: distinct types reach distinct structs, and collapsing them is refused' \
    'PASS: non-literal, negative, out-of-range, and kind-mismatched arguments leave no artifact' \
    'PASS: one backend specializes with evidence and every other refuses by name' \
    'PASS: typed-only boundaries, GCC analyzer, and ASan/UBSan remain clean'

#!/usr/bin/env sh
set -eu

# Optional narrowing (#312). The contract this gate holds the frontend to:
#
#   - the four recognized comparison shapes narrow, and only on their own edge;
#   - a definitely-returning guard carries the opposite edge past it;
#   - every listed invalidation rule rejects an unsafe use of `x` as `T`;
#   - the declared type stays `Optional(T)` through assignments and joins;
#   - unsupported shapes stay errors rather than optimistic assumptions;
#   - nothing here claims a runtime representation.
#
# Each refusal below is paired with a positive counterpart in `positive.kofun`,
# so a refusal proves the rule fired rather than proving narrowing never
# worked in the first place.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/optional-narrowing"
CC=${CC:-cc}
ANALYZER_CC=${ANALYZER_CC:-gcc}
WORK=${KOFUN_OPTIONAL_NARROWING_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}optional-narrowing"}

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v "$ANALYZER_CC" >/dev/null 2>&1 ||
    fail 'GCC is required for the static analyzer gate'
case $WORK in
    */optional-narrowing|*/optional-narrowing.*) ;;
    *) fail "work directory must end in optional-narrowing[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/remapped"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/optional_frontend.c" \
    -o "$WORK/kofun-optional-frontend"
"$ANALYZER_CC" -std=c11 -O0 -g -Wall -Wextra -Werror -pedantic \
    -fanalyzer "$ROOT/bootstrap/stage2/optional_frontend.c" \
    -o "$WORK/kofun-optional-analyzer"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/stage2/optional_frontend.c" \
    -o "$WORK/kofun-optional-sanitize"

cp "$CASES/positive.kofun" "$WORK/remapped/positive.kofun"
for suffix in first second remapped; do
    source="$CASES/positive.kofun"
    test "$suffix" = remapped && source="$WORK/remapped/positive.kofun"
    "$WORK/kofun-optional-frontend" "$source" \
        "$WORK/positive.$suffix.ir" "$WORK/positive.$suffix.tokens" \
        >"$WORK/positive.$suffix.stdout" \
        2>"$WORK/positive.$suffix.stderr"
    test ! -s "$WORK/positive.$suffix.stdout" ||
        fail "$suffix positive run wrote stdout"
    test ! -s "$WORK/positive.$suffix.stderr" ||
        fail "$suffix positive run wrote stderr"
done
cmp "$WORK/positive.first.ir" "$WORK/positive.second.ir" ||
    fail 'repeated narrowing IR differs'
cmp "$WORK/positive.first.ir" "$WORK/positive.remapped.ir" ||
    fail 'narrowing IR depends on the host source path'
cmp "$CASES/positive.ir" "$WORK/positive.first.ir" ||
    fail 'positive narrowing typed IR differs from its golden'

IR="$WORK/positive.first.ir"

# Recognized edges carry explicit refinement facts keyed by binding identity,
# and every fact names the declared type beside the refined one: a refinement
# is an extra fact about an edge, never a rewrite of the declaration.
grep -F 'refinement|owner=function:not_null_name_first|binding=parameter:not_null_name_first:x|declared=Optional(builtin:Int)|narrowed=builtin:Int|edge=true' \
    "$IR" >/dev/null || fail 'x != null did not refine the true edge'
grep -F 'refinement|owner=function:not_null_null_first|binding=parameter:not_null_null_first:x|declared=Optional(builtin:Int)|narrowed=builtin:Int|edge=true' \
    "$IR" >/dev/null || fail 'null != x did not refine the true edge'
grep -F 'refinement|owner=function:is_null_name_first|binding=parameter:is_null_name_first:x|declared=Optional(builtin:Int)|narrowed=builtin:Int|edge=false' \
    "$IR" >/dev/null || fail 'x == null did not refine the false edge'
grep -F 'refinement|owner=function:is_null_null_first|binding=parameter:is_null_null_first:x|declared=Optional(builtin:Int)|narrowed=builtin:Int|edge=false' \
    "$IR" >/dev/null || fail 'null == x did not refine the false edge'

# Every refinement row keeps the declared type optional. A row whose declared
# type had been rewritten to the refined one would mean the fact escaped into
# the declaration.
! grep -E '^refinement\|[^|]*\|[^|]*\|declared=builtin:' "$IR" >/dev/null ||
    fail 'a refinement rewrote the declared type'

# A definitely-returning guard carries the opposite edge past it; the
# non-terminating counterpart below is refused.
grep -F 'narrowed-use|owner=function:guard|binding=parameter:guard:x|declared=Optional(builtin:Int)|used-as=builtin:Int' \
    "$IR" >/dev/null || fail 'the early-return guard did not carry the refinement'
grep -F 'narrowed-use|owner=function:inverse_guard|binding=parameter:inverse_guard:x' \
    "$IR" >/dev/null || fail 'the inverse early-return guard did not narrow'

# Branch-local arithmetic types both operands as T, and a nested branch sits
# under the dominating outer refinement.
test "$(grep -c 'narrowed-use|owner=function:branch_local|' "$IR")" -eq 2 ||
    fail 'branch-local arithmetic did not use T on both operands'
test "$(grep -c 'narrowed-use|owner=function:nested|' "$IR")" -eq 2 ||
    fail 'the outer refinement did not dominate the nested branch'

# An immutable binding keeps its refinement across calls; a mutable one loses
# it, and the discard is recorded with its reason rather than inferred from the
# absence of an error.
test "$(grep -c 'narrowed-use|owner=function:immutable_across_call|' "$IR")" \
    -eq 2 || fail 'an immutable refinement did not survive a call'
! grep -F 'refinement-discarded|owner=function:immutable_across_call' "$IR" \
    >/dev/null || fail 'an immutable binding lost its refinement to a call'
grep -F 'refinement-discarded|owner=function:mutable_until_call|binding=local:mutable_until_call:x|reason=call' \
    "$IR" >/dev/null || fail 'a mutable binding kept its refinement across a call'

# An immutable refinement is loop-invariant, so the backedge keeps it. The
# mutable counterpart is refused below.
grep -F 'narrowed-use|owner=function:invariant_across_loop|' "$IR" >/dev/null ||
    fail 'an invariant refinement did not survive the loop backedge'

# Refinements do not escape their function: every fact and use names the
# function that established it, and no row survives without one.
test "$(grep -c '^refinement|owner=function:' "$IR")" \
    -eq "$(grep -c '^refinement|' "$IR")" ||
    fail 'a refinement fact escaped its function'
test "$(grep -c '^narrowed-use|owner=function:' "$IR")" \
    -eq "$(grep -c '^narrowed-use|' "$IR")" ||
    fail 'a narrowed use escaped its function'

# Runtime representation stays deferred: narrowing is a frontend fact only.
! grep -Eq 'tag|niche|layout|discriminant|unwrap|unchecked' "$IR" ||
    fail 'narrowing implied a runtime representation'

# Each refusal names the rule it pins. The positive counterpart is listed
# beside it so a green gate cannot mean "narrowing never worked".
failures='
sibling_branch_leak:E2S136:not_null_name_first
non_terminating_guard:E2S136:guard
assignment_discards:E2S136:mutable_until_call
assignment_checked:E2S136:mutable_until_call
call_discards:E2S136:immutable_across_call
non_null_comparison:E2S136:not_null_name_first
property_path:E2S142:not_null_name_first
index_path:E2S142:not_null_name_first
alias_does_not_transfer:E2S136:not_null_name_first
loop_backedge:E2S136:invariant_across_loop
immutable_assignment:E2S143:mutable_until_call
unrecognized_null_comparison:E2S142:is_null_name_first
null_compared_to_concrete:E2S135:not_null_name_first
'

previous_ifs=$IFS
IFS='
'
for entry in $failures; do
    test -n "$entry" || continue
    stem=${entry%%:*}
    rest=${entry#*:}
    code=${rest%%:*}
    counterpart=${rest#*:}
    grep -F "owner=function:$counterpart|" "$IR" >/dev/null ||
        fail "$stem has no accepted counterpart '$counterpart' in the IR"
    set +e
    "$WORK/kofun-optional-frontend" "$CASES/$stem.kofun" \
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

# The refusal corpus is globbed rather than listed twice, so a fixture added
# without a gate entry stops the build (DD-022).
declared=$(printf '%s' "$failures" | grep -c ':')
present=$(find "$CASES" -name '*.stderr' -type f | wc -l | tr -d ' ')
test "$declared" -eq "$present" ||
    fail "gate lists $declared refusals but $present fixtures exist"

ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/kofun-optional-sanitize" "$CASES/positive.kofun" \
    "$WORK/sanitize.ir" "$WORK/sanitize.tokens" \
    >"$WORK/sanitize.stdout" 2>"$WORK/sanitize.stderr"
test ! -s "$WORK/sanitize.stdout" ||
    fail 'sanitized positive run wrote stdout'
test ! -s "$WORK/sanitize.stderr" ||
    fail 'ASan/UBSan reported a positive-path finding'
cmp "$CASES/positive.ir" "$WORK/sanitize.ir" ||
    fail 'sanitized narrowing IR differs'

IFS='
'
for entry in $failures; do
    test -n "$entry" || continue
    stem=${entry%%:*}
    set +e
    ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/kofun-optional-sanitize" "$CASES/$stem.kofun" \
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
done
IFS=$previous_ifs

test -z "$(find "$WORK" -type f \
    \( -name '*.generated.c' -o -name '*.o' -o -name '*.wasm' \
       -o -name '*.elf' -o -name '*.native' \) -print)" ||
    fail 'narrowing emitted a backend/runtime artifact'

printf '%s\n' \
    'PASS: both operand orders of != narrow the true edge, == the false edge' \
    'PASS: a definitely-returning guard carries the opposite edge past it' \
    'PASS: refinements are per-branch and merge by intersection at joins' \
    'PASS: assignment, mutable calls, and loop backedges discard refinements' \
    'PASS: unsupported shapes stay errors and declared types stay Optional(T)' \
    'PASS: typed-only boundaries, GCC analyzer, and ASan/UBSan remain clean'

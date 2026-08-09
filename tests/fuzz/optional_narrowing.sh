#!/usr/bin/env sh
set -eu

# Optional narrowing fuzz (#312).
#
# Generates small control-flow graphs over one Optional binding and checks the
# frontend against an independent shell model of the narrowing contract:
#
#   - `!=` refines the true edge, `==` the false edge, in either operand order;
#   - a definitely-returning guard carries the opposite edge past it;
#   - assignment always discards;
#   - a mutable binding loses its refinement to a call and across a loop
#     backedge, an immutable one keeps it;
#   - a use of `x` as `T` is accepted exactly where a refinement reaches it.
#
# The model is written from the contract rather than from the implementation,
# so a frontend that narrows too eagerly and a frontend that narrows too little
# both diverge from it. Every case is also checked for bounded, sound
# behaviour: exit status is always 0 or 1, output is deterministic, the
# sanitized build agrees byte for byte, and a rejected program emits no IR.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_OPTIONAL_NARROWING_FUZZ_WORK:-"$ROOT/build/optional-narrowing-fuzz"}
CASES=${KOFUN_OPTIONAL_NARROWING_FUZZ_CASES:-96}
CC=${CC:-cc}

fail() {
    printf '%s\n' "optional-narrowing fuzz: $*" >&2
    exit 1
}

case $CASES in
    ''|*[!0-9]*|0) fail 'case count must be positive' ;;
esac

rm -rf "$WORK"
mkdir -p "$WORK"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/optional_frontend.c" \
    -o "$WORK/kofun-optional-frontend"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/stage2/optional_frontend.c" \
    -o "$WORK/kofun-optional-sanitize"

# The default is the seed this corpus was recorded with, so `task verify`
# generates the same programs it always has. It is overridable so a lane
# that runs more than once can explore more than one input set; a fixed
# seed means accumulated machine time buys no coverage.
seed=${KOFUN_OPTIONAL_NARROWING_FUZZ_SEED:-1885172317}
case $seed in
    ''|*[!0-9]*)
        printf '%s\n' "optional_narrowing fuzz: KOFUN_OPTIONAL_NARROWING_FUZZ_SEED must be a non-negative integer" >&2
        exit 2
        ;;
esac
printf '%s\n' "optional_narrowing fuzz: seed=$seed"
next_random() {
    seed=$(((seed * 1103515245 + 12345) % 2147483648))
}

emit_payload() {
    # $1 indent, $2 mutation
    case $2 in
        assign) printf '%sx = null\n' "$1" ;;
        call) printf '%slet seen: Int = observe(x)\n' "$1" ;;
    esac
    printf '%slet total: Int = x + 1\n' "$1"
}

accepted_count=0
rejected_count=0
case_index=0
while test "$case_index" -lt "$CASES"; do
    next_random
    condition_index=$((seed % 4))
    next_random
    shape_index=$((seed % 3))
    next_random
    branch_index=$((seed % 2))
    next_random
    mutation_index=$((seed % 3))
    next_random
    mutability_index=$((seed % 2))

    case $condition_index in
        0) condition='x != null'; refined_true=1 ;;
        1) condition='null != x'; refined_true=1 ;;
        2) condition='x == null'; refined_true=0 ;;
        *) condition='null == x'; refined_true=0 ;;
    esac
    refined_false=$((1 - refined_true))
    test "$refined_true" -eq 1 && edge=true || edge=false

    case $shape_index in
        0) shape=branches ;;
        1) shape=guard ;;
        *) shape=loop ;;
    esac
    case $mutation_index in
        0) mutation=none ;;
        1) mutation=assign ;;
        *) mutation=call ;;
    esac
    case $mutability_index in
        0) declaration='let mut x: Int? = 1'; mutable=1 ;;
        *) declaration='let x: Int? = 1'; mutable=0 ;;
    esac
    test "$branch_index" -eq 0 && branch=then || branch=else

    # The model. `reaching` is whether a refinement reaches the use site.
    case $shape in
        branches)
            test "$branch" = then &&
                reaching=$refined_true || reaching=$refined_false
            ;;
        guard)
            # The `then` branch definitely returns, so the continuation
            # carries the false edge.
            reaching=$refined_false
            ;;
        *)
            # The loop body sits on the true edge, and the backedge discards a
            # mutable binding's refinement before the body is typed.
            test "$mutable" -eq 1 && reaching=0 || reaching=$refined_true
            ;;
    esac
    case $mutation in
        none) expected_status=$((1 - reaching)) ;;
        assign) expected_status=1 ;;
        *)
            # A call discards a mutable binding's refinement; an immutable one
            # cannot be reassigned or mutably aliased, so it keeps its own.
            test "$mutable" -eq 1 &&
                expected_status=1 || expected_status=$((1 - reaching))
            ;;
    esac

    case_work="$WORK/case-$case_index"
    mkdir -p "$case_work"
    source="$case_work/program.kofun"
    {
        printf '%s\n' 'fn observe(value: Int?) -> Int {'
        printf '%s\n' '    return 0'
        printf '%s\n' '}'
        printf '%s\n' ''
        printf '%s\n' 'fn probe(flag: Bool) -> Int {'
        printf '    %s\n' "$declaration"
        case $shape in
            branches)
                printf '    if %s {\n' "$condition"
                if test "$branch" = then; then
                    emit_payload '        ' "$mutation"
                else
                    printf '%s\n' '        let other: Int = 0'
                fi
                printf '%s\n' '    } else {'
                if test "$branch" = else; then
                    emit_payload '        ' "$mutation"
                else
                    printf '%s\n' '        let spare: Int = 0'
                fi
                printf '%s\n' '    }'
                ;;
            guard)
                printf '    if %s {\n' "$condition"
                printf '%s\n' '        return 0'
                printf '%s\n' '    }'
                emit_payload '    ' "$mutation"
                ;;
            *)
                printf '    if %s {\n' "$condition"
                printf '%s\n' '        while flag {'
                emit_payload '            ' "$mutation"
                printf '%s\n' '        }'
                printf '%s\n' '    }'
                ;;
        esac
        printf '%s\n' '    return 0'
        printf '%s\n' '}'
    } >"$source"

    describe="case $case_index [$condition | $shape | $branch | $mutation |"
    describe="$describe mutable=$mutable]"

    for run in first second; do
        set +e
        "$WORK/kofun-optional-frontend" "$source" \
            "$case_work/$run.ir" "$case_work/$run.tokens" \
            >"$case_work/$run.stdout" 2>"$case_work/$run.stderr"
        eval "status_$run=\$?"
        set -e
    done
    set +e
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/kofun-optional-sanitize" "$source" \
        "$case_work/sanitized.ir" "$case_work/sanitized.tokens" \
        >"$case_work/sanitized.stdout" 2>"$case_work/sanitized.stderr"
    status_sanitized=$?
    set -e

    test "$status_first" -eq "$status_second" ||
        fail "$describe: repeated runs exited $status_first and $status_second"
    test "$status_first" -eq "$status_sanitized" ||
        fail "$describe: sanitized run exited $status_sanitized"
    cmp "$case_work/first.stdout" "$case_work/second.stdout" ||
        fail "$describe: repeated diagnostics differ"
    cmp "$case_work/first.stdout" "$case_work/sanitized.stdout" ||
        fail "$describe: sanitized diagnostics differ"
    test ! -s "$case_work/first.stderr" ||
        fail "$describe: wrote internal stderr"
    test ! -s "$case_work/sanitized.stderr" ||
        fail "$describe: ASan/UBSan reported a finding"

    case $status_first in
        0|1) ;;
        *) fail "$describe: exited $status_first, which is neither 0 nor 1" ;;
    esac
    test "$status_first" -eq "$expected_status" ||
        fail "$describe: exited $status_first but the contract expects $expected_status"

    if test "$status_first" -eq 0; then
        cmp "$case_work/first.ir" "$case_work/second.ir" ||
            fail "$describe: repeated typed IR differs"
        cmp "$case_work/first.ir" "$case_work/sanitized.ir" ||
            fail "$describe: sanitized typed IR differs"
        # Exactly one recognized condition per program, so exactly one fact,
        # and its edge must follow the operator rather than the outcome.
        facts=$(grep -c '^refinement|' "$case_work/first.ir" || true)
        test "$facts" -eq 1 ||
            fail "$describe: recorded $facts refinement facts instead of 1"
        grep -F "|edge=$edge|" "$case_work/first.ir" >/dev/null ||
            fail "$describe: the refinement fact is not on the $edge edge"
        grep -F 'declared=Optional(builtin:Int)|narrowed=builtin:Int' \
            "$case_work/first.ir" >/dev/null ||
            fail "$describe: a refinement changed the declared type"
        ! grep -Eq 'tag|niche|layout|discriminant' "$case_work/first.ir" ||
            fail "$describe: implied a runtime representation"
        accepted_count=$((accepted_count + 1))
    else
        test ! -e "$case_work/first.ir" ||
            fail "$describe: rejected program emitted typed IR"
        test ! -e "$case_work/first.tokens" ||
            fail "$describe: rejected program emitted tokens"
        test -s "$case_work/first.stdout" ||
            fail "$describe: rejected without a diagnostic"
        reported=$(grep -c '^error\[' "$case_work/first.stdout" || true)
        total=$(wc -l <"$case_work/first.stdout" | tr -d ' ')
        test "$reported" -eq "$total" ||
            fail "$describe: emitted a line that is not a diagnostic"
        test "$reported" -le 32 ||
            fail "$describe: emitted $reported diagnostics, past the bound"
        rejected_count=$((rejected_count + 1))
    fi

    case_index=$((case_index + 1))
done

test "$accepted_count" -gt 0 ||
    fail 'no generated program was accepted; the corpus proves nothing'
test "$rejected_count" -gt 0 ||
    fail 'no generated program was rejected; the corpus proves nothing'

printf '%s\n' \
    "PASS: optional-narrowing fuzz agreed with the contract on $CASES CFGs" \
    "PASS: $accepted_count accepted and $rejected_count rejected, all bounded and deterministic"

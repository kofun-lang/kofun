#!/bin/sh
set -eu

# Iterative `while` over an indexed List[Int] (#1128).
#
# Before this slice, `while` was not a Stage 2 Core statement at all, so every
# iterative scan over an indexed sequence stopped at E2S10 — linear search,
# two-pointer walks, sliding windows, prefix sums, and binary search, which is
# the program the issue was filed about and the one most people write first.
#
# The lowering is `if` without the else, with one difference that this corpus
# exists to hold: the condition is emitted *inside* the loop. `emit_condition_into`
# returns a C prelude that computes into the target, so a condition hoisted
# above the `for` would be evaluated once and the loop would never end.
# `binary_search` and `pair_sum_exists` both terminate only because the
# condition is re-read, so a regression there hangs this gate rather than
# passing it quietly.

root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
fixtures="$root/tests/stage2/while-list-int"
work=${TMPDIR:-/tmp}/kofun-stage2-while-list-int.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"
ASSERT_CONTEXT='stage2 while over List[Int]'
. "$root/tests/assertions/assert.sh"

KOFUN="$root/bin/kofun"

# A wall clock, because the failure this slice can introduce is not a wrong
# answer but a loop that never returns one. Without a bound, a condition that
# stopped being re-evaluated would hang CI instead of failing it.
run_bounded() {
    stem=$1
    set +e
    timeout 60 "$KOFUN" run "$fixtures/$stem.kofun" \
        >"$work/$stem.stdout" 2>"$work/$stem.stderr"
    status=$?
    set -e
    if test "$status" -eq 124; then
        echo "while-list-int: $stem did not terminate within 60s;" \
            "the loop condition is no longer re-evaluated" >&2
        exit 1
    fi
}

# ------------------------------------------------------------------ accepted
for stem in binary_search scan; do
    run_bounded "$stem"
    assert_num "$stem exit status" "$status" -eq 0
    assert_file_empty "$stem stderr" "$work/$stem.stderr"
    cmp "$fixtures/$stem.stdout" "$work/$stem.stdout"
done

# The answers are pinned above; this states the one that motivated the issue in
# a form a reader can check without opening a golden.
# `-e`, because grep reads `-1` as an option otherwise and then waits on stdin
# — which hangs the gate instead of failing it.
assert_grep "binary search finds the first element" \
    -Fqx -e "0" "$work/binary_search.stdout"
assert_grep "binary search reports a miss as -1" \
    -Fqx -e "-1" "$work/binary_search.stdout"

# ------------------------------------------------------------------ refused
# A non-Bool condition is refused before any C is written, the same as `if`.
run_bounded text_condition
assert_num "text condition exit status" "$status" -eq 1
assert_file_empty "text condition stdout" "$work/text_condition.stdout"
cmp "$fixtures/text_condition.stderr" "$work/text_condition.stderr"

# A loop that walks one step past the end traps on the bounds check, and the
# trap ends the loop instead of spinning inside it.
run_bounded out_of_range
assert_num "out of range exit status" "$status" -eq 1
cmp "$fixtures/out_of_range.stderr" "$work/out_of_range.stderr"

# `for ... in` is still outside Core, which is what
# bootstrap/stage2/unsupported_core.kofun now holds; this only states that
# admitting `while` did not admit every loop form with it.
cat >"$work/for_in.kofun" <<'FIXTURE'
fn main() -> Int {
    for value in [1, 2] {
        return value
    }
    return 1
}
FIXTURE
set +e
timeout 60 "$KOFUN" run "$work/for_in.kofun" \
    >"$work/for_in.stdout" 2>"$work/for_in.stderr"
for_in_status=$?
set -e
# 3, not 1: `kofun run` separates a refused compile from a program
# that ran and returned nonzero.
assert_num "for-in exit status" "$for_in_status" -eq 3
assert_grep "for-in stays outside Core" \
    -Fq "error[E2S10]" "$work/for_in.stderr"

printf '%s\n' \
    "PASS: iterative while over an indexed List[Int] executes, terminates, and refuses a non-Bool condition"

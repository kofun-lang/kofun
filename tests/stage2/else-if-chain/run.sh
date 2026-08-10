#!/bin/sh
set -eu

# Statement-position `else if` chains (#1174).
#
# Before this slice the lowering required `{` immediately after `else`, so a
# second `if` there was `E2S18` rather than a chain, and every multi-way
# branch had to be hand-nested — including the binary search shipped as
# `examples/coding_interview.kofun`.
#
# The chain is emitted iteratively: each link goes inside the previous link's
# `else`. That structure is not a style choice, it is what makes
# `spec/semantics.md`'s rule true —
#
#   "A branch that is not taken evaluates neither its body nor a later
#    `else if` condition."
#
# and it is the one property here that a reader cannot confirm by looking at
# the output of a working program. So it is gated by consequence rather than
# by inspection: the pair below puts a *trapping* index in a later condition
# and requires the trap to happen in exactly one of the two runs.

root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
fixtures="$root/tests/stage2/else-if-chain"
work=${TMPDIR:-/tmp}/kofun-stage2-else-if-chain.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"
ASSERT_CONTEXT='stage2 else-if chains'
. "$root/tests/assertions/assert.sh"

KOFUN="$root/bin/kofun"

run_case() {
    stem=$1
    set +e
    timeout 120 "$KOFUN" run "$fixtures/$stem.kofun" \
        >"$work/$stem.stdout" 2>"$work/$stem.stderr"
    status=$?
    set -e
    test "$status" -ne 124 ||
        fail "$stem did not terminate within 120s"
}

# ------------------------------------------------------------------ accepted
# A ladder with a trailing else, a chain without one, links that return with
# the chain not final, and a chain nested inside a loop.
run_case chain
assert_num "chain exit status" "$status" -eq 0
assert_file_empty "chain stderr" "$work/chain.stderr"
cmp "$fixtures/chain.stdout" "$work/chain.stdout"

# Stated here as well as pinned, so a reader can check the ladder without
# opening the golden: five scores descend through every link.
assert_grep "the grading ladder reaches its last link" \
    -Fqx -e "0" "$work/chain.stdout"
assert_grep "a chain with no trailing else falls through" \
    -Fqx -e "-1" "$work/chain.stdout"

# ------------------------------------------------- the short-circuit rule
# Same program twice, differing only in which branch is taken. The later
# condition indexes far outside a three-element list.
#
# First branch taken: the trapping condition must never be evaluated.
run_case short_circuit_taken
assert_num "short-circuit taken exit status" "$status" -eq 0
assert_file_empty "short-circuit taken stderr" "$work/short_circuit_taken.stderr"
cmp "$fixtures/short_circuit_taken.stdout" "$work/short_circuit_taken.stdout"

# First branch not taken: the same condition must now be evaluated, and trap.
# Without this half, a lowering that never evaluated later conditions at all
# would pass the half above.
run_case short_circuit_reached
assert_num "short-circuit reached exit status" "$status" -eq 1
assert_file_empty "short-circuit reached stdout" "$work/short_circuit_reached.stdout"
cmp "$fixtures/short_circuit_reached.stderr" "$work/short_circuit_reached.stderr"

# `else` with no `if` and no block stays a refusal; the chain admitted one
# specific token after `else`, not anything.
cat >"$work/bare_else.kofun" <<'FIXTURE'
fn main() -> Int {
    if false {
        print(1)
    } else print(2)
    return 0
}
FIXTURE
set +e
timeout 120 "$KOFUN" run "$work/bare_else.kofun" \
    >"$work/bare_else.stdout" 2>"$work/bare_else.stderr"
bare_else_status=$?
set -e
# 1, not the 3 an unsupported *statement* gets: this is a structural parse
# refusal, a different category.
assert_num "bare else exit status" "$bare_else_status" -eq 1
assert_grep 'an else with neither if nor a block is refused' \
    -Fq "error[E2S18]" "$work/bare_else.stderr"

printf '%s\n' \
    "PASS: else-if chains lower, and a later condition runs only when every earlier one was false"

#!/bin/sh
set -eu

# Move-assertion gate for #572.
#
# Three things are checked, in this order:
#
#   1. the design text and the diagnostic registry still carry the unstable
#      assertion: docs/MEMORY_MODEL.md states the take-versus-optimization
#      distinction, and E2S146 stays a registered Stage 2 identity;
#   2. provable last uses compile and run identically on the reference
#      executor and the C11 backend, and the assertion is erased: the
#      emitted C of a program with the assertion and its pair without it
#      are byte-identical;
#   3. every implemented failure reason rejects with its exact explained
#      diagnostic — later use, possible alias, branch mismatch, escaping
#      capture, and backend limitation. `unknown foreign call` is reserved;
#      this slice cannot express a foreign call, and README.md records that.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CASES="$ROOT/tests/move-assertion"
ASSERT_CONTEXT="move assertion"
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-move-assertion.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'move assertion: FAIL: %s\n' "$*" >&2
    exit 1
}

require_line() {
    file=$1
    needle=$2
    label=$3
    assert_grep "$label" -Fq -- "$needle" "$file"
}

# ------------------------------------------------------- corpus hygiene

find "$CASES" -type f \( -name '*.py' -o -name '*.kf' \) >"$WORK/forbidden"
assert_file_empty 'forbidden Python or .kf source in the corpus' \
    "$WORK/forbidden"

# ------------------------------------------- design text and registry pin

memory_model="$ROOT/docs/MEMORY_MODEL.md"
assert_regular_file 'memory model design text' "$memory_model"
for declaration in \
    '## 14. Semantic `take` versus optimization-only moves' \
    '**Semantic `take` is observable.**' \
    '**Managed-value moves are optimization only.**' \
    '### The unstable assertion: `compiler.ensure_move(value)`' \
    '**Everything in this subsection is unstable.**' \
    '`unknown foreign call` is reserved'
do
    require_line "$memory_model" "$declaration" \
        'the memory model lost the take-versus-optimization distinction'
done

registry="$ROOT/tests/diagnostics/registry.tsv"
require_line "$registry" 'E2S146	move-assertion	frontend' \
    'E2S146 is no longer a registered Stage 2 diagnostic identity'
require_line "$ROOT/tests/diagnostics/reports/stage2.tsv" 'E2S146	stage2' \
    'E2S146 lost its Stage 2 adapter report row'

# --------------------------------------------------- provable last uses

for stem in last_use scoped_last_use terminal_both_arms \
    terminal_arm_quiet_sibling
do
    source="$CASES/$stem.kofun"
    expected="$CASES/$stem.stdout"
    assert_regular_file "positive source $stem" "$source"
    assert_regular_file "positive golden $stem" "$expected"

    "$ROOT/bin/kofun" check "$source" \
        >"$WORK/$stem.check.stdout" 2>"$WORK/$stem.check.stderr" ||
        fail "$stem did not check: $(cat "$WORK/$stem.check.stderr")"
    require_line "$WORK/$stem.check.stdout" "ok: $source" \
        "$stem checked with a qualified ok"

    "$ROOT/bin/kofun" build "$source" -o "$WORK/$stem" \
        --emit-c "$WORK/$stem.c" \
        >"$WORK/$stem.build.stdout" 2>"$WORK/$stem.build.stderr" ||
        fail "$stem did not build: $(cat "$WORK/$stem.build.stderr")"
    "$WORK/$stem" >"$WORK/$stem.backend.stdout"
    cmp "$expected" "$WORK/$stem.backend.stdout" ||
        fail "$stem: C11 backend output differs from the golden"

    "$ROOT/bin/kofun" run "$source" \
        >"$WORK/$stem.reference.stdout" 2>"$WORK/$stem.run.stderr" ||
        fail "$stem did not run on the reference executor"
    cmp "$expected" "$WORK/$stem.reference.stdout" ||
        fail "$stem: reference executor and C11 backend disagree"

    "$WORK/$stem" >"$WORK/$stem.backend.second"
    cmp "$WORK/$stem.backend.stdout" "$WORK/$stem.backend.second" ||
        fail "$stem is not reproducible across runs"
done

# ------------------------------------------------------- zero footprint
#
# The pair must differ by exactly the assertion line, produce the same
# stdout on both executors, and lower to byte-identical C. Byte-identical
# is the strongest erasure evidence this gate can state: no counter, no
# helper, no reordering — nothing.

# Every accepted shape owes this evidence, not just the straight-line one:
# #904 admits a second acceptance path, so the terminal-arm pair is checked
# the same way, and #915's loop-local last use is a third.
#
# The loop pair is the one that could not exist before: `while` did not lower
# until #1128, so no positive loop case could execute and the rule that a
# loop-local binding is a genuine last use could only be argued. It is the
# counterpart to loop_repeat.kofun, which stays rejected because its binding
# lives outside the loop.
for pair in zero_footprint zero_footprint_terminal zero_footprint_loop; do
    with="$CASES/${pair}_with.kofun"
    without="$CASES/${pair}_without.kofun"
    expected="$CASES/$pair.stdout"
    assert_regular_file "$pair with-assertion source" "$with"
    assert_regular_file "$pair without-assertion source" "$without"
    assert_regular_file "$pair golden" "$expected"

    grep -v 'compiler\.ensure_move' "$with" >"$WORK/$pair.stripped"
    cmp "$WORK/$pair.stripped" "$without" ||
        fail "the $pair pair differ by more than the assertion line"
    grep -c 'compiler\.ensure_move' "$with" >"$WORK/$pair.count" || true
    assert_eq "exactly one assertion line in $pair with-version" \
        "$(cat "$WORK/$pair.count")" '1'

    for variant in with without; do
        eval "source=\$$variant"
        "$ROOT/bin/kofun" build "$source" -o "$WORK/${pair}_$variant" \
            --emit-c "$WORK/${pair}_$variant.c" \
            >"$WORK/${pair}_$variant.build.stdout" \
            2>"$WORK/${pair}_$variant.build.stderr" ||
            fail "$pair $variant did not build"
        "$WORK/${pair}_$variant" >"$WORK/${pair}_$variant.stdout"
        cmp "$expected" "$WORK/${pair}_$variant.stdout" ||
            fail "$pair $variant: backend output differs from the golden"
        "$ROOT/bin/kofun" run "$source" >"$WORK/${pair}_$variant.reference" \
            2>"$WORK/${pair}_$variant.run.stderr" ||
            fail "$pair $variant did not run on the reference executor"
        cmp "$expected" "$WORK/${pair}_$variant.reference" ||
            fail "$pair $variant: executors disagree"
    done

    cmp "$WORK/${pair}_with.c" "$WORK/${pair}_without.c" ||
        fail "$pair: the assertion left a trace: emitted C is not identical"
    assert_not_grep "$pair: the emitted C names the assertion" -qE -- \
        'ensure_move|compiler' "$WORK/${pair}_with.c"
done

# -------------------------------------------------- explained rejections
#
# Each block pins the exact public diagnostic and, separately, the reason
# vocabulary word #572 requires, so a wording change that loses the reason
# fails by name rather than by golden drift.

expect_rejected() {
    stem=$1
    reason=$2
    diagnostic=$3
    source="$CASES/$stem.kofun"
    assert_regular_file "negative source $stem" "$source"
    set +e
    "$ROOT/bin/kofun" check "$source" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    status=$?
    set -e
    assert_num "$stem refusal exit status" "$status" -eq 1
    require_line "$WORK/$stem.stderr" "$diagnostic" \
        "$stem was rejected with the wrong diagnostic"
    require_line "$WORK/$stem.stderr" "($reason)" \
        "$stem lost its explained reason"
    printf 'move assertion: rejected as designed: %s (%s)\n' "$stem" "$reason"
}

expect_rejected later_use 'later use' \
    'error[E2S146]: unstable `compiler.ensure_move`: `banner` is used again at byte 217 (later use) at byte 199'
expect_rejected possible_alias 'possible alias' \
    'error[E2S146]: unstable `compiler.ensure_move`: the read of `banner` at byte 296 may create an alias (possible alias) at byte 328'
expect_rejected branch_mismatch 'branch mismatch' \
    'error[E2S146]: unstable `compiler.ensure_move`: the assertion is inside a conditional arm that `banner` outlives (branch mismatch) at byte 346'
expect_rejected arm_fallthrough 'branch mismatch' \
    'error[E2S146]: unstable `compiler.ensure_move`: the assertion is inside a conditional arm that `banner` outlives (branch mismatch) at byte 401'
expect_rejected sibling_arm_later_use 'later use' \
    'error[E2S146]: unstable `compiler.ensure_move`: `banner` is used again at byte 405 (later use) at byte 353'
expect_rejected arm_nested_loop 'branch mismatch' \
    'error[E2S146]: unstable `compiler.ensure_move`: the assertion is inside a conditional arm that `banner` outlives (branch mismatch) at byte 410'
expect_rejected escaping_capture 'escaping capture' \
    'error[E2S146]: unstable `compiler.ensure_move`: `banner` is captured by a lambda at byte 263 (escaping capture) at byte 304'
expect_rejected borrowed_parameter 'possible alias' \
    'error[E2S146]: unstable `compiler.ensure_move`: parameter `label` is borrowed from the caller (possible alias) at byte 334'
expect_rejected copy_value 'backend limitation' \
    'error[E2S146]: unstable `compiler.ensure_move`: `answer` has Copy type `Int`, not managed storage (backend limitation) at byte 227'
expect_rejected loop_repeat 'later use' \
    'error[E2S146]: unstable `compiler.ensure_move`: an enclosing loop or block can repeat this read of `banner` (later use) at byte 285'
expect_rejected no_storage_identity 'backend limitation' \
    'error[E2S146]: unstable `compiler.ensure_move`: `width` names no local storage identity (backend limitation) at byte 320'

# The two usage errors carry no proof-failure reason; they pin the
# compile-time-only contract instead.
for pair in \
    'no_value|error[E2S146]: unstable `compiler.ensure_move` is compile-time only and has no value here at byte 212' \
    'malformed_argument|error[E2S146]: unstable `compiler.ensure_move` takes exactly one local binding or parameter name at byte 227'
do
    stem=${pair%%|*}
    diagnostic=${pair#*|}
    source="$CASES/$stem.kofun"
    assert_regular_file "negative source $stem" "$source"
    set +e
    "$ROOT/bin/kofun" check "$source" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    status=$?
    set -e
    assert_num "$stem refusal exit status" "$status" -eq 1
    require_line "$WORK/$stem.stderr" "$diagnostic" \
        "$stem was rejected with the wrong diagnostic"
    printf 'move assertion: rejected as designed: %s\n' "$stem"
done

printf 'take stays semantic; managed moves stay optimization-only: PASS\n'
printf 'provable last uses compile and run identically on both executors: PASS\n'
printf 'assertion erased: emitted C byte-identical with and without it: PASS\n'
printf 'every implemented failure reason rejects with its explanation: PASS\n'

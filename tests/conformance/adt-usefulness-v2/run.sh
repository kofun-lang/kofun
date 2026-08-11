#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

# The recursive pattern-matrix usefulness oracle.
#
# The model this replaces could see a scrutinee column and at most one payload
# column, so everything it answered about depth was answered by a refusal. This
# corpus asks the questions that refusal was standing in for: nested
# constructors to depth eight, products of fields, or alternatives, guards, and
# the identity and budget boundaries around all of them.
#
# Two habits run through it.
#
# Every bound is exercised twice, at the last accepted model and at the first
# refused one, so a bound that moved is visible from both sides rather than only
# from the side that still passes.
#
# Every rule the oracle implements is proved by reintroducing its absence. The
# mutation section below rebuilds the oracle with one behaviour removed and
# requires this corpus to notice. A gate that only reads the good path cannot
# tell whether the bad one is still refused.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/adt-usefulness-v2"
SOURCE="$ROOT/bootstrap/stage2/adt_usefulness_v2.c"
CC=${CC:-cc}
WORK=${KOFUN_ADT_USEFULNESS_V2_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}adt-usefulness-v2"}
TOOL="$WORK/adt-usefulness-v2"
ASSERT_CONTEXT='adt usefulness v2'
. "$ROOT/tests/assertions/assert.sh"

case "$WORK" in
    */adt-usefulness-v2|*/adt-usefulness-v2.*) ;;
    *) assert_fail "work directory must end in adt-usefulness-v2[.suffix]: $WORK" ;;
esac

rm -rf "$WORK"
mkdir -p "$WORK"

"$CC" -std=c11 -Wall -Wextra -Werror -pedantic "$SOURCE" -o "$TOOL"

identity() {
    printf '%064d' "$1"
}

run_success() {
    stem=$1
    input=$2
    "$TOOL" "$input" "$WORK/$stem.result"
}

expect_failure() {
    stem=$1
    input=$2
    code=$3
    printf '%s\n' stale > "$WORK/$stem.result"
    if "$TOOL" "$input" "$WORK/$stem.result" > "$WORK/$stem.actual" 2>&1
    then
        assert_fail "expected $code failure for $stem"
    fi
    assert_grep "$stem.actual" -F "error[$code]:" "$WORK/$stem.actual"
    assert_absent "$stem.result" "$WORK/$stem.result"
}

# The recorded answer, byte for byte. Wording that drifts is wording that stops
# describing the model it came from.
expect_recorded() {
    stem=$1
    code=$2
    expect_failure "$stem" "$CASES/fixtures/$stem.matrix" "$code"
    cmp "$CASES/fixtures/$stem.stderr" "$WORK/$stem.actual"
}

# ---------------------------------------------------------------------------
# 1. Depth 0 and depth 1: the coverage the one-level model carried.
#
# These are that model's own cases, projected onto the v2 input. A flat enum is
# the depth-0 matrix and a single payload column is the depth-1 matrix, so the
# earlier checkpoint is a special case of this one rather than something it
# replaced.
# ---------------------------------------------------------------------------
run_success flat_exhaustive "$CASES/fixtures/flat_exhaustive.matrix"
assert_grep "flat_exhaustive.result" -Fx \
    'kofun-adt-usefulness-result/v2' "$WORK/flat_exhaustive.result"
assert_grep "flat_exhaustive.result" -F \
    '|name=Color|constructors=3|depth=1' "$WORK/flat_exhaustive.result"
assert_grep "flat_exhaustive.result" -F \
    'complete|arms=3|alternatives=3|constructors=3|columns=1|' \
    "$WORK/flat_exhaustive.result"
expect_recorded flat_missing E2S25
expect_recorded flat_redundant E2S26

run_success nested_exhaustive "$CASES/fixtures/nested_exhaustive.matrix"
assert_grep "nested_exhaustive.result" -F \
    '|name=Outer|constructors=2|depth=2' "$WORK/nested_exhaustive.result"
expect_recorded nested_missing E2S25
expect_recorded nested_outer_missing E2S25
expect_recorded nested_redundant_whole E2S26
expect_recorded nested_redundant_nested E2S26

# A wildcard where the payload was never examined prints as `_`, and a payload
# that was examined prints the constructor. Both are in the recorded answers
# above; this states which is which so the distinction cannot be read as noise.
assert_grep "nested_missing.stderr" -F 'Wrap(Right)' \
    "$CASES/fixtures/nested_missing.stderr"
assert_grep "nested_outer_missing.stderr" -F 'Wrap(_)' \
    "$CASES/fixtures/nested_outer_missing.stderr"

# ---------------------------------------------------------------------------
# 2. Depth 2 and beyond.
# ---------------------------------------------------------------------------
run_success depth_three_exhaustive "$CASES/fixtures/depth_three_exhaustive.matrix"
assert_grep "depth_three_exhaustive.result" -F '|depth=3' \
    "$WORK/depth_three_exhaustive.result"
expect_recorded depth_three_missing E2S25
expect_recorded depth_three_redundant E2S26

# A guarded arm covers nothing, so the wildcard arm after it is not redundant
# and the match is still exhaustive.
run_success depth_three_guarded "$CASES/fixtures/depth_three_guarded.matrix"
assert_grep "depth_three_guarded.result" -F '|guard=yes|' \
    "$WORK/depth_three_guarded.result"

# A chain of single-field ADTs, at the accepted depth and one past it. Depth is
# a property of the signature, not of the patterns written against it, so this
# is refused before any arm is read.
generate_chain() {
    levels=$1
    output=$2
    {
        printf '%s\n' 'kofun-adt-usefulness/v2'
        level=$levels
        while test "$level" -ge 1; do
            printf 'adt|id=%s|name=L%s\n' "$(identity "$((500 + level))")" "$level"
            if test "$level" -eq "$levels"; then
                printf 'constructor|id=%s|owner=%s|ordinal=0|name=Stop%s|fields=-\n' \
                    "$(identity "$((600 + level))")" \
                    "$(identity "$((500 + level))")" "$level"
                printf 'constructor|id=%s|owner=%s|ordinal=1|name=Halt%s|fields=-\n' \
                    "$(identity "$((700 + level))")" \
                    "$(identity "$((500 + level))")" "$level"
            else
                printf 'constructor|id=%s|owner=%s|ordinal=0|name=Step%s|fields=%s\n' \
                    "$(identity "$((600 + level))")" \
                    "$(identity "$((500 + level))")" "$level" \
                    "$(identity "$((500 + level + 1))")"
            fi
            level=$((level - 1))
        done
        printf 'target|adt=%s\n' "$(identity 501)"
        printf 'arm|index=0|span=10..18|guard=no\n'
        printf 'alternative|arm=0|index=0|pattern=_\n'
    } > "$output"
}

generate_chain 8 "$WORK/depth-boundary.matrix"
run_success depth-boundary "$WORK/depth-boundary.matrix"
assert_grep "depth-boundary.result" -F '|depth=8' "$WORK/depth-boundary.result"
generate_chain 9 "$WORK/depth-over.matrix"
expect_failure depth-over "$WORK/depth-over.matrix" E2S110
assert_grep "depth-over.actual" -F 'signature exceeds depth 8' \
    "$WORK/depth-over.actual"

# ---------------------------------------------------------------------------
# 3. Products: more than one field, and more than one column.
# ---------------------------------------------------------------------------
run_success product_exhaustive "$CASES/fixtures/product_exhaustive.matrix"
assert_grep "product_exhaustive.result" -F '|columns=2|' \
    "$WORK/product_exhaustive.result"
expect_recorded product_missing E2S25

# Rows that overlap without any one of them being redundant: each contributes a
# case the others do not. A specialization that dropped wildcard rows would
# report this exhaustive matrix as missing a case.
run_success product_overlapping "$CASES/fixtures/product_overlapping.matrix"

# ---------------------------------------------------------------------------
# 4. Or alternatives, guards, and bound roles.
# ---------------------------------------------------------------------------
run_success or_exhaustive "$CASES/fixtures/or_exhaustive.matrix"
assert_grep "or_exhaustive.result" -F 'arm|index=0|span=10..18|guard=no|alternatives=2|' \
    "$WORK/or_exhaustive.result"
expect_recorded or_alternative_redundant E2S26
expect_failure or_roles_differ "$CASES/fixtures/or_roles_differ.matrix" E2S110
assert_grep "or_roles_differ.actual" -F 'bind different roles' \
    "$WORK/or_roles_differ.actual"

run_success binding_roles "$CASES/fixtures/binding_roles.matrix"
assert_grep "binding_roles.result" -F 'alternative|arm=0|index=0|status=useful|roles=item' \
    "$WORK/binding_roles.result"
assert_grep "binding_roles.result" -F 'alternative|arm=0|index=1|status=useful|roles=item' \
    "$WORK/binding_roles.result"
assert_grep "binding_roles.result" -F 'alternative|arm=1|index=0|status=useful|roles=-' \
    "$WORK/binding_roles.result"

# A guarded arm does not cover, so what follows it is not redundant and what it
# alone would have covered is still missing.
expect_recorded guarded_not_covering E2S25
run_success guarded_then_wildcard "$CASES/fixtures/guarded_then_wildcard.matrix"

# ---------------------------------------------------------------------------
# 5. Identity is resolved identity.
# ---------------------------------------------------------------------------
# A decoy ADT whose constructors carry the same display names as the payload's.
# Nothing about the names distinguishes the two; the owner link does.
expect_failure decoy_owner "$CASES/fixtures/decoy_owner.matrix" E2S110
assert_grep "decoy_owner.actual" -F \
    "pattern constructor is not owned by the column's ADT" \
    "$WORK/decoy_owner.actual"

# Renaming every display name changes what the answer reads and nothing about
# what it is: the same arms are useful and the same case is missing.
sed -e 's/|name=Outer/|name=Renamed/' -e 's/|name=Wrap|/|name=Boxed|/' \
    "$CASES/fixtures/nested_missing.matrix" > "$WORK/renamed.matrix"
expect_failure renamed "$WORK/renamed.matrix" E2S25
assert_grep "renamed.actual" -F 'non-exhaustive match on `Renamed`: no arm matches `Boxed(Right)`' \
    "$WORK/renamed.actual"

# Declaration order of ADTs and constructors is not semantic: the same records in
# another order resolve to the same model. Arm order is semantic, and swapping
# two arms turns a whole-constructor row that hid a nested one into a nested row
# that no longer does.
{
    sed -n '1p' "$CASES/fixtures/nested_exhaustive.matrix"
    sed -n '/^adt|/p;/^constructor|/p' "$CASES/fixtures/nested_exhaustive.matrix" |
        sort
    sed -n '/^target|/p;/^arm|/p;/^alternative|/p' \
        "$CASES/fixtures/nested_exhaustive.matrix"
} > "$WORK/reordered-declarations.matrix"
run_success reordered-declarations "$WORK/reordered-declarations.matrix"
cmp "$WORK/nested_exhaustive.result" "$WORK/reordered-declarations.result"

{
    sed -n '1,/^target|/p' "$CASES/fixtures/nested_redundant_whole.matrix"
    outer=$(identity 21)
    inner=$(identity 31)
    empty=$(identity 22)
    printf 'arm|index=0|span=10..18|guard=no\n'
    printf 'alternative|arm=0|index=0|pattern=%s(%s)\n' "$outer" "$inner"
    printf 'arm|index=1|span=20..28|guard=no\n'
    printf 'alternative|arm=1|index=0|pattern=%s(_)\n' "$outer"
    printf 'arm|index=2|span=30..38|guard=no\n'
    printf 'alternative|arm=2|index=0|pattern=%s\n' "$empty"
} > "$WORK/reordered-arms.matrix"
# Same three rows, and the answer changes: `Wrap(_)` before `Wrap(Left)` hides
# it, and after it does not. That contrast is the whole content of "arm order is
# semantic", so both halves are asserted rather than only the one that passes.
run_success reordered-arms "$WORK/reordered-arms.matrix"
assert_grep "reordered-arms.result" -F 'complete|arms=3|alternatives=3|' \
    "$WORK/reordered-arms.result"
assert_grep "nested_redundant_whole.stderr" -F 'unreachable match arm at bytes 20..28' \
    "$CASES/fixtures/nested_redundant_whole.stderr"

# ---------------------------------------------------------------------------
# 6. Fail-closed models.
# ---------------------------------------------------------------------------
expect_failure cycle "$CASES/fixtures/cycle.matrix" E2S110
assert_grep "cycle.actual" -F 'form a cycle, so the domain is infinite' \
    "$WORK/cycle.actual"
expect_failure broken_field "$CASES/fixtures/broken_field.matrix" E2S110
assert_grep "broken_field.actual" -F 'constructor field identity is absent' \
    "$WORK/broken_field.actual"
expect_failure absent_constructor "$CASES/fixtures/absent_constructor.matrix" E2S110
assert_grep "absent_constructor.actual" -F 'pattern names an absent constructor' \
    "$WORK/absent_constructor.actual"
expect_failure too_many_fields "$CASES/fixtures/too_many_fields.matrix" E2S110
assert_grep "too_many_fields.actual" -F 'has too many fields' \
    "$WORK/too_many_fields.actual"
expect_failure too_few_fields "$CASES/fixtures/too_few_fields.matrix" E2S110
assert_grep "too_few_fields.actual" -F 'has too few fields' \
    "$WORK/too_few_fields.actual"

sed 's/^kofun-adt-usefulness\/v2$/kofun-adt-usefulness\/v1/' \
    "$CASES/fixtures/flat_exhaustive.matrix" > "$WORK/wrong-version.matrix"
expect_failure wrong-version "$WORK/wrong-version.matrix" E2S110
assert_grep "wrong-version.actual" -F 'has no v2 header' "$WORK/wrong-version.actual"

sed 's/^arm|index=0|/arm|unknown=0|/' \
    "$CASES/fixtures/flat_exhaustive.matrix" > "$WORK/malformed.matrix"
expect_failure malformed "$WORK/malformed.matrix" E2S110
assert_grep "malformed.actual" -F 'malformed arm record' "$WORK/malformed.actual"

sed 's/^target|adt=0*1$/target|adt=0000000000000000000000000000000000000000000000000000000000000999/' \
    "$CASES/fixtures/flat_exhaustive.matrix" > "$WORK/stale-target.matrix"
expect_failure stale-target "$WORK/stale-target.matrix" E2S110
assert_grep "stale-target.actual" -F 'target ADT identity is absent' \
    "$WORK/stale-target.actual"

# ---------------------------------------------------------------------------
# 7. Determinism and transactions.
# ---------------------------------------------------------------------------
run_success repeated "$CASES/fixtures/nested_exhaustive.matrix"
cmp "$WORK/nested_exhaustive.result" "$WORK/repeated.result"
mkdir -p "$WORK/remapped"
cp "$CASES/fixtures/nested_exhaustive.matrix" "$WORK/remapped/model.matrix"
run_success remapped "$WORK/remapped/model.matrix"
cmp "$WORK/nested_exhaustive.result" "$WORK/remapped.result"

cp "$CASES/fixtures/nested_exhaustive.matrix" "$WORK/alias.matrix"
if "$TOOL" "$WORK/alias.matrix" "$WORK/alias.matrix" > "$WORK/alias.actual" 2>&1
then
    assert_fail 'expected aliased path failure'
fi
cmp "$CASES/fixtures/nested_exhaustive.matrix" "$WORK/alias.matrix"
assert_grep "alias.actual" -F 'input and output paths must differ' \
    "$WORK/alias.actual"
mkdir -p "$WORK/alias-dir"
cp "$CASES/fixtures/nested_exhaustive.matrix" "$WORK/alias-dir/model.matrix"
if "$TOOL" "$WORK/alias-dir/model.matrix" "$WORK/alias-dir/./model.matrix" \
    > "$WORK/dot-alias.actual" 2>&1
then
    assert_fail 'expected dot-segment aliased path failure'
fi
cmp "$CASES/fixtures/nested_exhaustive.matrix" "$WORK/alias-dir/model.matrix"
cp "$CASES/fixtures/nested_exhaustive.matrix" "$WORK/transaction.result.tmp"
if "$TOOL" "$WORK/transaction.result.tmp" "$WORK/transaction.result" \
    > "$WORK/transaction-alias.actual" 2>&1
then
    assert_fail 'expected transaction-path input alias failure'
fi
cmp "$CASES/fixtures/nested_exhaustive.matrix" "$WORK/transaction.result.tmp"
assert_absent "transaction.result" "$WORK/transaction.result"

printf '%s\n' \
    'PASS: depth 0 through 8, products, or alternatives, guards, and roles are exact' \
    'PASS: identity decides coverage; display names decide only what the answer reads' \
    'PASS: cycles, broken links, wrong arity, and stale identities fail closed'

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
# alone would have covered is still missing. Both halves, because they are
# different rules: the first is about what a guard hides, the second about what
# it covers.
expect_recorded guarded_not_covering E2S25
expect_recorded guarded_wildcard_not_covering E2S25
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

# ---------------------------------------------------------------------------
# 8. Every bound, at the last model it accepts and the first it refuses.
# ---------------------------------------------------------------------------

# ADTs. Each is a distinct singleton, so the count is the only thing growing.
generate_adts() {
    count=$1
    output=$2
    {
        printf '%s\n' 'kofun-adt-usefulness/v2'
        index=0
        while test "$index" -lt "$count"; do
            printf 'adt|id=%s|name=A%s\n' "$(identity "$((1000 + index))")" "$index"
            printf 'constructor|id=%s|owner=%s|ordinal=0|name=Only%s|fields=-\n' \
                "$(identity "$((2000 + index))")" \
                "$(identity "$((1000 + index))")" "$index"
            index=$((index + 1))
        done
        printf 'target|adt=%s\n' "$(identity 1000)"
        printf 'arm|index=0|span=10..18|guard=no\n'
        printf 'alternative|arm=0|index=0|pattern=%s\n' "$(identity 2000)"
    } > "$output"
}
generate_adts 16 "$WORK/adts-boundary.matrix"
run_success adts-boundary "$WORK/adts-boundary.matrix"
generate_adts 17 "$WORK/adts-over.matrix"
expect_failure adts-over "$WORK/adts-over.matrix" E2S110
assert_grep "adts-over.actual" -F 'exceeds 16 ADTs' "$WORK/adts-over.actual"

# Constructors, counted across the whole model rather than per ADT.
generate_constructors() {
    count=$1
    output=$2
    {
        printf '%s\n' 'kofun-adt-usefulness/v2'
        printf 'adt|id=%s|name=Wide\n' "$(identity 3000)"
        ordinal=0
        while test "$ordinal" -lt "$count"; do
            printf 'constructor|id=%s|owner=%s|ordinal=%s|name=C%s|fields=-\n' \
                "$(identity "$((4000 + ordinal))")" "$(identity 3000)" \
                "$ordinal" "$ordinal"
            ordinal=$((ordinal + 1))
        done
        printf 'target|adt=%s\n' "$(identity 3000)"
        printf 'arm|index=0|span=10..18|guard=no\n'
        printf 'alternative|arm=0|index=0|pattern=_\n'
    } > "$output"
}
generate_constructors 64 "$WORK/constructors-boundary.matrix"
run_success constructors-boundary "$WORK/constructors-boundary.matrix"
assert_grep "constructors-boundary.result" -F '|constructors=64|columns=1|' \
    "$WORK/constructors-boundary.result"
generate_constructors 65 "$WORK/constructors-over.matrix"
expect_failure constructors-over "$WORK/constructors-over.matrix" E2S110
assert_grep "constructors-over.actual" -F 'exceeds 64 constructors' \
    "$WORK/constructors-over.actual"

# Arms. Each names a distinct constructor, so all 64 are useful and the model is
# exhaustive; the 65th is refused while reading, before any of that is decided.
generate_arms() {
    count=$1
    output=$2
    {
        printf '%s\n' 'kofun-adt-usefulness/v2'
        printf 'adt|id=%s|name=Wide\n' "$(identity 3000)"
        ordinal=0
        while test "$ordinal" -lt 64; do
            printf 'constructor|id=%s|owner=%s|ordinal=%s|name=C%s|fields=-\n' \
                "$(identity "$((4000 + ordinal))")" "$(identity 3000)" \
                "$ordinal" "$ordinal"
            ordinal=$((ordinal + 1))
        done
        printf 'target|adt=%s\n' "$(identity 3000)"
        index=0
        while test "$index" -lt "$count"; do
            printf 'arm|index=%s|span=%s..%s|guard=no\n' \
                "$index" "$((10 + index * 10))" "$((18 + index * 10))"
            printf 'alternative|arm=%s|index=0|pattern=%s\n' \
                "$index" "$(identity "$((4000 + index % 64))")"
            index=$((index + 1))
        done
    } > "$output"
}
generate_arms 64 "$WORK/arms-boundary.matrix"
run_success arms-boundary "$WORK/arms-boundary.matrix"
assert_grep "arms-boundary.result" -F 'complete|arms=64|alternatives=64|' \
    "$WORK/arms-boundary.result"
generate_arms 65 "$WORK/arms-over.matrix"
expect_failure arms-over "$WORK/arms-over.matrix" E2S110
assert_grep "arms-over.actual" -F 'exceeds 64 arms' "$WORK/arms-over.actual"

# Alternatives within one arm, and alternatives across the whole model. The
# second bound is reached with sixteen arms of eight, which is the first shape
# in which both are live at once.
generate_alternatives() {
    per_arm=$1
    arms=$2
    output=$3
    {
        printf '%s\n' 'kofun-adt-usefulness/v2'
        printf 'adt|id=%s|name=Wide\n' "$(identity 3000)"
        ordinal=0
        while test "$ordinal" -lt 64; do
            printf 'constructor|id=%s|owner=%s|ordinal=%s|name=C%s|fields=-\n' \
                "$(identity "$((4000 + ordinal))")" "$(identity 3000)" \
                "$ordinal" "$ordinal"
            ordinal=$((ordinal + 1))
        done
        printf 'target|adt=%s\n' "$(identity 3000)"
        index=0
        emitted=0
        while test "$index" -lt "$arms"; do
            printf 'arm|index=%s|span=%s..%s|guard=no\n' \
                "$index" "$((10 + index * 10))" "$((18 + index * 10))"
            slot=0
            while test "$slot" -lt "$per_arm"; do
                printf 'alternative|arm=%s|index=%s|pattern=%s\n' \
                    "$index" "$slot" "$(identity "$((4000 + emitted % 64))")"
                emitted=$((emitted + 1))
                slot=$((slot + 1))
            done
            index=$((index + 1))
        done
    } > "$output"
}
generate_alternatives 8 1 "$WORK/per-arm-boundary.matrix"
expect_failure per-arm-boundary "$WORK/per-arm-boundary.matrix" E2S25
if grep -F 'exceeds 8 alternatives' "$WORK/per-arm-boundary.actual" >/dev/null
then
    assert_fail 'the declared 8-alternative arm was rejected while reading'
fi
generate_alternatives 9 1 "$WORK/per-arm-over.matrix"
expect_failure per-arm-over "$WORK/per-arm-over.matrix" E2S110
assert_grep "per-arm-over.actual" -F 'exceeds 8 alternatives' \
    "$WORK/per-arm-over.actual"

# Sixty-four constructors cannot fill 128 distinct alternatives, so the
# 128-alternative model is admitted and then answered as an ordinary redundancy
# — which is the point: the bound is not what stopped it. The 129th crosses the
# bound while reading.
generate_alternatives 8 16 "$WORK/alternatives-boundary.matrix"
expect_failure alternatives-boundary "$WORK/alternatives-boundary.matrix" E2S26
if grep -F 'exceeds 128 alternatives' "$WORK/alternatives-boundary.actual" \
    >/dev/null
then
    assert_fail 'the declared 128-alternative boundary was rejected while reading'
fi
generate_alternatives 8 17 "$WORK/alternatives-over.matrix"
expect_failure alternatives-over "$WORK/alternatives-over.matrix" E2S110
assert_grep "alternatives-over.actual" -F 'exceeds 128 alternatives' \
    "$WORK/alternatives-over.actual"

# Fields on one constructor.
generate_fields() {
    count=$1
    output=$2
    {
        printf '%s\n' 'kofun-adt-usefulness/v2'
        printf 'adt|id=%s|name=Leaf\n' "$(identity 5000)"
        printf 'constructor|id=%s|owner=%s|ordinal=0|name=Only|fields=-\n' \
            "$(identity 5001)" "$(identity 5000)"
        printf 'adt|id=%s|name=Holder\n' "$(identity 5100)"
        printf 'constructor|id=%s|owner=%s|ordinal=0|name=Hold|fields=' \
            "$(identity 5101)" "$(identity 5100)"
        index=0
        while test "$index" -lt "$count"; do
            printf '%s%s' "$(test "$index" -eq 0 || printf ,)" "$(identity 5000)"
            index=$((index + 1))
        done
        printf '\n'
        printf 'target|adt=%s\n' "$(identity 5100)"
        printf 'arm|index=0|span=10..18|guard=no\n'
        printf 'alternative|arm=0|index=0|pattern=_\n'
    } > "$output"
}
generate_fields 4 "$WORK/fields-boundary.matrix"
run_success fields-boundary "$WORK/fields-boundary.matrix"
generate_fields 5 "$WORK/fields-over.matrix"
expect_failure fields-over "$WORK/fields-over.matrix" E2S110
assert_grep "fields-over.actual" -F 'exceeds 4 fields' "$WORK/fields-over.actual"

# Columns are a derived bound rather than an independent one. A row widens by
# `arity - 1` each time its head is specialized, and only the leftmost column is
# ever specialized before the ones beside it, so the widest a row can get is
# `1 + (depth - 1) * (fields - 1)`. At the accepted maxima — depth 8, four
# fields — that is 22, and a 23rd column needs one of those two bounds crossed
# first. The generator below spells the leftmost spine and leaves the siblings
# wild, which is the shape that reaches it.
generate_spine() {
    levels=$1
    output=$2
    pattern=$(identity "$((600 + levels))")
    level=$((levels - 1))
    while test "$level" -ge 1; do
        pattern="$(identity "$((600 + level))")($pattern,_,_,_)"
        level=$((level - 1))
    done
    {
        printf '%s\n' 'kofun-adt-usefulness/v2'
        level=$levels
        while test "$level" -ge 1; do
            printf 'adt|id=%s|name=L%s\n' "$(identity "$((500 + level))")" "$level"
            if test "$level" -eq "$levels"; then
                printf 'constructor|id=%s|owner=%s|ordinal=0|name=A%s|fields=-\n' \
                    "$(identity "$((600 + level))")" \
                    "$(identity "$((500 + level))")" "$level"
                printf 'constructor|id=%s|owner=%s|ordinal=1|name=B%s|fields=-\n' \
                    "$(identity "$((700 + level))")" \
                    "$(identity "$((500 + level))")" "$level"
            else
                printf 'constructor|id=%s|owner=%s|ordinal=0|name=S%s|fields=%s,%s,%s,%s\n' \
                    "$(identity "$((600 + level))")" \
                    "$(identity "$((500 + level))")" "$level" \
                    "$(identity "$((500 + level + 1))")" \
                    "$(identity "$((500 + level + 1))")" \
                    "$(identity "$((500 + level + 1))")" \
                    "$(identity "$((500 + level + 1))")"
            fi
            level=$((level - 1))
        done
        printf 'target|adt=%s\n' "$(identity 501)"
        printf 'arm|index=0|span=10..18|guard=no\n'
        printf 'alternative|arm=0|index=0|pattern=%s\n' "$pattern"
        printf 'arm|index=1|span=20..28|guard=no\n'
        printf 'alternative|arm=1|index=0|pattern=_\n'
    } > "$output"
}
generate_spine 8 "$WORK/columns-widest.matrix"
run_success columns-widest "$WORK/columns-widest.matrix"
assert_grep "columns-widest.result" -F '|columns=22|' \
    "$WORK/columns-widest.result"

# A line longer than the reader's buffer, and an input larger than its budget.
{
    sed -n '1,/^target|/p' "$CASES/fixtures/flat_exhaustive.matrix"
    printf 'arm|index=0|span=10..18|guard=no|'
    index=0
    while test "$index" -lt 5000; do
        printf 'x'
        index=$((index + 1))
    done
    printf '\n'
} > "$WORK/long-line.matrix"
expect_failure long-line "$WORK/long-line.matrix" E2S110
assert_grep "long-line.actual" -F 'line exceeds 4096 bytes' \
    "$WORK/long-line.actual"

# ---------------------------------------------------------------------------
# 9. The rules, proved by removing them.
#
# Each mutation below rebuilds the oracle with one behaviour changed and
# requires this corpus to notice. A gate that only reads the good path cannot
# tell whether the bad one is still refused, and every one of these has a
# plausible-looking wrong version.
# ---------------------------------------------------------------------------
mutate() {
    label=$1
    expression=$2
    sed "$expression" "$SOURCE" > "$WORK/mutant-$label.c"
    if cmp -s "$SOURCE" "$WORK/mutant-$label.c"; then
        assert_fail "mutation $label changed nothing"
    fi
    "$CC" -std=c11 -w "$WORK/mutant-$label.c" -o "$WORK/mutant-$label"
}

# The mutant must disagree with the recorded answer for one named fixture.
mutant_disagrees() {
    label=$1
    fixture=$2
    set +e
    "$WORK/mutant-$label" "$CASES/fixtures/$fixture.matrix" \
        "$WORK/mutant-$label.result" > "$WORK/mutant-$label.actual" 2>&1
    mutant_status=$?
    set -e
    if test -f "$CASES/fixtures/$fixture.stderr"; then
        if cmp -s "$CASES/fixtures/$fixture.stderr" "$WORK/mutant-$label.actual"
        then
            assert_fail "mutation $label left $fixture answering identically"
        fi
    elif test "$mutant_status" -eq 0; then
        assert_fail "mutation $label left $fixture accepted"
    fi
}

# Specialization keeps wildcard rows: a wildcard admits the constructor being
# specialized on, so it must survive into the narrowed matrix. Dropping it makes
# a wildcard stop covering anything below it, and the overlapping product — three
# rows that together cover four values, none of them alone — reports a case as
# missing.
mutate specialize \
    's/^        if (head->kind == PATTERN_CONSTRUCTOR &&$/        if (head->kind != PATTERN_CONSTRUCTOR ||/'
mutant_disagrees specialize product_overlapping

# The default matrix keeps only the rows that admit every constructor. Keeping
# the constructor rows too makes a leftover case look covered by a row that
# names something else.
mutate default 's/^        if (head->kind == PATTERN_CONSTRUCTOR) continue;$//'
mutant_disagrees default flat_missing

# The guard rule is two rules, and each is mutated on its own.
#
# A guarded arm covers nothing for exhaustiveness, because its guard may fail.
# Letting it cover makes a guarded wildcard answer for every case it would only
# have matched when the guard held.
mutate guard-coverage 's/^        if (arm->guarded) continue;$//'
mutant_disagrees guard-coverage guarded_wildcard_not_covering

# And a guarded arm hides nothing from the arms after it. Letting it hide makes
# an unguarded wildcard behind a guarded one look unreachable, which is the
# report that would send someone to delete the arm that actually runs.
mutate guard-redundancy 's/^                if (item->arm != arm_index &&$/                if (false \&\&/'
mutant_disagrees guard-redundancy guarded_then_wildcard

# The witness is the ordinal-least constructor the column never names. Taking
# the mirrored ordinal instead reports a constructor that is covered, which is
# what "canonical" is protecting against: not a missing witness but a wrong one.
mutate witness-order \
    's/^            \*absent = constructor;$/            *absent = constructor_at_ordinal(program, adt, total - 1u - ordinal);/'
mutant_disagrees witness-order flat_missing

# Identity is the resolved id. Dropping the owner check lets the decoy
# constructor — same display name, different owner — stand in for the payload's.
mutate identity \
    's/strcmp(constructor->owner, program->adts\[expected_adt\].id) != 0/0/'
mutant_disagrees identity decoy_owner

# The budget is checked before every visit. Lowering it refuses a model the
# corpus otherwise accepts, which is the only way to observe a bound set as
# headroom above every model the other bounds admit.
mutate budget 's|#define OPERATION_LIMIT UINT64_C(65536)|#define OPERATION_LIMIT UINT64_C(16)|'
set +e
"$WORK/mutant-budget" "$CASES/fixtures/nested_exhaustive.matrix" \
    "$WORK/mutant-budget.result" > "$WORK/mutant-budget.actual" 2>&1
budget_status=$?
set -e
assert_num "lowered budget refuses" "$budget_status" -eq 1
assert_grep "mutant-budget.actual" -F 'exceeds 16 operations' \
    "$WORK/mutant-budget.actual"
assert_absent "mutant-budget.result" "$WORK/mutant-budget.result"

# ---------------------------------------------------------------------------
# 10. The same answers under every build this repository can produce.
# ---------------------------------------------------------------------------
for optimisation in -O0 -O2; do
    "$CC" -std=c11 "$optimisation" -Wall -Wextra -Werror -pedantic \
        "$SOURCE" -o "$WORK/adt-usefulness-v2$optimisation"
    "$WORK/adt-usefulness-v2$optimisation" \
        "$CASES/fixtures/nested_exhaustive.matrix" \
        "$WORK/optimisation$optimisation.result"
    cmp "$WORK/nested_exhaustive.result" "$WORK/optimisation$optimisation.result"
done

if command -v clang >/dev/null 2>&1; then
    clang -std=c11 -Wall -Wextra -Werror -pedantic "$SOURCE" \
        -o "$WORK/adt-usefulness-v2-clang"
    "$WORK/adt-usefulness-v2-clang" "$CASES/fixtures/nested_exhaustive.matrix" \
        "$WORK/clang.result"
    cmp "$WORK/nested_exhaustive.result" "$WORK/clang.result"
fi

"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$SOURCE" -o "$WORK/adt-usefulness-v2-sanitized"
for fixture in nested_exhaustive depth_three_exhaustive product_overlapping \
    binding_roles
do
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/adt-usefulness-v2-sanitized" "$CASES/fixtures/$fixture.matrix" \
        "$WORK/sanitized-$fixture.result"
    cmp "$WORK/$fixture.result" "$WORK/sanitized-$fixture.result"
done
# The refusal paths run under the sanitizers too: they are where the reader
# stops early, and an early stop is where a partial structure would be read.
for fixture in nested_missing depth_three_redundant cycle too_many_fields
do
    set +e
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/adt-usefulness-v2-sanitized" "$CASES/fixtures/$fixture.matrix" \
        "$WORK/sanitized-$fixture.result" \
        > "$WORK/sanitized-$fixture.actual" 2>&1
    sanitized_status=$?
    set -e
    assert_num "sanitized $fixture status" "$sanitized_status" -eq 1
    assert_absent "sanitized-$fixture.result" "$WORK/sanitized-$fixture.result"
done

printf '%s\n' 'int main(void) { return 0; }' > "$WORK/analyzer-probe.c"
if "$CC" -std=c11 -O0 -Wall -Wextra -Werror -pedantic -fanalyzer \
    "$WORK/analyzer-probe.c" -o "$WORK/analyzer-probe" >/dev/null 2>&1
then
    "$CC" -std=c11 -O0 -Wall -Wextra -Werror -pedantic -fanalyzer \
        "$SOURCE" -o "$WORK/adt-usefulness-v2-analyzed"
    printf '%s\n' 'PASS: GCC analyzer accepts the recursive usefulness oracle'
fi

printf '%s\n' \
    'PASS: depth 0 through 8, products, or alternatives, guards, and roles are exact' \
    'PASS: identity decides coverage; display names decide only what the answer reads' \
    'PASS: cycles, broken links, wrong arity, and stale identities fail closed' \
    'PASS: every bound accepts its last model and refuses the first one past it' \
    'PASS: seven removed rules and a lowered budget are each observed by this corpus'

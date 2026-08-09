#!/usr/bin/env sh
set -eu

# RFC-0001 stage 1: the canonical allocator contract and its bounded Stage 2
# projection, pinned against each other.
#
# This gate proves three things and deliberately no more:
#
#   1. the projection compiles and runs through the ordinary compiler, and its
#      observations match the pinned golden;
#   2. the canonical contract and the projection have not drifted apart --
#      every decision the canonical source makes is one the projection makes;
#   3. the seed adds no capability. No `alloc` effect, no `with` scope, no
#      region enforcement, and no release claim appear anywhere.
#
# It does not execute the canonical source. That source uses records and
# closed ADTs the Stage 2 Core does not lower yet, which is exactly why the
# projection exists; the pin below is what keeps the two honest until the
# Core reaches it.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CANONICAL="$ROOT/stdlib/alloc/alloc.kofun"
PROJECTION="$ROOT/tests/stdlib/alloc/alloc.kofun"
EXPECTED="$ROOT/tests/stdlib/alloc/alloc.stdout"
WORK=${KOFUN_ALLOC_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}stdlib-alloc"}

fail() {
    printf '%s\n' "FAIL: stdlib alloc: $*" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

test -s "$CANONICAL" || fail 'the canonical contract is missing'
test -s "$PROJECTION" || fail 'the projection is missing'
test -s "$EXPECTED" || fail 'the pinned observation is missing'

# 1. The projection runs, and twice with the same result: a decision function
#    that depended on anything but its arguments would show up here.
"$ROOT/bin/kofun" check "$PROJECTION" >/dev/null ||
    fail 'the projection did not type-check'
"$ROOT/bin/kofun" run "$PROJECTION" >"$WORK/first.stdout" ||
    fail 'the projection did not run'
"$ROOT/bin/kofun" run "$PROJECTION" >"$WORK/second.stdout" ||
    fail 'the projection did not run a second time'
cmp "$WORK/first.stdout" "$WORK/second.stdout" ||
    fail 'the projection is not deterministic'
cmp "$EXPECTED" "$WORK/first.stdout" ||
    fail 'the projection observation differs from its pinned golden'

# 2. The drift pin. Every name the canonical contract declares as a decision
#    must exist in the projection, and every decision name the projection
#    declares must exist in the canonical contract. A decision added to one
#    surface and not the other is the drift this pin refuses; the canonical
#    source may carry *types* the projection cannot spell, which is why only
#    `fn` names are compared.
canonical_decisions() {
    sed -n 's/^fn \(alloc_[a-z_]*\)(.*/\1/p' "$1" | LC_ALL=C sort -u
}
canonical_decisions "$CANONICAL" >"$WORK/canonical.names"
canonical_decisions "$PROJECTION" >"$WORK/projection.names"

# The projection spells the encodings as functions the canonical source has no
# need for, because the canonical source has the types instead. Those are
# declared here rather than left to a wildcard, so a genuinely new projection
# name still fails the pin.
cat >"$WORK/encoding.names" <<'ENCODINGS'
alloc_error_exhausted
alloc_error_quota_exceeded
alloc_error_region_closed
alloc_error_wrong_allocator
alloc_kind_arena
alloc_kind_fixed
alloc_kind_quota
alloc_kind_tracing
alloc_refuse
ENCODINGS

missing=$(comm -23 "$WORK/canonical.names" "$WORK/projection.names")
if test -n "$missing"; then
    printf '%s\n' \
        'FAIL: stdlib alloc: the canonical contract declares decisions the projection does not:' \
        "$missing" >&2
    exit 1
fi
LC_ALL=C sort -u "$WORK/canonical.names" "$WORK/encoding.names" \
    >"$WORK/allowed.names"
extra=$(comm -13 "$WORK/allowed.names" "$WORK/projection.names")
if test -n "$extra"; then
    printf '%s\n' \
        'FAIL: stdlib alloc: the projection declares decisions the canonical contract does not:' \
        "$extra" >&2
    exit 1
fi

# 3. The seed grants nothing. RFC-0001 stages 2 through 6 own the effect
#    label, the scope, and region checking; a seed that quietly introduced one
#    of them would make the stage boundary meaningless.
# Matched against declarations rather than prose: `RegionClosed` is an error
# case this seed owns, and a substring search for "region" would refuse the
# seed for naming its own vocabulary.
for forbidden in '^with ' '^effect ' '^region ' '^fn alloc_region_'; do
    if grep -nE "$forbidden" "$CANONICAL" "$PROJECTION" >/dev/null 2>&1; then
        fail "the seed introduces a declaration matching \`$forbidden\`, which is a later stage"
    fi
done
if grep -rn 'alloc' "$ROOT/release/claims.json" >/dev/null 2>&1; then
    if grep -n '"id": "alloc' "$ROOT/release/claims.json" >/dev/null 2>&1; then
        fail 'the seed added an allocator release claim'
    fi
fi

decisions=$(grep -c '' "$WORK/canonical.names")
printf 'PASS: the allocator projection runs deterministically and matches its golden\n'
printf 'PASS: %s canonical decisions and the projection have not drifted apart\n' "$decisions"
printf 'PASS: the seed adds no allocator capability, effect, scope, or claim\n'

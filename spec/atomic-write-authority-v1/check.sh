#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/spec/atomic-write-authority-v1"
WORK=${KOFUN_ATOMIC_WRITE_AUTHORITY_WORK:-"$ROOT/build/atomic-write-authority"}
ASSERT_CONTEXT='AtomicWriteAuthority profile v1'
. "$ROOT/tests/assertions/assert.sh"

case $WORK in
    */atomic-write-authority|*/atomic-write-authority.*) ;;
    *) assert_fail "work directory must end in atomic-write-authority[.suffix]: $WORK" ;;
esac

command -v node >/dev/null 2>&1 || assert_fail 'node is required'
rm -rf "$WORK"
mkdir -p "$WORK"

node --check "$HERE/model.mjs"
node --check "$HERE/check.mjs"

node "$HERE/check.mjs" >"$WORK/contract.stdout"
assert_grep 'the profile properties hold' -Fq 'profile properties hold on the model' "$WORK/contract.stdout"
assert_grep 'every mutation is caught distinctly' -Fq 'each caught, by a distinct property set' "$WORK/contract.stdout"

# Vectors are deterministic, which is what lets a future implementation be
# compared against a committed file rather than against a rerun.
node "$HERE/check.mjs" --vectors >"$WORK/vectors.first.json"
node "$HERE/check.mjs" --vectors >"$WORK/vectors.second.json"
cmp "$WORK/vectors.first.json" "$WORK/vectors.second.json"
cmp "$HERE/vectors/canonical.json" "$WORK/vectors.first.json"

# The profile and the model are one fact. Each phrase occurs once and fits on
# one line, because an assertion matching a recurring or wrapped phrase is one
# a mutation walks past.
assert_regular_file 'the profile' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md records the selected option' -Fq \
    'Option A was selected on' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md refuses by construction, not validation' -Fq \
    'and a missing parameter cannot' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md keeps the reservation per directory' -Fq \
    'the reservation is per **directory**' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md keeps a committed rename committed' -Fq \
    'does not un-answer it' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md claims no implementation' -Fq \
    'no syscall adapter, no capability, and no release claim' "$HERE/PROFILE.md"

# The allowlist is in the model and described in the profile; drift between
# them is what this pair of checks exists to prevent.
for fs in ext4 xfs btrfs tmpfs; do
    assert_grep "PROFILE.md lists $fs" -Fq "| $fs |" "$HERE/PROFILE.md"
done

printf '%s\n' \
    'PASS: 13 profile properties hold on the pure state and reservation model' \
    'PASS: 8 implementation mistakes are each caught by a distinct property set' \
    'PASS: canonical vectors are deterministic, and the profile states the model’s allowlist and rules'

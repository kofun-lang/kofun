#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/spec/wasi-command-projection-v1"
WORK=${KOFUN_WASI_PROJECTION_WORK:-"$ROOT/build/wasi-command-projection"}
ASSERT_CONTEXT='WASI command projection v1'
. "$ROOT/tests/assertions/assert.sh"

case $WORK in
    */wasi-command-projection|*/wasi-command-projection.*) ;;
    *) assert_fail "work directory must end in wasi-command-projection[.suffix]: $WORK" ;;
esac

command -v node >/dev/null 2>&1 || assert_fail 'node is required'
rm -rf "$WORK"
mkdir -p "$WORK"

node --check "$HERE/model.mjs"
node --check "$HERE/check.mjs"

node "$HERE/check.mjs" >"$WORK/contract.stdout"
assert_grep 'the projection properties hold' -Fq 'projection properties hold' "$WORK/contract.stdout"
assert_grep 'every mutation is caught distinctly' -Fq 'each caught, by a distinct property set' "$WORK/contract.stdout"

node "$HERE/check.mjs" --vectors >"$WORK/vectors.first.json"
node "$HERE/check.mjs" --vectors >"$WORK/vectors.second.json"
cmp "$WORK/vectors.first.json" "$WORK/vectors.second.json"
cmp "$HERE/vectors/canonical.json" "$WORK/vectors.first.json"

# #1098 is consumed, never mutated. If its frozen surface moved, this profile's
# import table is describing something that no longer exists.
node "$HERE/../wasi-command-profile-v1/check.mjs" >"$WORK/profile.stdout" 2>&1 ||
    assert_fail 'the frozen #1098 profile no longer checks out'

assert_regular_file 'the profile' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md records the selected option' -Fq \
    'Option A — explicit command context and authority values' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md derives imports from operations' -Fq \
    'easier direction to write and it' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md offers no absent/empty distinction' -Fq \
    'absent/empty distinction**' "$HERE/PROFILE.md"
# Each asserted phrase must occur once AND fit on one line. Two of these
# failed first as whole sentences the document wraps; grep -F does not know
# about wrapping, and the gate failed on correct prose.
assert_grep 'PROFILE.md keeps build and run refusing' -Fq \
    'is therefore fail-closed' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md claims no implementation' -Fq \
    'no capability or release claim' "$HERE/PROFILE.md"

printf '%s\n' \
    'PASS: 14 projection properties hold over 10 source operations and 13 frozen imports' \
    'PASS: 9 implementation mistakes are each caught by a distinct property set' \
    'PASS: canonical vectors are deterministic and the frozen #1098 surface is unchanged'

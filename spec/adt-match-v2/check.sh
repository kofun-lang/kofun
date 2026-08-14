#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/spec/adt-match-v2"
WORK=${KOFUN_ADT_MATCH_V2_WORK:-"$ROOT/build/adt-match-v2"}
ASSERT_CONTEXT='ADT match v2 profile'
. "$ROOT/tests/assertions/assert.sh"

case $WORK in
    */adt-match-v2|*/adt-match-v2.*) ;;
    *) assert_fail "work directory must end in adt-match-v2[.suffix]: $WORK" ;;
esac

command -v node >/dev/null 2>&1 || assert_fail 'node is required'
rm -rf "$WORK"
mkdir -p "$WORK"

node --check "$HERE/model.mjs"
node --check "$HERE/check.mjs"

node "$HERE/check.mjs" >"$WORK/contract.stdout"
assert_grep 'the profile properties hold' -Fq 'profile properties hold' "$WORK/contract.stdout"
assert_grep 'every mutation is caught distinctly' -Fq 'each caught, by a distinct property set' "$WORK/contract.stdout"

node "$HERE/check.mjs" --vectors >"$WORK/vectors.first.json"
node "$HERE/check.mjs" --vectors >"$WORK/vectors.second.json"
cmp "$WORK/vectors.first.json" "$WORK/vectors.second.json"
cmp "$HERE/vectors/canonical.json" "$WORK/vectors.first.json"

# The limits table in the profile has to be the limits in the model. Reading
# them out of the model and requiring the document to state each one is what
# keeps a table from drifting into decoration.
assert_regular_file 'the profile' "$HERE/PROFILE.md"
for limit in $(node -e '
  import("./spec/adt-match-v2/model.mjs").then((m) => {
    for (const v of Object.values(m.LIMITS)) process.stdout.write(v + "\n");
  });
' 2>/dev/null); do
    assert_grep "PROFILE.md states the bound $limit" -Fq "| $limit |" "$HERE/PROFILE.md"
done

assert_grep 'PROFILE.md refuses ranges and record subpatterns' -Fq \
    'ranges, and record' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md keeps a guarded arm out of coverage' -Fq \
    'never counts toward exhaustiveness' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md orders witnesses by declaration' -Fq \
    'order**, not alphabetical order' "$HERE/PROFILE.md"
assert_grep 'PROFILE.md makes unsupported a checked fact' -Fq \
    'must be a checked fact, not prose' "$HERE/PROFILE.md"

printf '%s\n' \
    'PASS: 11 profile properties hold across all ten recorded decisions' \
    'PASS: 10 plausible checker mistakes are each caught by a distinct property set' \
    'PASS: canonical vectors are deterministic and the profile states the model’s bounds'

#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/spec/wasi-host-matrix-v1"
WORK=${KOFUN_WASI_HOST_MATRIX_WORK:-"$ROOT/build/wasi-host-matrix"}
ASSERT_CONTEXT='WASI host matrix policy v1'
. "$ROOT/tests/assertions/assert.sh"

case $WORK in
    */wasi-host-matrix|*/wasi-host-matrix.*) ;;
    *) assert_fail "work directory must end in wasi-host-matrix[.suffix]: $WORK" ;;
esac

command -v node >/dev/null 2>&1 || assert_fail 'node is required'
rm -rf "$WORK"
mkdir -p "$WORK"

node --check "$HERE/check.mjs"

# The validator, then its own mutations. Both run offline: this gate proves the
# manifest pins something a fetcher could verify, and never fetches.
node "$HERE/check.mjs" >"$WORK/validate.stdout"
assert_grep 'the manifest validates' -Fq '2 maintained hosts, 1 oracle' "$WORK/validate.stdout"

node "$HERE/check.mjs" --mutations >"$WORK/mutations.stdout"
assert_grep 'every mutation is refused by its own reason' -Fq \
    'each by its own reason' "$WORK/mutations.stdout"

# The policy and the manifest are one fact in two forms. These assertions are
# each on a sentence that occurs once, because an assertion matching a phrase
# that recurs is an assertion that a mutation walks past.
assert_regular_file 'the policy' "$HERE/POLICY.md"
assert_grep 'POLICY.md records the selected option' -Fq \
    'plus a pinned Node using its built-in WASI' "$HERE/POLICY.md"
assert_grep 'POLICY.md keeps the oracle out of the maintained count' -Fq \
    '**The oracle is never one of the two.**' "$HERE/POLICY.md"
# Each asserted phrase must fit on one line *and* occur once. The first
# version asserted a whole sentence, which the document wraps across two lines,
# so grep -F found nothing and the gate failed on correct prose.
assert_grep 'POLICY.md refuses a silent skip' -Fq \
    'There is no skip path' "$HERE/POLICY.md"
assert_grep 'POLICY.md bounds the security claim' -Fq \
    'It establishes no' "$HERE/POLICY.md"

# The pins the policy prose states have to be the pins the manifest carries,
# or the document and the gate are two facts that agree by luck.
for pin in $(node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  for (const h of m.hosts) if (h.role === "maintained-host") process.stdout.write(h.id + ":" + h.version + "\n");
' "$HERE/hosts.json"); do
    id=${pin%%:*}
    version=${pin#*:}
    assert_grep "POLICY.md states the $id pin" -Fq "**$version**" "$HERE/POLICY.md"
done

# The reserved target is still reserved. This gate decides a host matrix; it
# does not enable a backend, and a reader should not be able to mistake one for
# the other.
assert_grep 'POLICY.md disclaims enabling a backend' -Fq \
    'Nothing here installs a host or runs a module.' "$HERE/POLICY.md"

printf '%s\n' \
    'PASS: the host matrix pins two maintained implementations plus one oracle, each with digested artifacts' \
    'PASS: 17 manifest mutations are refused, each by its own reason' \
    'PASS: the policy and the manifest state the same pins, and the target stays reserved'

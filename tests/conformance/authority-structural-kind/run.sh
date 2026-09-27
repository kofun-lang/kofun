#!/bin/sh
set -eu

# #1243. Owned/Managed structural classification over the nominal forms Stage 2
# already admits, and the refusals the classification implies.
#
# Every fixture is a whole program. A refusal fixture must exit 1 with its
# golden first line and no C artifact; a control fixture must build. The
# refusals are E353 (a copy, an equality, or a mode-less parameter head of an
# Owned composite), E2S123 (positional `take` twice) and E2S181 (an `edit`
# parameter). The controls are the Managed counterparts -- a trivial `Point`
# record, `EnvironmentKey`, and the K-ANY `Loop` -- which keep the behaviour
# they had before this slice.

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cases="$root/tests/conformance/authority-structural-kind"
work=${TMPDIR:-/tmp}/kofun-authority-structural-kind.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"
ASSERT_CONTEXT='authority structural kind'
. "$root/tests/assertions/assert.sh"

KOFUN="$root/bin/kofun"

refusals='
owned_record_copy
adt_copy_parameter
owned_empty_variant_pass
owned_record_take_twice
owned_record_edit_param
launder_return_copy
owned_record_equality_int
managed_record_take_twice
managed_record_edit_param
'

controls='
managed_record_copy
loop_managed
key_managed
'

for stem in $refusals; do
    set +e
    "$KOFUN" build "$cases/$stem.kofun" -o "$work/$stem.bin" \
        --emit-c "$work/$stem.c" >"$work/$stem.actual" 2>&1
    status=$?
    set -e
    test "$status" -eq 1 ||
        fail "$stem exited $status instead of 1"
    test "$(wc -l <"$work/$stem.actual" | tr -d ' ')" -eq 1 ||
        fail "$stem printed more than one line"
    cmp "$cases/$stem.stderr" "$work/$stem.actual" ||
        fail "$stem diagnostic differs from its golden"
    test ! -e "$work/$stem.c" ||
        fail "$stem committed a C artifact"
done

for stem in $controls; do
    "$KOFUN" build "$cases/$stem.kofun" -o "$work/$stem.bin" \
        --emit-c "$work/$stem.c" >"$work/$stem.actual" 2>&1 ||
        fail "$stem does not build: $(head -n 1 "$work/$stem.actual")"
    test -s "$work/$stem.c" ||
        fail "$stem did not emit C"
done

# C3. The causal path is rendered from declaration names, and a rename moves
# the names but not which component is reported. The copy refusal of the same
# shape with the field and type renamed names the new field.
cat >"$work/renamed.kofun" <<'FIXTURE'
type Wallet = { keyring: RootAuthority }
fn copy(value: Wallet) -> Int {
    let alias = value
    return 0
}

fn main() -> Int {
    return 0
}
FIXTURE
set +e
"$KOFUN" build "$work/renamed.kofun" -o "$work/renamed.bin" \
    --emit-c "$work/renamed.c" >"$work/renamed.actual" 2>&1
renamed_status=$?
set -e
test "$renamed_status" -eq 1 ||
    fail "the renamed copy probe was accepted"
grep -F 'Wallet.keyring -> RootAuthority' "$work/renamed.actual" >/dev/null ||
    fail 'the renamed copy probe did not name the renamed path'

printf '%s\n' \
    "PASS: Owned records and ADTs classify, their causal path renders, and copy/equality/mode-less-head refuse E353 with take-twice E2S123 and edit E2S181 while the Managed controls are unchanged"

#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/spec/wasi-command-profile-v1"
WORK=${KOFUN_WASI_COMMAND_PROFILE_WORK:-"$ROOT/build/wasi-command-profile"}
TARGET=wasm32-wasi-command1
ASSERT_CONTEXT='WASI command capability profile v1'
. "$ROOT/tests/assertions/assert.sh"

case $WORK in
    */wasi-command-profile|*/wasi-command-profile.*) ;;
    *) assert_fail "work directory must end in wasi-command-profile[.suffix]: $WORK" ;;
esac

command -v node >/dev/null 2>&1 || assert_fail 'node is required'
rm -rf "$WORK"
mkdir -p "$WORK"

node --check "$HERE/contract.mjs"
node --check "$HERE/model.mjs"
node --check "$HERE/check.mjs"
node "$HERE/check.mjs"

node "$HERE/model.mjs" vectors >"$WORK/vectors.first.json"
node "$HERE/model.mjs" vectors >"$WORK/vectors.second.json"
cmp "$WORK/vectors.first.json" "$WORK/vectors.second.json"
cmp "$HERE/vectors/canonical.json" "$WORK/vectors.first.json"
node "$HERE/model.mjs" compare "$HERE/vectors/canonical.json" >"$WORK/compare.stdout"
assert_grep 'the canonical-vector comparison' -Fq 'is canonical' "$WORK/compare.stdout"

# #1296's first slice enabled this target for programs that reach no host
# operation, so "reserved and unsupported" stopped being true. What replaces it
# is the boundary that *is* true: a program performing a host operation is
# refused, atomically, because the projection this profile describes is not
# implemented for it yet.
#
# The assertion moved rather than being deleted. A gate whose subject is
# implemented and whose assertion is removed leaves nothing saying where the
# implementation stops.
set +e
"$ROOT/bin/kofun" build "$ROOT/examples/wasm_arithmetic.kofun" \
    --target "$TARGET" -o "$WORK/refused.wasm" \
    >"$WORK/refused.stdout" 2>"$WORK/refused.stderr"
status=$?
set -e
assert_num 'the unimplemented-operation status' "$status" -ne 0
assert_absent 'the unimplemented-operation artifact' "$WORK/refused.wasm"
assert_file_empty 'the unimplemented-operation stdout' "$WORK/refused.stdout"
assert_grep 'the unimplemented-operation refusal names the boundary' \
    -Fq 'no host operations in this slice' "$WORK/refused.stderr"

printf '%s\n' \
    'PASS: canonical profile vectors are deterministic and byte-identical' \
    'PASS: the reference model refusal matrix and Node engine fixture pass' \
    "PASS: $TARGET refuses a host operation atomically and leaves no artifact"

#!/bin/sh
set -eu

# What two gates do when `readelf` is absent, run rather than read (#1496).
#
# Both wrapped their `readelf` assertions in `if command -v readelf` and said
# nothing when the branch was not taken. Running them that way showed the two
# were not the same case at all:
#
#   bootstrap/c_abi/check.sh   genuinely degrades. It also printed
#                              `PASS: the C ABI output is a dynamically linked
#                              executable` — the exact claim its skipped
#                              `readelf` reads — so it now prints a `SKIP` and
#                              withholds that one claim.
#
#   stdlib/tests/verify.sh     never degraded. Sixty lines before its
#                              conditional it runs `stdlib/set/tests/verify.sh`,
#                              which invokes `readelf` unguarded and dies with
#                              `command not found`. The conditional could not
#                              be taken, so `readelf` is now declared required
#                              at the top of that file and the assertions are
#                              unconditional.
#
# That asymmetry is why this executes rather than reads. A static check that
# each conditional has an `else` would have passed on both, and would have
# certified a branch that no run can reach as a behaviour.
#
# What it costs, measured: `bootstrap/c_abi/check.sh` is about 1 s and
# `stdlib/tests/verify.sh` about 51 s on a warm tree, and the second is a real
# addition to the suite. It is taken because "this gate requires readelf" is a
# claim about a run without readelf, and nothing else here makes one.
#
# The shim hides `readelf` and nothing else: it is a directory of symlinks to
# every other command the gates need, placed ahead of an empty PATH. Hiding it
# by breaking PATH entirely would test a different failure.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
ASSERT_CONTEXT="optional-tool-skips"
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-optional-tool-skips.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'optional-tool-skips: FAIL: %s\n' "$*" >&2
    exit 1
}

command -v readelf >/dev/null 2>&1 ||
    fail 'readelf must be present to prove what happens without it'

# The shim: every executable on the current PATH except `readelf`.
mkdir -p "$WORK/bin"
printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r directory; do
    test -d "$directory" || continue
    for candidate in "$directory"/*; do
        test -x "$candidate" || continue
        name=$(basename -- "$candidate")
        test "$name" != readelf || continue
        test ! -e "$WORK/bin/$name" || continue
        ln -s "$candidate" "$WORK/bin/$name" 2>/dev/null || true
    done
done

test ! -e "$WORK/bin/readelf" ||
    fail 'the shim still exposes readelf'
PATH="$WORK/bin" command -v readelf >/dev/null 2>&1 &&
    fail 'readelf is still reachable under the shim'

# The shim must not have hidden anything else, or a gate would fail for an
# unrelated reason and this check would read as a pass for the wrong cause.
for needed in sh cc grep sed awk printf_missing_is_fine; do
    test "$needed" = printf_missing_is_fine && continue
    PATH="$WORK/bin" command -v "$needed" >/dev/null 2>&1 ||
        fail "the shim hid $needed, which is not what this measures"
done

run_degraded() {
    label=$1
    script=$2
    expected=$3
    set +e
    KOFUN_C_ABI_WORK="$WORK/c-abi-work" \
        KOFUN_C_ABI_BUILD_DIR="$WORK/c-abi-build" \
        PATH="$WORK/bin" sh "$ROOT/$script" \
        >"$WORK/$label.stdout" 2>"$WORK/$label.stderr"
    status=$?
    set -e
    assert_num "$label exits 0 without readelf" "$status" -eq 0
    assert_grep "$label announces what it did not check" -Fq -- \
        "$expected" "$WORK/$label.stdout"
}

run_degraded c-abi bootstrap/c_abi/check.sh \
    'SKIP: dynamic linkage of the C ABI output (readelf unavailable)'
assert_executable 'degraded C ABI executable in private work directory' \
    "$WORK/c-abi-work/kofun-caller"
assert_executable 'degraded driver compiler in private C ABI build directory' \
    "$WORK/c-abi-build/kofun-c-abi"
# The claim its `readelf` reads must not be printed when it did not read it.
if grep -Fq 'PASS: the C ABI output is a dynamically linked executable' \
    "$WORK/c-abi.stdout"
then
    fail 'the C ABI gate claimed dynamic linkage on a run that never looked'
fi

# The stdlib gate requires `readelf` and must say which one is missing rather
# than dying inside a subordinate script with `command not found`.
set +e
PATH="$WORK/bin" sh "$ROOT/stdlib/tests/verify.sh" \
    >"$WORK/stdlib.stdout" 2>"$WORK/stdlib.stderr"
stdlib_status=$?
set -e
assert_num 'the stdlib gate refuses without readelf' "$stdlib_status" -eq 1
assert_grep 'the stdlib gate names the tool it needs' -Fq -- \
    'readelf is required' "$WORK/stdlib.stderr"
# It must refuse before doing the work, not after: the subordinate set gate is
# what used to report the absence, as a missing LOAD segment.
if grep -Fq 'no executable LOAD segment' "$WORK/stdlib.stderr"; then
    fail 'the stdlib gate still reports a missing readelf as a missing LOAD segment'
fi

printf '%s\n' \
    'PASS: the C ABI gate announces the assertions it skipped, exits 0, and withholds the claim they support' \
    'PASS: the stdlib gate refuses by naming readelf rather than dying inside a subordinate script'

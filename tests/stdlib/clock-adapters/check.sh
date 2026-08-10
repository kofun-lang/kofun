#!/bin/sh
set -eu

# Clock adapter gate for #647.
#
# Three things are checked, in this order:
#
#   1. the canonical surface in stdlib/clock/ still declares the adapter
#      contract, and its Linux adapter still reaches the kernel only through
#      the existing safe wrappers;
#   2. the executable producer runs identically on the reference interpreter
#      and the C11 backend, and specific decisions in its output are read
#      rather than accepted wholesale from a golden file;
#   3. the two mixing mistakes the separate types exist to prevent are
#      rejected by the toolchain.
#
# Nothing here reads or depends on host time. That is asserted, not assumed:
# the emitted C is searched for time headers and time symbols, and the
# producer is run twice and compared.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/stdlib/clock-adapters"
ASSERT_CONTEXT="clock adapters"
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-clock-adapters.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'clock adapters: FAIL: %s\n' "$*" >&2
    exit 1
}

require_line() {
    file=$1
    needle=$2
    label=$3
    assert_grep "$label" -Fq -- "$needle" "$file"
}

# ------------------------------------------------------- corpus hygiene

find "$CASES" -type f \( -name '*.py' -o -name '*.kf' \) >"$WORK/forbidden"
assert_file_empty 'forbidden Python or .kf source in the corpus' \
    "$WORK/forbidden"

# ---------------------------------------------------- canonical surface

canonical="$ROOT/stdlib/clock/adapters.kofun"
assert_regular_file 'canonical adapter surface' "$canonical"

for declaration in \
    'type ClockDomain =' \
    '| MonotonicDomain' \
    '| SystemDomain' \
    'type ClockIdentity = {' \
    'type MonotonicInstant = {' \
    'type SystemInstant = {' \
    'type Duration = {' \
    'type ClockError =' \
    'type MonotonicClock = {' \
    'type SystemClock = {' \
    'type Sleeper = {' \
    'type Waiter = {' \
    'type FakeClock = {' \
    'fn clock_identity_same(' \
    'fn clock_monotonic_compare(' \
    'fn clock_monotonic_elapsed(' \
    'fn clock_monotonic_add(' \
    'fn clock_deadline_reached(' \
    'fn clock_fake(' \
    'fn clock_fake_monotonic_now(' \
    'fn clock_fake_system_now(' \
    'fn clock_fake_advance(' \
    'fn clock_fake_register(' \
    'fn clock_fake_cancel(' \
    'fn clock_fake_poll('
do
    require_line "$canonical" "$declaration" \
        'canonical adapter surface lost a declaration'
done

for variant in WrongClockIdentity BackwardsTime ClockArithmeticOverflow \
    WaiterCancelled StaleClockHandle PlatformReadFailed
do
    require_line "$canonical" "| $variant" \
        'canonical ClockError lost a closed variant'
done

# The separation the whole contract rests on: monotonic readings carry an
# identity, system readings carry an epoch, and neither carries the other.
require_line "$canonical" '    identity: ClockIdentity,' \
    'monotonic instants no longer carry an identity'
require_line "$canonical" '    epoch_seconds: Int,' \
    'system instants no longer carry an epoch'
grep -A 4 'type SystemInstant = {' "$canonical" >"$WORK/system_instant.block"
assert_not_grep 'SystemInstant grew an identity; it is not comparable across reads' \
    -q -- 'identity' "$WORK/system_instant.block"

# The fake clock is the deterministic one: it must not read anything.
assert_not_grep 'the portable adapter surface names a syscall' \
    -q -- 'clock_gettime\|nanosleep\|__linux_syscall' "$canonical"

adapter="$ROOT/stdlib/clock/adapters_linux_x86_64.kofun"
assert_regular_file 'Linux adapter' "$adapter"
for declaration in \
    'let LINUX_CLOCK_REALTIME = 0' \
    'let LINUX_CLOCK_MONOTONIC = 1' \
    'type LinuxClockAdapter = {' \
    'fn clock_linux_monotonic_now(' \
    'fn clock_linux_system_now(' \
    'fn clock_linux_sleep(' \
    'fn clock_linux_sleep_until('
do
    require_line "$adapter" "$declaration" \
        'Linux adapter lost a declaration'
done
require_line "$adapter" 'posix.clock_now(LINUX_CLOCK_MONOTONIC)' \
    'Linux adapter does not use the existing safe clock_gettime wrapper'
require_line "$adapter" 'posix.sleep_once(request)' \
    'Linux adapter does not use the existing safe nanosleep wrapper'
assert_not_grep 'Linux clock adapter bypasses the standard Linux ABI boundary' \
    -q -- 'trusted intrinsic\|__linux_syscall' "$adapter"

# Both canonical files are still ahead of the compiler. Pinning that keeps
# the corpus honest: the executable evidence is the producer below, not these.
# The two files stop at different boundaries now that top-level constants
# parse, so each is pinned to its own rather than to one shared message.
canonical_boundary() {
    source=$1
    expected=$2
    if "$ROOT/bin/kofun" check "$source" \
        >"$WORK/canonical.stdout" 2>"$WORK/canonical.stderr"
    then
        fail "canonical source unexpectedly claimed executable codegen: $source"
    fi
    require_line "$WORK/canonical.stderr" "$expected" \
        "canonical source did not stop at the documented compiler boundary: $source"
}

canonical_boundary "$canonical" \
    'error[E2S32]: record `ClockIdentity` has a field type outside the Stage 2 Int/Bool/Text slice'
canonical_boundary "$adapter" \
    'error[E2S02]: expected top-level `fn`, `type`, or `let`'

# ------------------------------------------------------------- producer

producer="$CASES/adapters.kofun"
expected="$CASES/adapters.stdout"
assert_regular_file 'producer source' "$producer"
assert_regular_file 'producer golden' "$expected"

# The producer is self-contained on purpose: it cannot read a clock it cannot
# name, and it names none.
assert_not_grep 'the deterministic producer imports a module and is no longer sealed' \
    -q -- '^import ' "$producer"
assert_not_grep 'the deterministic producer names a platform clock' \
    -q -- 'clock_gettime\|nanosleep\|__linux_syscall\|Timestamp' "$producer"

"$ROOT/bin/kofun" check "$producer" \
    >"$WORK/check.stdout" 2>"$WORK/check.stderr" ||
    fail "producer did not check: $(cat "$WORK/check.stderr")"

"$ROOT/bin/kofun" build "$producer" -o "$WORK/adapters" \
    --emit-c "$WORK/adapters.c" >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    fail "producer did not build: $(cat "$WORK/build.stderr")"

"$WORK/adapters" >"$WORK/backend.stdout"
cmp "$expected" "$WORK/backend.stdout" ||
    fail 'C11 backend output differs from the recorded clock decisions'

# The reference executor must agree with the backend on the deterministic core.
"$ROOT/bin/kofun" run "$producer" >"$WORK/reference.stdout" 2>"$WORK/run.stderr" ||
    fail "producer did not run on the reference executor: $(cat "$WORK/run.stderr")"
cmp "$expected" "$WORK/reference.stdout" ||
    fail 'reference executor and C11 backend disagree on the deterministic core'

# Deterministic means deterministic: same binary, same bytes, twice.
"$WORK/adapters" >"$WORK/backend.second"
cmp "$WORK/backend.stdout" "$WORK/backend.second" ||
    fail 'the deterministic producer is not reproducible across runs'

# No ambient time, checked against the code that actually runs.
assert_not_grep 'the emitted C reaches for host time' -qE -- \
    'time\.h|clock_gettime|gettimeofday|nanosleep|localtime|CLOCK_[A-Z]' \
    "$WORK/adapters.c"

# ---------------------------------------------------------- typed HIR
#
# The Stage 2 semantic sidecar projects a bounded program — 64 functions, 512
# nodes — and the producer above is larger than that. typed_hir.kofun carries
# the same four value shapes and the same closed error through the projection,
# so "checked source → typed HIR → executable backend" is observed on a source
# that names the clock types rather than asserted about one that cannot fit.

witness="$CASES/typed_hir.kofun"
witness_expected="$CASES/typed_hir.stdout"
assert_regular_file 'typed HIR witness' "$witness"
assert_regular_file 'typed HIR witness golden' "$witness_expected"

"$ROOT/bin/kofun" check "$witness" \
    --emit-typed-sidecar "$WORK/typed_hir-semantic.json" --generation 1 \
    >"$WORK/witness.stdout" 2>"$WORK/witness.stderr" ||
    fail "typed HIR witness did not check: $(cat "$WORK/witness.stderr")"
assert_file_nonempty 'typed sidecar' "$WORK/typed_hir-semantic.json"
require_line "$WORK/typed_hir-semantic.json" '"stage2-semantic-v1"' \
    'typed sidecar is not the Stage 2 semantic artifact'
require_line "$WORK/typed_hir-semantic.json" '"completeness": "complete"' \
    'typed sidecar is a partial projection'
for named in ClockIdentity MonotonicInstant SystemInstant Duration ClockError
do
    require_line "$WORK/typed_hir-semantic.json" "\"$named\"" \
        'typed HIR does not carry the clock type'
done

"$ROOT/bin/kofun" build "$witness" -o "$WORK/typed_hir" \
    >"$WORK/witness.build.stdout" 2>"$WORK/witness.build.stderr" ||
    fail "typed HIR witness did not build: $(cat "$WORK/witness.build.stderr")"
"$WORK/typed_hir" >"$WORK/witness.run.stdout"
cmp "$witness_expected" "$WORK/witness.run.stdout" ||
    fail 'typed HIR witness output differs from the recorded decisions'

# ------------------------------------------------- recorded clock decisions
#
# Each block below names the decision it reads, so a failure says which rule
# changed rather than only that a golden moved.

field() {
    sed -n "$1,$2p" "$expected" | tr '\n' ' '
}

assert_eq 'identity: monotonic domain, serial, and the separate system domain' \
    "$(field 1 5)" '1 7 2 1 0 '
assert_eq 'system reading keeps its epoch fields' \
    "$(field 6 7)" '1700000000 250000000 '
assert_eq 'ordering inside one identity, then WrongClockIdentity(9)' \
    "$(field 8 12)" '0 -1 1 -1 9 '
assert_eq 'elapsed time, then BackwardsTime carrying the regression' \
    "$(field 13 17)" '0 1 500000000 -2 1500000000 '
assert_eq 'deadline carry, then ClockArithmeticOverflow at the Int limit' \
    "$(field 18 22)" '0 12 250000000 -3 9223372036854775807 '
assert_eq 'a live handle reads, advancing the generation and the read count' \
    "$(field 23 27)" '0 10 750000000 1 1 '
assert_eq 'the retained handle is StaleClockHandle(0) and changes nothing' \
    "$(field 28 31)" '-6 0 1 1 '
assert_eq 'the system read is a separate capability call' \
    "$(field 32 35)" '0 1700000000 250000000 2 '
assert_eq 'the scripted failure is PlatformReadFailed(11) and reads no clock' \
    "$(field 36 38)" '-5 11 2 '
assert_eq 'three registrations accepted, a foreign deadline refused' \
    "$(field 39 43)" '0 0 0 -1 9 '
assert_eq 'the retained sleeper handle is StaleClockHandle(0)' \
    "$(field 44 45)" '-6 0 '
assert_eq 'nothing is due before the clock is advanced by hand' \
    "$(field 46 46)" '-1 '
assert_eq 'manual advance moves monotonic time and nothing else' \
    "$(field 47 49)" '0 11 750000000 '
assert_eq 'equal deadlines wake in registration order, one per poll' \
    "$(field 50 53)" '0 1 -1 2 '
assert_eq 'cancellation is accepted and the waiter stays cancelled' \
    "$(field 54 55)" '0 3 '
assert_eq 'the handle that cancelled is spent, and refusing it changes nothing' \
    "$(field 56 58)" '-6 7 3 '
assert_eq 'advancing past a cancelled deadline wakes nobody' \
    "$(field 59 61)" '13 -1 2 '
assert_eq 'WaiterCancelled carries the waiter it cancelled' \
    "$(field 62 63)" '-4 2 '
assert_eq 'cancelling an already woken waiter is refused, not repeated' \
    "$(field 64 65)" '-7 0 '
assert_eq 'every reading in the run came from the fake clock' \
    "$(field 66 66)" '2 '

lines=$(wc -l <"$expected" | tr -d ' ')
assert_num 'recorded decisions cover the whole golden' "$lines" -eq 66

# --------------------------------------------------------- mixing is a bug
#
# These are rejected during lowering rather than by `check`; see README.md.
# The gate asserts the rejection and its reason, and nothing more.

expect_rejected() {
    stem=$1
    reason=$2

    # `check` must be enough. #848 asks for a compile-time error rather than a
    # convention, and a mistake caught only once the backend runs is a weaker
    # promise than one the frontend refuses.
    if "$ROOT/bin/kofun" check "$CASES/$stem.kofun" \
        >"$WORK/$stem.check.stdout" 2>"$WORK/$stem.check.stderr"
    then
        fail "$stem passed \`kofun check\`; the separate clock types did not stop it"
    fi
    require_line "$WORK/$stem.check.stderr" "$reason" \
        "$stem was rejected by check for the wrong reason"

    # And the whole toolchain must agree, so no later stage can accept what the
    # frontend refused.
    if "$ROOT/bin/kofun" build "$CASES/$stem.kofun" -o "$WORK/$stem" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    then
        fail "$stem built after check refused it"
    fi
    require_line "$WORK/$stem.stderr" "$reason" \
        "$stem was rejected by build for the wrong reason"
    assert_absent "$stem emitted a binary despite being refused" "$WORK/$stem"

    printf 'clock adapters: refused by check and build: %s\n' "$stem"
}

expect_rejected mixed_instants \
    'error[E2S32]: nominal record binding has the wrong type'
expect_rejected monotonic_epoch_field \
    'error[E2S32]: unknown nominal record field read'

printf 'clock identities, ordering, and typed errors: PASS\n'
printf 'affine clock handle and explicit capability passing: PASS\n'
printf 'deterministic fake clock, stable waiter order, cancellation: PASS\n'
printf 'reference executor and C11 backend agree, with no host time: PASS\n'

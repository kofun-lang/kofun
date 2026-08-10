#!/bin/sh
# Gate for the kotest unit-test framework, its runner, and the executable
# stdlib samples.  Unlike the projection gates, every assertion here is
# about sources that actually compile and run: the framework library, the
# Go-style sample/test companions under examples/stdlib/, and the runner's
# failure and filter behaviour.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
RUNNER="$ROOT/tooling/kotest/run.sh"
KOTEST_LIB="$ROOT/stdlib/testing/kotest.kofun"
SAMPLES="$ROOT/examples/stdlib"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-kotest-gate.XXXXXX")
watch_pid=''

stop_watch() {
    [ -n "$watch_pid" ] || return 0
    if kill -0 "$watch_pid" 2>/dev/null; then
        kill "$watch_pid" 2>/dev/null || :
        sleep 1
        kill -KILL "$watch_pid" 2>/dev/null || :
    fi
    wait "$watch_pid" 2>/dev/null || :
    watch_pid=''
}

cleanup() {
    status=$?
    trap - 0 1 2 15
    stop_watch
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup 0 1 2 15

fail() {
    printf 'kotest gate: FAIL: %s\n' "$*" >&2
    exit 1
}

test -f "$RUNNER" || fail 'runner tooling/kotest/run.sh is missing'
test -f "$KOTEST_LIB" || fail 'framework stdlib/testing/kotest.kofun is missing'

if find "$ROOT/tooling/kotest" "$SAMPLES" -type f \
    \( -name '*.py' -o -name '*.kf' \) | grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

# ---------------------------------------------------------------- framework
# The framework must contain no trusted declarations and no main of its own.
grep -q 'trusted' "$KOTEST_LIB" && fail 'kotest.kofun contains a trusted declaration'
grep -q '^fn main(' "$KOTEST_LIB" && fail 'kotest.kofun must not define fn main'
for assertion in \
    expect_eq_int expect_ne_int expect_lt_int expect_le_int expect_gt_int \
    expect_ge_int expect_between_int expect_that_int expect_eq_text \
    expect_ne_text expect_text_len expect_text_starts_with \
    expect_text_contains fail_now assert_equals_int assert_equals_text \
    spy_init spy_record spy_count spy_last verify_called_times \
    verify_last_argument stub_unreachable kotest_summary kotest_selfcheck
do
    grep -q "^fn $assertion(" "$KOTEST_LIB" ||
        fail "framework function is missing: $assertion"
done

# ------------------------------------------------- samples: every module
# Each stdlib sample is a Go-style companion pair: X_sample.kofun runs on
# its own (the examples gate owns the golden), X_sample_test.kofun is the
# kotest suite over the same functions.  This gate owns exactly these
# suites (examples/README.md binds each row here by name):
#   array_sample_test.kofun        binary_heap_sample_test.kofun
#   clock_sample_test.kofun        csv_sample_test.kofun
#   date_time_sample_test.kofun    decimal_sample_test.kofun
#   json_sample_test.kofun         list_sample_test.kofun
#   logging_sample_test.kofun      map_sample_test.kofun
#   random_sample_test.kofun       regex_sample_test.kofun
#   set_sample_test.kofun          testing_sample_test.kofun
#   toml_sample_test.kofun         tuple_sample_test.kofun
#   vector_sample_test.kofun
modules='array binary_heap clock csv date_time decimal json list logging
map random regex set testing toml tuple vector'
for module in $modules; do
    test -f "$SAMPLES/${module}_sample.kofun" ||
        fail "missing sample: ${module}_sample.kofun"
    test -f "$SAMPLES/${module}_sample_test.kofun" ||
        fail "missing suite: ${module}_sample_test.kofun"
    test -f "$SAMPLES/${module}_sample.expected" ||
        fail "missing golden: ${module}_sample.expected"
    grep -q '^fn test_' "$SAMPLES/${module}_sample_test.kofun" ||
        fail "suite has no tests: ${module}_sample_test.kofun"
done

# ---------------------------------------------------------- passing sweep
# The full suite must pass: samples plus the framework's own suite.
if ! sh "$RUNNER" "$SAMPLES" "$ROOT/stdlib/testing" --no-color \
    >"$WORK/pass.out" 2>"$WORK/pass.err"; then
    cat "$WORK/pass.out" "$WORK/pass.err" >&2
    fail 'passing sweep exited nonzero'
fi
grep -q 'KOTEST-ASSERT-FAIL kotest' "$WORK/pass.out" &&
    fail 'framework selfcheck failed inside the passing sweep'
grep -Eq 'Tests  [0-9]+ passed \([0-9]+ total, [0-9]+ suites\)' "$WORK/pass.out" ||
    fail 'passing sweep did not print the green summary'
grep -q '✗' "$WORK/pass.out" && fail 'passing sweep contains a failed test'
escape=$(printf '\033')
if grep -q "$escape" "$WORK/pass.out" "$WORK/pass.err"; then
    fail '--no-color output contains an ANSI escape byte'
fi
total=$(sed -n 's/^Tests  \([0-9][0-9]*\) passed.*/\1/p' "$WORK/pass.out")
test "$total" -ge 100 ||
    fail "passing sweep ran only $total tests; the samples are not all wired"

# --------------------------------------------------------- failing fixture
# The deliberately failing suite must exit 1 and name its failures; a
# harness that swallows red is worse than no harness.
set +e
sh "$RUNNER" "$ROOT/tests/stdlib/kotest/fixtures/failing_test.kofun" \
    --no-color >"$WORK/red.out" 2>"$WORK/red.err"
red_status=$?
set -e
test "$red_status" -eq 1 ||
    fail "failing fixture exited $red_status instead of 1"
grep -q '✗ failing_test.test_equality_that_fails' "$WORK/red.out" ||
    fail 'failing fixture did not mark the failed test'
grep -q 'KOTEST-ASSERT-FAIL expect_eq_int' "$WORK/red.out" ||
    fail 'failing fixture lost the assertion diagnostic'
grep -q '✓ failing_test.test_that_passes_beside_failures' "$WORK/red.out" ||
    fail 'failing fixture did not keep running after a failure'
grep -q 'Tests  2 failed | 1 passed (3 total, 1 suites)' "$WORK/red.out" ||
    fail 'failing fixture summary is wrong'

# ------------------------------------------------- build-failure coordinates
# A build diagnostic must point into the file the author wrote (#1129). The
# unit is the kotest library, the companion, and the suite concatenated, so an
# untranslated offset lands roughly a library's length past the defect and
# moves whenever the library is edited.
#
# The expected offset is computed from the fixture here rather than written
# down, so the assertion cannot go stale against an edited fixture, and it is
# compared against what the compiler reports for the companion on its own —
# which is the whole claim: through kotest, the same defect gets the same
# coordinate as outside it.
OFFSETS_COMPANION="$ROOT/tests/stdlib/kotest/fixtures/offsets.kofun"
expected_offset=$(LC_ALL=C awk '
    # Anchored to an indented statement, so prose in the header comment of
    # the fixture cannot be mistaken for the construct.
    /^[[:space:]]+for / { print pos + index($0, "for ") - 1; exit }
    { pos += length($0) + 1 }
' "$OFFSETS_COMPANION")
test -n "$expected_offset" ||
    fail 'offsets fixture no longer contains the marker construct'

set +e
sh "$RUNNER" "$ROOT/tests/stdlib/kotest/fixtures/offsets_test.kofun" \
    --no-color >"$WORK/offsets.out" 2>&1
offsets_status=$?
set -e
test "$offsets_status" -eq 2 ||
    fail "offsets fixture exited $offsets_status instead of 2 (build failure)"
grep -q 'kotest: BUILD FAIL' "$WORK/offsets.out" ||
    fail 'offsets fixture did not report a build failure'
grep -q "fixtures/offsets.kofun byte $expected_offset" "$WORK/offsets.out" ||
    fail "build diagnostic did not name offsets.kofun byte $expected_offset
$(sed 's/^/    /' "$WORK/offsets.out")"

# The defect is in the companion, so the suite must not be blamed for it.
grep -q "offsets_test.kofun byte" "$WORK/offsets.out" &&
    fail 'build diagnostic attributed the companion defect to the suite'

# And the raw unit offset must not be what the reader is sent to.
grep -Eq 'statement at byte [0-9]+' "$WORK/offsets.out" &&
    fail 'build diagnostic still reports a bare unit offset'

# ------------------------------------------------------------------ filter
sh "$RUNNER" "$SAMPLES/list_sample_test.kofun" --filter test_fold \
    --no-color >"$WORK/filter.out" 2>&1 ||
    fail 'filtered run exited nonzero'
grep -q 'Tests  1 passed (1 total, 1 suites)' "$WORK/filter.out" ||
    fail '--filter did not narrow to one test'

# -------------------------------------------------------------------- list
sh "$RUNNER" "$SAMPLES/list_sample_test.kofun" --list \
    >"$WORK/list.out" 2>&1 || fail '--list exited nonzero'
grep -q 'list_sample_test.test_push_appends_in_order' "$WORK/list.out" ||
    fail '--list did not enumerate tests'

# -------------------------------------------------------------- keep-going
# A compiler error in the first suite must not prevent the later suite from
# running when --keep-going is set.  The overall command still has to fail.
mkdir -p "$WORK/keep-going"
cat >"$WORK/keep-going/a_broken_test.kofun" <<'KOFUN'
fn test_build_failure() -> Int {
    return function_that_does_not_exist()
}
KOFUN
cat >"$WORK/keep-going/z_after_test.kofun" <<'KOFUN'
fn test_after_build_failure() -> Int {
    return expect_eq_int(1, 1)
}
KOFUN

# The default is fail-fast for build failures: prove the later suite is not
# reached before proving that --keep-going changes that behavior.
set +e
sh "$RUNNER" "$WORK/keep-going" --no-color \
    >"$WORK/fail-fast.out" 2>"$WORK/fail-fast.err"
fail_fast_status=$?
set -e
test "$fail_fast_status" -ne 0 ||
    fail 'default build-failure handling exited zero'
grep -q 'kotest: BUILD FAIL .*a_broken_test.kofun' "$WORK/fail-fast.out" ||
    fail 'default build-failure handling lost the compiler failure'
if grep -q 'z_after_test.test_after_build_failure' "$WORK/fail-fast.out"; then
    fail 'default build-failure handling ran the later suite'
fi

set +e
sh "$RUNNER" "$WORK/keep-going" --keep-going --no-color \
    >"$WORK/keep-going.out" 2>"$WORK/keep-going.err"
keep_status=$?
set -e
test "$keep_status" -ne 0 ||
    fail '--keep-going hid the earlier build failure'
grep -q 'kotest: BUILD FAIL .*a_broken_test.kofun' "$WORK/keep-going.out" ||
    fail '--keep-going did not report the earlier build failure'
grep -q '✓ z_after_test.test_after_build_failure' "$WORK/keep-going.out" ||
    fail '--keep-going did not run the later valid suite'

# ------------------------------------------------------------------- watch
# Watch mode must complete one run, observe a source change, and complete a
# second run.  Repeated bounded writes avoid racing the watch stamp; cleanup
# always reaps the background runner, with SIGKILL only as a final fallback.
mkdir -p "$WORK/watch" "$WORK/watch-tmp"
cat >"$WORK/watch/z_watch_test.kofun" <<'KOFUN'
fn test_watch_rerun() -> Int {
    return expect_eq_int(1, 1)
}
KOFUN

exercise_watch() {
    watch_mode=$1
    watch_out="$WORK/watch-$watch_mode.out"
    watch_err="$WORK/watch-$watch_mode.err"
    if [ "$watch_mode" = no-color ]; then
        TMPDIR="$WORK/watch-tmp" sh "$RUNNER" "$WORK/watch" \
            --watch --no-color >"$watch_out" 2>"$watch_err" &
    else
        TMPDIR="$WORK/watch-tmp" sh "$RUNNER" "$WORK/watch" \
            --watch >"$watch_out" 2>"$watch_err" &
    fi
    watch_pid=$!

    watch_runs() {
        awk '/^Tests  / { count += 1 } END { print count + 0 }' "$watch_out"
    }

    attempt=0
    while [ "$(watch_runs)" -lt 1 ] && [ "$attempt" -lt 20 ]; do
        kill -0 "$watch_pid" 2>/dev/null || {
            cat "$watch_out" "$watch_err" >&2
            fail "--watch $watch_mode exited before its initial run"
        }
        sleep 1
        attempt=$((attempt + 1))
    done
    test "$(watch_runs)" -ge 1 || {
        cat "$watch_out" "$watch_err" >&2
        fail "--watch $watch_mode initial run timed out"
    }

    attempt=0
    while [ "$(watch_runs)" -lt 2 ] && [ "$attempt" -lt 20 ]; do
        printf '\n' >>"$WORK/watch/z_watch_test.kofun"
        sleep 1
        attempt=$((attempt + 1))
    done
    test "$(watch_runs)" -ge 2 || {
        cat "$watch_out" "$watch_err" >&2
        fail "--watch $watch_mode did not rerun after a source change"
    }
    stop_watch
    if grep -q "$escape" "$watch_out" "$watch_err"; then
        fail "--watch $watch_mode output contains an ANSI escape byte"
    fi
    watch_summaries=$(grep -c '^Tests  1 passed (1 total, 1 suites)$' \
        "$watch_out" || :)
    test "$watch_summaries" -ge 2 || {
        cat "$watch_out" "$watch_err" >&2
        fail "--watch $watch_mode did not complete two successful runs"
    }
    watch_green=$(grep -c '✓ z_watch_test.test_watch_rerun' \
        "$watch_out" || :)
    test "$watch_green" -ge 2 || {
        cat "$watch_out" "$watch_err" >&2
        fail "--watch $watch_mode did not report the fixture green twice"
    }
    if grep -Eq '✗|BUILD FAIL|KOTEST-FAILED' "$watch_out"; then
        fail "--watch $watch_mode output contains a failed run"
    fi
    if [ -s "$watch_err" ]; then
        cat "$watch_err" >&2
        fail "--watch $watch_mode emitted unexpected stderr"
    fi
}

exercise_watch no-color
exercise_watch redirected-auto

printf 'kotest framework and runner behaviour: PASS\n'
printf 'kotest failing-suite detection and exit codes: PASS\n'
printf 'kotest no-color, keep-going, and watch options: PASS\n'
printf 'kotest stdlib sample suites (%s tests): PASS\n' "$total"

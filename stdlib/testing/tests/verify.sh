#!/bin/sh
set -eu

testing_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$testing_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-testing-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'testing checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$testing_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$testing_dir/testing.kofun"
for declaration in \
    'type AssertionFailure =' \
    '| ExpectedTrue(Text)' \
    '| ExpectedFalse(Text)' \
    '| IntNotEqual(Text, Int, Int)' \
    '| BoolNotEqual(Text, Bool, Bool)' \
    '| TextNotEqual(Text, Text, Text)' \
    'type TestResult =' \
    'type TestSummary = {' \
    'fn expect_true(' \
    'fn expect_false(' \
    'fn expect_equal_int(' \
    'fn expect_equal_bool(' \
    'fn expect_equal_text(' \
    'fn test_passed(' \
    'fn test_failed(' \
    'fn test_summary_add(' \
    'fn test_summarize(' \
    'fn test_exit_code('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for behavior in \
    'return TestFailed(ExpectedTrue(name))' \
    'return TestFailed(ExpectedFalse(name))' \
    'return TestFailed(IntNotEqual(name, expected, actual))' \
    'return TestFailed(BoolNotEqual(name, expected, actual))' \
    'return TestFailed(TextNotEqual(name, expected, actual))' \
    'passed: summary.passed + 1' \
    'failed: summary.failed + 1' \
    'if summary.failed == 0'
do
    grep -Fq "$behavior" "$source_file" ||
        fail "missing canonical behavior: $behavior"
done

# The result API is pure: assertion and summary functions do not report or
# terminate the process themselves.
if grep -Eq '(^|[^a-z_])(print|exit|clock|random)\(' "$source_file"
then
    fail 'canonical testing API contains a reporting or nondeterministic effect'
fi

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -eq 1 ] ||
    fail 'canonical ADT source unexpectedly claimed executable codegen'
[ ! -s "$work/canonical.check.stdout" ] ||
    fail 'canonical ADT refusal unexpectedly wrote stdout'
printf '%s\n' \
    'error[E2S157]: Stage 2 function list signatures require exactly List[Int] at byte 2328' |
    cmp - "$work/canonical.check.stderr" ||
    fail 'canonical ADT source did not expose the documented list boundary'

checkpoint="$testing_dir/tests/checkpoint.kofun"
expected="$testing_dir/tests/checkpoint.stdout"

"$repo_dir/bin/kofun" build "$checkpoint" \
    -o "$work/checkpoint-c11" \
    --emit-c "$work/checkpoint.c" >/dev/null
"$work/checkpoint-c11" >"$work/checkpoint-c11.stdout"
cmp "$expected" "$work/checkpoint-c11.stdout" ||
    fail 'C11 checkpoint output differs'

"$repo_dir/bin/kofun" build "$checkpoint" \
    --target x86_64-linux \
    -o "$work/checkpoint-native" >/dev/null
"$work/checkpoint-native" >"$work/checkpoint-native.stdout"
cmp "$expected" "$work/checkpoint-native.stdout" ||
    fail 'direct x86-64 checkpoint output differs'
cmp "$work/checkpoint-c11.stdout" "$work/checkpoint-native.stdout" ||
    fail 'C11 and direct x86-64 results differ'

printf 'testing value-result API contract: PASS\n'
printf 'testing pass and failure paths: PASS\n'
printf 'testing deterministic C11/x86-64 differential: PASS\n'

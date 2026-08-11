#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RUNNER="$ROOT/tests/fuzz/run-scheduled.sh"
VALIDATOR="$ROOT/tests/fuzz/findings.mjs"
MANIFEST="$ROOT/tests/fuzz/scheduled-generators.tsv"
mkdir -p "$ROOT/build"
WORK=$(mktemp -d "$ROOT/build/scheduled-fuzz-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
    printf '%s\n' "FAIL: scheduled fuzz check: $*" >&2
    exit 1
}

node --check "$VALIDATOR"
node "$VALIDATOR" schema
node "$VALIDATOR" validate

# The manifest pins the defaults without changing them. This catches a random
# default leaking into task fuzz, while the scheduled runner always supplies a
# separate seed environment variable.
tab=$(printf '\t')
header=true
rows=0
while IFS="$tab" read -r generator seed_variable work_variable budget_variable script reuse_stage2 offset default_seed; do
    if test "$header" = true; then
        header=false
        continue
    fi
    test -n "$generator" || continue
    rows=$((rows + 1))
    grep -Fq "${seed_variable}:-$default_seed" "$ROOT/$script" ||
        fail "$script no longer has the recorded fixed default $seed_variable=$default_seed"
    grep -Fq "seed=\$" "$ROOT/$script" ||
        fail "$script no longer reports its seed"
done <"$MANIFEST"
test "$rows" -eq 9 || fail "expected 9 randomized generators, found $rows"

KOFUN_SCHEDULED_FUZZ_RUN_ID=18446744073709551615123456789012 \
KOFUN_SCHEDULED_FUZZ_OUTPUT="$WORK/plan-a" \
    sh "$RUNNER" --plan >"$WORK/plan-a.log"
KOFUN_SCHEDULED_FUZZ_RUN_ID=18446744073709551615123456789012 \
KOFUN_SCHEDULED_FUZZ_OUTPUT="$WORK/plan-b" \
    sh "$RUNNER" --plan >"$WORK/plan-b.log"
cmp "$WORK/plan-a/seeds.tsv" "$WORK/plan-b/seeds.tsv" >/dev/null ||
    fail 'one run id did not reproduce byte-identical seeds'
KOFUN_SCHEDULED_FUZZ_RUN_ID=18446744073709551615123456789013 \
KOFUN_SCHEDULED_FUZZ_OUTPUT="$WORK/plan-c" \
    sh "$RUNNER" --plan >"$WORK/plan-c.log"
cmp -s "$WORK/plan-a/seeds.tsv" "$WORK/plan-c/seeds.tsv" &&
    fail 'adjacent run ids produced the same seed plan'
awk -F '\t' 'NR > 1 && ($3 !~ /^[0-9]+$/ || $3 < 0 || $3 > 2147483647) { exit 1 }
    END { if (NR != 10) exit 1 }' "$WORK/plan-a/seeds.tsv" ||
    fail 'seed plan is incomplete or outside the 31-bit generator bound'

# Force a generator-level refusal after it prints the scheduled seed. The
# generated reproducer carries both that seed and the deliberately invalid
# budget, so running it proves the failure is not merely an orchestrator exit.
set +e
KOFUN_SCHEDULED_FUZZ_RUN_ID=1210 \
KOFUN_SCHEDULED_FUZZ_RUN_ATTEMPT=3 \
KOFUN_SCHEDULED_FUZZ_DATE=2026-08-11 \
KOFUN_SCHEDULED_FUZZ_ONLY=semantic-differential \
KOFUN_SEMANTIC_FUZZ_CASES=0 \
KOFUN_SCHEDULED_FUZZ_OUTPUT="$WORK/failure" \
    sh "$RUNNER" >"$WORK/failure.stdout" 2>"$WORK/failure.stderr"
runner_status=$?
set -e
test "$runner_status" -eq 1 || fail "forced run returned $runner_status instead of aggregate failure 1"
seed=$(awk -F '\t' 'NR == 2 { print $3 }' "$WORK/failure/seeds.tsv")
test -n "$seed" || fail 'forced run recorded no seed'
grep -Eq "seed=$seed([^0-9]|$)" "$WORK/failure/logs/semantic-differential.log" ||
    fail 'forced generator log does not name the exact seed'
node "$VALIDATOR" validate-artifact "$WORK/failure/findings.json" >/dev/null

set +e
KOFUN_REPOSITORY_ROOT="$ROOT" \
KOFUN_SCHEDULED_FUZZ_REPRO_WORK="$WORK/reproduction-work" \
    sh "$WORK/failure/reproduce-semantic-differential.sh" \
    >"$WORK/reproduction.log" 2>&1
reproduction_status=$?
set -e
test "$reproduction_status" -eq 2 ||
    fail "generated reproducer returned $reproduction_status instead of generator status 2"
grep -Eq "seed=$seed([^0-9]|$)" "$WORK/reproduction.log" ||
    fail 'generated reproducer did not run the exact recorded seed'
cmp "$WORK/failure/logs/semantic-differential.log" "$WORK/reproduction.log" >/dev/null ||
    fail 'generated reproducer did not produce the same failure output'

workflow="$ROOT/.github/workflows/scheduled-fuzz.yml"
test -f "$workflow" || fail 'scheduled workflow is missing'
grep -Fq 'schedule:' "$workflow" || fail 'workflow has no fixed schedule'
grep -Fq 'workflow_dispatch:' "$workflow" || fail 'workflow cannot be dispatched for a reproduction'
grep -Fq 'permissions:' "$workflow" && grep -Fq 'contents: read' "$workflow" ||
    fail 'workflow does not declare read-only repository permissions'
grep -Fq 'persist-credentials: false' "$workflow" ||
    fail 'workflow checkout retained write credentials'
grep -Fq 'upload-artifact@' "$workflow" || fail 'workflow does not retain failure artifacts'
grep -Fq 'GITHUB_STEP_SUMMARY' "$workflow" || fail 'workflow does not publish a run summary'
grep -Fq 'semantic_protocol_test.sh is excluded' "$workflow" ||
    fail 'workflow does not explain the non-random protocol self-test exclusion'
if grep -Eq 'contents: write|issues: write|pull-requests: write|git push|gh issue|gh pr|curl .*-X (POST|PATCH|PUT|DELETE)' "$workflow"; then
    fail 'workflow contains a remote repository mutation path'
fi

printf '%s\n' \
    'PASS: scheduled fuzz seeds rotate reproducibly, failures retain validated findings, and the generated reproducer repeats the exact failure'

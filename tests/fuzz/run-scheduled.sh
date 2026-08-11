#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MANIFEST="$ROOT/tests/fuzz/scheduled-generators.tsv"
FINDINGS="$ROOT/tests/fuzz/findings.mjs"
OUTPUT=${KOFUN_SCHEDULED_FUZZ_OUTPUT:-"$ROOT/build/scheduled-fuzz"}
RUN_ID=${KOFUN_SCHEDULED_FUZZ_RUN_ID:-}
RUN_ATTEMPT=${KOFUN_SCHEDULED_FUZZ_RUN_ATTEMPT:-1}
RUN_DATE=${KOFUN_SCHEDULED_FUZZ_DATE:-$(date -u +%F)}
ONLY=${KOFUN_SCHEDULED_FUZZ_ONLY:-}
PLAN=false

fail() {
    printf '%s\n' "scheduled fuzz: $*" >&2
    exit 2
}

case ${1-} in
    '') ;;
    --plan) PLAN=true ;;
    *) fail 'usage: run-scheduled.sh [--plan]' ;;
esac
test "$#" -le 1 || fail 'usage: run-scheduled.sh [--plan]'

case $RUN_ID in
    ''|*[!0-9]*) fail 'KOFUN_SCHEDULED_FUZZ_RUN_ID must be a non-negative decimal integer' ;;
esac
test "${#RUN_ID}" -le 32 || fail 'KOFUN_SCHEDULED_FUZZ_RUN_ID must be at most 32 digits'
case $RUN_ATTEMPT in
    ''|*[!0-9]*|0) fail 'KOFUN_SCHEDULED_FUZZ_RUN_ATTEMPT must be a positive decimal integer' ;;
esac
case $RUN_DATE in
    ????-??-??) ;;
    *) fail 'KOFUN_SCHEDULED_FUZZ_DATE must be YYYY-MM-DD' ;;
esac
node -e 'const value = process.argv[1]; const date = new Date(`${value}T00:00:00Z`); if (Number.isNaN(date.valueOf()) || date.toISOString().slice(0, 10) !== value) process.exit(1)' \
    "$RUN_DATE" || fail 'KOFUN_SCHEDULED_FUZZ_DATE must be a calendar date'
case $ONLY in
    ''|*[!a-z0-9-]*) test -z "$ONLY" || fail 'KOFUN_SCHEDULED_FUZZ_ONLY is not a generator name' ;;
esac

test -f "$MANIFEST" || fail "missing generator manifest: $MANIFEST"
test ! -e "$OUTPUT" || fail "output already exists: $OUTPUT"
mkdir -p "$(dirname -- "$OUTPUT")"
mkdir "$OUTPUT"

# BigInt keeps the mapping exact after GitHub's run counter outgrows a shell
# integer or JavaScript's ordinary Number range.
base_seed=$(node -e \
    'process.stdout.write(String(BigInt(process.argv[1]) % 2147483648n))' \
    "$RUN_ID")

printf 'generator\tseed_variable\tseed\n' >"$OUTPUT/seeds.tsv"
printf '%s\n' "scheduled fuzz: run_id=$RUN_ID attempt=$RUN_ATTEMPT base_seed=$base_seed"
printf '%s\n' \
    'scheduled fuzz: semantic_protocol_test.sh excluded: it is a deterministic negative/replay protocol self-test with no PRNG; task fuzz still runs it'

if test "$PLAN" = false; then
    mkdir "$OUTPUT/logs" "$OUTPUT/work"
    node "$FINDINGS" init "$OUTPUT/findings.json"
    {
        printf '# Scheduled fuzz run %s (attempt %s)\n\n' "$RUN_ID" "$RUN_ATTEMPT"
        printf -- '- Date (UTC): `%s`\n' "$RUN_DATE"
        printf -- '- Base seed: `%s`\n' "$base_seed"
        printf -- '- `semantic_protocol_test.sh` is excluded because it is a deterministic negative/replay protocol self-test with no PRNG; the normal `task fuzz` gate still runs it.\n\n'
        printf '| Generator | Seed | Result | Evidence | Reproducer |\n'
        printf '| --- | ---: | --- | --- | --- |\n'
    } >"$OUTPUT/summary.md"
fi

tab=$(printf '\t')
header=true
selected=0
failures=0
shared_stage2=
while IFS="$tab" read -r generator seed_variable work_variable budget_variable script reuse_stage2 offset default_seed; do
    if test "$header" = true; then
        header=false
        test "$generator" = generator && test "$seed_variable" = seed_variable ||
            fail 'generator manifest header is invalid'
        continue
    fi
    test -n "$generator" || continue
    case $generator in *[!a-z0-9-]*) fail "invalid generator name: $generator" ;; esac
    case $seed_variable:$work_variable:$budget_variable in
        *[!A-Z0-9_:]*) fail "invalid environment variable in $generator row" ;;
    esac
    case $offset:$default_seed in
        *[!0-9:]*) fail "invalid numeric field in $generator row" ;;
    esac
    case $reuse_stage2 in yes|no) ;; *) fail "invalid reuse_stage2 value in $generator row" ;; esac
    test -f "$ROOT/$script" || fail "$generator names missing script $script"
    if test -n "$ONLY" && test "$generator" != "$ONLY"; then
        continue
    fi
    selected=$((selected + 1))
    seed=$(((base_seed + offset * 104729) % 2147483648))
    printf '%s\t%s\t%s\n' "$generator" "$seed_variable" "$seed" >>"$OUTPUT/seeds.tsv"
    printf '%s\n' "scheduled fuzz: generator=$generator seed=$seed"
    test "$PLAN" = false || continue

    log="$OUTPUT/logs/$generator.log"
    generator_work="$OUTPUT/work/$generator"
    set +e
    if test "$reuse_stage2" = yes && test -n "$shared_stage2"; then
        env KOFUN_STAGE2_COMPILER="$shared_stage2" \
            "$seed_variable=$seed" "$work_variable=$generator_work" \
            sh "$ROOT/$script" >"$log" 2>&1
    else
        env "$seed_variable=$seed" "$work_variable=$generator_work" \
            sh "$ROOT/$script" >"$log" 2>&1
    fi
    status=$?
    set -e
    cat "$log"

    # Let the first successful consumer build through its normal, fully logged
    # path. Later consumers copy that exact Stage 2 binary through the existing
    # KOFUN_STAGE2_COMPILER contract, avoiding five redundant -O2 compiles.
    if test "$status" -eq 0 && test "$reuse_stage2" = yes &&
        test -z "$shared_stage2" && test -x "$generator_work/kofun-stage2"
    then
        mkdir "$OUTPUT/tooling"
        shared_stage2="$OUTPUT/tooling/kofun-stage2"
        cp "$generator_work/kofun-stage2" "$shared_stage2"
    fi

    failure_kind=
    if test "$status" -ne 0; then
        failure_kind=generator-exit
    elif ! grep -Eq "seed=$seed([^0-9]|$)" "$log"; then
        failure_kind=seed-report-missing
        status=1
        message="scheduled fuzz: $generator exited successfully without reporting seed=$seed"
        printf '%s\n' "$message" >>"$log"
        printf '%s\n' "$message" >&2
    fi

    if test -z "$failure_kind"; then
        printf '| `%s` | `%s` | pass | [`logs/%s.log`](logs/%s.log) | — |\n' \
            "$generator" "$seed" "$generator" "$generator" >>"$OUTPUT/summary.md"
        continue
    fi

    failures=$((failures + 1))
    reproducer="$OUTPUT/reproduce-$generator.sh"
    budget_value=$(printenv "$budget_variable" 2>/dev/null || :)
    case $budget_value in *[!0-9]*) fail "$budget_variable must be numeric when set" ;; esac
    {
        printf '%s\n' '#!/bin/sh' 'set -eu'
        printf '%s\n' 'ROOT=${KOFUN_REPOSITORY_ROOT:-$(pwd)}'
        printf 'if test ! -f "$ROOT/%s"; then\n' "$script"
        printf '%s\n' \
            "    printf '%s\n' 'run this reproducer from a Kofun checkout, or set KOFUN_REPOSITORY_ROOT' >&2" \
            '    exit 2' \
            'fi'
        printf '%s\n' "REPRO_WORK=\${KOFUN_SCHEDULED_FUZZ_REPRO_WORK:-\"\$ROOT/build/scheduled-fuzz-reproduction/$generator\"}"
        if test -n "$budget_value"; then
            printf 'exec env %s=%s %s="$REPRO_WORK" %s=%s sh "$ROOT/%s"\n' \
                "$seed_variable" "$seed" "$work_variable" "$budget_variable" "$budget_value" "$script"
        else
            printf 'exec env %s=%s %s="$REPRO_WORK" sh "$ROOT/%s"\n' \
                "$seed_variable" "$seed" "$work_variable" "$script"
        fi
    } >"$reproducer"
    chmod +x "$reproducer"

    reproduction="$seed_variable=$seed"
    if test -n "$budget_value"; then
        reproduction="$reproduction $budget_variable=$budget_value"
    fi
    reproduction="$reproduction sh $script"
    node "$FINDINGS" record "$OUTPUT/findings.json" \
        "$RUN_DATE" "$generator" "$seed" "$RUN_ID" "$RUN_ATTEMPT" \
        "$status" "$failure_kind" "$reproduction" "logs/$generator.log"
    printf '| `%s` | `%s` | **fail (%s)** | [`logs/%s.log`](logs/%s.log) | [`reproduce-%s.sh`](reproduce-%s.sh) |\n' \
        "$generator" "$seed" "$status" "$generator" "$generator" \
        "$generator" "$generator" >>"$OUTPUT/summary.md"
done <"$MANIFEST"

test "$selected" -gt 0 || fail "no generator matched KOFUN_SCHEDULED_FUZZ_ONLY=$ONLY"
test "$PLAN" = false || exit 0

node "$FINDINGS" validate-artifact "$OUTPUT/findings.json"
if test "$failures" -ne 0; then
    printf '%s\n' \
        "scheduled fuzz: $failures generator(s) failed; evidence: $OUTPUT" >&2
    exit 1
fi
printf '%s\n' "PASS: scheduled fuzz ran $selected generators with run-derived seeds"

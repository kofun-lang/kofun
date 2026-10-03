#!/bin/sh
# The bidirectional shard ledger (#1684).
#
# `task verify` runs one declared task set. Sharding runs that set on several
# runners, and the only thing that keeps sharding from becoming the "passes
# because it could not look" failure this repository refuses everywhere is a
# ledger that fails in BOTH directions:
#
#   * a task `verify` runs that no shard names is an unrun gate;
#   * a shard task that `verify` does not run is a task the ledger invented;
#   * a task in two shards ran twice.
#
# The basis is the verify task list as `tests/pair-coverage/measure.sh
# --print-verify-tasks` states it, which is the same extraction `check_drivers`
# compares `drivers.tsv` against. Reading it through that entry point rather
# than re-parsing `Taskfile.yml` here is deliberate: a second parser would
# prove the second parser, and the two would drift the first time the verify
# block changed shape.
#
# The partition itself is committed as `partition.tsv`, one `task<TAB>shard`
# row per declared task. It is derived from `timings.tsv` (the per-task wall
# time a measured run records) by `partition.mjs`, so the balance is justified
# by a measurement rather than by task name. This file enforces coverage; the
# generator owns the balance.
#
# Usage:
#   sh tests/verify-shards/check.sh [PARTITION]
#   sh tests/verify-shards/check.sh --prove      # mutations must be refused
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
HERE=$ROOT/tests/verify-shards
PARTITION=${KOFUN_VERIFY_SHARDS_PARTITION:-$HERE/partition.tsv}

if test "${1:-}" = "--prove"; then
    exec sh "$HERE/self-test.sh"
fi
test "$#" -le 1 || {
    printf '%s\n' 'usage: check.sh [PARTITION]' >&2
    exit 2
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-verify-shards.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

sh "$ROOT/tests/pair-coverage/measure.sh" --print-verify-tasks \
    >"$WORK/verify-tasks.txt" || {
    printf '%s\n' 'FAIL: verify shards: the verify task list could not be read' >&2
    exit 1
}
test -s "$WORK/verify-tasks.txt" || {
    printf '%s\n' 'FAIL: verify shards: the verify task list is empty' >&2
    exit 1
}

test -f "$PARTITION" || {
    printf 'FAIL: verify shards: missing %s\n' "$PARTITION" >&2
    exit 1
}

# Parse and validate shape. A rowwith the wrong number of fields is refused
# rather than skipped: a skipped row would read as a covered task.
stable_rows=$WORK/partition.txt
row_number=0
shard_count=0
: >"$stable_rows"
while IFS= read -r row; do
    row_number=$((row_number + 1))
    test -n "$row" || continue
    case $row in
        \#*) continue ;;
    esac
    fields=$(printf '%s' "$row" | awk -F '\t' '{print NF}')
    if test "$fields" -ne 2; then
        printf 'FAIL: verify shards: %s line %s has %s tab-separated fields, expected 2 (task<TAB>shard)\n' \
            "$PARTITION" "$row_number" "$fields" >&2
        exit 1
    fi
    task=$(printf '%s' "$row" | cut -f1)
    shard=$(printf '%s' "$row" | cut -f2)
    case $task in
        '') printf 'FAIL: verify shards: %s line %s has an empty task\n' \
                "$PARTITION" "$row_number" >&2
            exit 1 ;;
    esac
    case $shard in
        *[!0-9]*|'')
            printf 'FAIL: verify shards: %s line %s has a non-numeric shard `%s`\n' \
                "$PARTITION" "$row_number" "$shard" >&2
            exit 1 ;;
    esac
    printf '%s\t%s\n' "$task" "$shard" >>"$stable_rows"
    test "$shard" -ge "$shard_count" && shard_count=$((shard + 1))
done <"$PARTITION"

test "$shard_count" -gt 0 || {
    printf 'FAIL: verify shards: %s names no shards\n' "$PARTITION" >&2
    exit 1
}

# Every shard 0..N-1 is present. A gap would make `verify-shard i` silently run
# an empty lane, which reads as a shard that passed.
i=0
while test "$i" -lt "$shard_count"; do
    if ! cut -f2 "$stable_rows" | grep -qx "$i"; then
        printf 'FAIL: verify shards: shard %s is empty; shards must be contiguous 0..%s\n' \
            "$i" "$((shard_count - 1))" >&2
        exit 1
    fi
    i=$((i + 1))
done

cut -f1 "$stable_rows" | sort >"$WORK/partition-tasks.txt"
sort "$WORK/verify-tasks.txt" >"$WORK/verify-sorted.txt"

fail=0

in_no_shard=$(comm -23 "$WORK/verify-sorted.txt" "$WORK/partition-tasks.txt")
if test -n "$in_no_shard"; then
    printf '%s\n' 'FAIL: verify shards: verify runs these tasks and no shard names them:' >&2
    printf '%s\n' "$in_no_shard" | sed 's/^/  /' >&2
    fail=1
fi

not_in_verify=$(comm -13 "$WORK/verify-sorted.txt" "$WORK/partition-tasks.txt")
if test -n "$not_in_verify"; then
    printf '%s\n' 'FAIL: verify shards: these shard tasks are not in the verify set:' >&2
    printf '%s\n' "$not_in_verify" | sed 's/^/  /' >&2
    fail=1
fi

duplicated=$(cut -f1 "$stable_rows" | sort | uniq -d)
if test -n "$duplicated"; then
    printf '%s\n' 'FAIL: verify shards: these tasks are named by more than one shard:' >&2
    printf '%s\n' "$duplicated" | sed 's/^/  /' >&2
    fail=1
fi

test "$fail" -eq 0 || exit 1

declared=$(wc -l <"$WORK/verify-sorted.txt" | tr -d ' ')
printf 'PASS: verify shards: %s of %s verify tasks are each named by exactly one shard across %s shards\n' \
    "$(wc -l <"$WORK/partition-tasks.txt" | tr -d ' ')" "$declared" "$shard_count"

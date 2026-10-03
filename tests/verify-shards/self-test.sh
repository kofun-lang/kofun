#!/bin/sh
# Negative self-tests for the shard ledger (#1684).
#
# `check.sh` fails in both directions, and a checker that quietly stopped
# refusing would keep reporting PASS on an honest partition. This drives the
# checker with a mutated partition per rule and requires each to be refused.
#
# It is reached by `sh tests/verify-shards/check.sh --prove`, so the negative
# path is one command rather than a paragraph a reader has to trust.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
HERE=$ROOT/tests/verify-shards

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-verify-shards-prove.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

data_rows=$WORK/base.txt
grep -v '^#' "$HERE/partition.tsv" | grep -v '^[[:space:]]*$' >"$data_rows"

test -s "$data_rows" || {
    printf '%s\n' 'FAIL: verify shards self-test: partition.tsv holds no rows' >&2
    exit 1
}

failed=0

expect_refused() {
    er_name=$1
    er_mutant=$2
    if KOFUN_VERIFY_SHARDS_PARTITION="$er_mutant" \
        sh "$HERE/check.sh" >"$WORK/$er_name.out" 2>"$WORK/$er_name.err"
    then
        printf 'FAIL: verify shards self-test: mutation `%s` was accepted\n' "$er_name" >&2
        sed 's/^/  /' "$WORK/$er_name.out" >&2
        failed=1
    else
        printf 'PASS: verify shards self-test: mutation `%s` refused\n' "$er_name"
    fi
}

expect_accepted() {
    ea_name=$1
    ea_partition=$2
    if KOFUN_VERIFY_SHARDS_PARTITION="$ea_partition" \
        sh "$HERE/check.sh" >"$WORK/$ea_name.out" 2>"$WORK/$ea_name.err"
    then
        printf 'PASS: verify shards self-test: %s accepted\n' "$ea_name"
    else
        printf 'FAIL: verify shards self-test: %s was refused\n' "$ea_name" >&2
        sed 's/^/  /' "$WORK/$ea_name.err" >&2
        failed=1
    fi
}

# The honest partition is accepted, so the mutations below are read against a
# checker that looked at the tree rather than one that refuses everything.
expect_accepted 'the committed partition' "$HERE/partition.tsv"

# A verify task in no shard: drop the first data row.
tail -n +2 "$data_rows" >"$WORK/dropped.tsv"
expect_refused 'a dropped task' "$WORK/dropped.tsv"

# A shard task the verify set does not declare.
cp "$data_rows" "$WORK/extra.tsv"
printf 'not-a-verify-task\t0\n' >>"$WORK/extra.tsv"
expect_refused 'an undeclared shard task' "$WORK/extra.tsv"

# A task in two shards: mirror the first row under a different shard.
cp "$data_rows" "$WORK/dup.tsv"
first_task=$(head -n1 "$data_rows" | cut -f1)
first_shard=$(head -n1 "$data_rows" | cut -f2)
printf '%s\t%s\n' "$first_task" "$((first_shard + 1))" >>"$WORK/dup.tsv"
expect_refused 'a task in two shards' "$WORK/dup.tsv"

# A gap: move every row of shard 0 to shard 1, leaving shard 0 empty.
awk -F '\t' 'BEGIN{OFS="\t"} $2==0 {$2=1} {print}' "$data_rows" >"$WORK/gap.tsv"
expect_refused 'an empty shard' "$WORK/gap.tsv"

# Malformed row: one field.
cp "$data_rows" "$WORK/short.tsv"
printf 'lonely-task\n' >>"$WORK/short.tsv"
expect_refused 'a one-field row' "$WORK/short.tsv"

# Non-numeric shard.
cp "$data_rows" "$WORK/text.tsv"
printf 'a-task\tsecond\n' >>"$WORK/text.tsv"
expect_refused 'a non-numeric shard' "$WORK/text.tsv"

test "$failed" -eq 0 || exit 1
printf '%s\n' 'PASS: the shard ledger refuses every mutation and accepts the committed partition'

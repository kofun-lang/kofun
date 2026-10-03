#!/bin/sh
# Run one shard of `task verify` (#1684).
#
# `KOFUN_VERIFY_SHARD=<i>` selects the tasks the committed partition assigns to
# shard i and hands exactly those to `verify-runner.sh` with the shard seam set.
# The runner then executes the lane, archives the artifacts the aggregate job
# needs, and stops before the census-dependent global gates, because those read
# a census of the whole run rather than of one shard.
#
# The ledger is checked first. A shard run under a partition that no longer
# covers the verify set must not start: `verify-shard` would otherwise run a
# subset and report a green shard for a set nothing validated.
#
# Usage: KOFUN_VERIFY_SHARD=i sh tests/verify-shards/run-shard.sh
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
HERE=$ROOT/tests/verify-shards
partition=${KOFUN_VERIFY_SHARDS_PARTITION:-$HERE/partition.tsv}
shard=${KOFUN_VERIFY_SHARD:?set KOFUN_VERIFY_SHARD to the shard index}
archive=${KOFUN_VERIFY_SHARD_ARCHIVE:-$ROOT/build/verify-shard-$shard}

case $shard in
    *[!0-9]*|'')
        printf 'FAIL: verify shard: KOFUN_VERIFY_SHARD must be a non-negative integer, got `%s`\n' \
            "$shard" >&2
        exit 2
        ;;
esac

sh "$HERE/check.sh" >/dev/null

shard_count=$(awk -F '\t' '!/^#/ && NF == 2 {print $2}' "$partition" |
    sort -n | tail -n 1)
shard_count=$((shard_count + 1))
if test "$shard" -ge "$shard_count"; then
    printf 'FAIL: verify shard: shard %s is outside 0..%s\n' \
        "$shard" "$((shard_count - 1))" >&2
    exit 2
fi

tasks=$(awk -F '\t' -v s="$shard" '!/^#/ && NF == 2 && $2 == s {print $1}' \
    "$partition" | sort)
test -n "$tasks" || {
    printf 'FAIL: verify shard: shard %s names no tasks\n' "$shard" >&2
    exit 2
}

rm -rf "$archive"
mkdir -p "$archive"

# Word-splitting is intended: the partition holds one task name per line and no
# task name contains whitespace.
# shellcheck disable=SC2086
KOFUN_VERIFY_SHARD=$shard KOFUN_VERIFY_SHARD_ARCHIVE=$archive \
    sh "$ROOT/bootstrap/stage2/verify-runner.sh" "$ROOT" "${VERIFY_JOBS:-3}" $tasks

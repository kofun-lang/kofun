#!/bin/sh
# The aggregate half of a sharded `task verify` (#1684).
#
# Sharding splits the parallel lane across runners. Three things in the runner
# still read a census of the whole run and cannot run inside a shard:
# `fuzz-sanitizer-reuse`, `verify-object-reuse`, and `compile-census`. They run
# here, in the job that requires every shard, over the union of the prepare
# job's census and every shard's census.
#
# The union is the proof that sharding did not change what `verify` measured.
# The prepare job builds the shared pre-lane once and every shard reuses those
# objects, so the pre-lane compiles appear exactly once — in the prepare census
# — and each consumer compile appears exactly once, in the shard that ran it.
# Concatenating the censuses therefore reproduces the single-run census that
# `tooling/compile-census/ledger.tsv` was measured against, and the ceiling
# fails in both directions if it does not.
#
# Usage: KOFUN_VERIFY_AGGREGATE_DIR=<downloads> sh tests/verify-shards/aggregate.sh
#   <downloads>/prepare/{compile-census.tsv,fuzz-sanitizer-census.tsv,
#                        semantic-objects/,fuzz-sanitizer-object/,kofun-stage2,wall_ns}
#   <downloads>/shard-*/{compile-census.tsv,wall_ns}
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
agg_dir=${KOFUN_VERIFY_AGGREGATE_DIR:?set KOFUN_VERIFY_AGGREGATE_DIR to the downloaded artifacts}

fail() {
    printf 'FAIL: verify aggregate: %s\n' "$1" >&2
    exit 1
}

test -d "$agg_dir/prepare" || fail "missing $agg_dir/prepare"

# The job that requires every shard must require *every* shard. A matrix that
# ran fewer than the partition declares would leave a gate unrun while the
# ledger still passed, so the downloaded set is checked against the partition
# itself rather than against the number the workflow happened to list.
declared_shards=$(awk -F '\t' '!/^#/ && NF == 2 {print $2}' \
    "$ROOT/tests/verify-shards/partition.tsv" | sort -n | tail -n 1)
declared_shards=$((declared_shards + 1))
for shard in $(seq 0 $((declared_shards - 1))); do
    test -d "$agg_dir/shard-$shard" ||
        fail "shard $shard is declared in the partition but was not archived"
done
for stray in "$agg_dir"/shard-*; do
    test -d "$stray" || continue
    stray_number=${stray##*/shard-}
    case $stray_number in
        *[!0-9]*|'') fail "unexpected shard archive: $stray" ;;
    esac
    test "$stray_number" -lt "$declared_shards" ||
        fail "shard archive $stray is outside the declared shard set"
done

# The coverage ledger is the aggregate's too: a shard that crashed before
# archiving would leave a task unaccounted for, and the ceiling below only sees
# compiles, not the tasks that never ran.
task verify-shards >/dev/null || fail 'the shard ledger did not pass'

. "$ROOT/bootstrap/stage2/semantic-objects.sh"
. "$ROOT/bootstrap/stage2/fuzz-sanitizer-object.sh"

mkdir -p "$ROOT/build"
work=$(mktemp -d "$ROOT/build/verify-aggregate.XXXXXX")
trap 'kofun_stage2_owned_tree_remove "$work" 2>/dev/null || true' 0 1 2 15

combined=$work/compile-census.tsv
: >"$combined"
cat "$agg_dir/prepare/compile-census.tsv" >>"$combined"
for shard_census in "$agg_dir"/shard-*/compile-census.tsv; do
    test -f "$shard_census" || fail "missing $shard_census"
    cat "$shard_census" >>"$combined"
done

# The fuzz sanitizer census is the prepare job's one compile plus the link rows
# the fuzz consumers appended in whichever shard ran them. Combine it the same
# way, so the completed one-compile/five-link census is reassembled rather than
# read from any single part.
combined_fuzz=$work/fuzz-sanitizer-census.tsv
: >"$combined_fuzz"
cat "$agg_dir/prepare/fuzz-sanitizer-census.tsv" >>"$combined_fuzz"
for shard_fuzz in "$agg_dir"/shard-*/fuzz-sanitizer-census.tsv; do
    test -f "$shard_fuzz" || fail "missing $shard_fuzz"
    cat "$shard_fuzz" >>"$combined_fuzz"
done

semantic_objects=$agg_dir/prepare/semantic-objects
fuzz_sanitizer_objects=$agg_dir/prepare/fuzz-sanitizer-object
fuzz_sanitizer_census=$combined_fuzz
stage2=$agg_dir/prepare/kofun-stage2
resolver=$agg_dir/prepare/module-resolver/kofun-module-resolver
for prepared in "$semantic_objects" "$fuzz_sanitizer_objects" \
    "$agg_dir/prepare/fuzz-sanitizer-census.tsv" "$stage2" "$resolver"
do
    test -e "$prepared" || fail "missing $prepared"
done
chmod +x "$stage2"

# The artifact download does not carry the bundle's read-only modes, and both
# validators refuse a mutable bundle (directory 0555, members 0444). Restore
# them, as the shard runner does for its reuse copy.
for bundle in "$semantic_objects" "$fuzz_sanitizer_objects"; do
    find "$bundle" -type f -exec chmod 0444 {} +
    find "$bundle" -type d -exec chmod 0555 {} +
done

# Reuse the prepare job's launcher resolver instead of rebuilding it here; the
# touch is the freshness condition `ensure_module_resolver` checks.
mkdir -p "$ROOT/build/module-resolver"
cp "$resolver" "$ROOT/build/module-resolver/kofun-module-resolver"
chmod 0755 "$ROOT/build/module-resolver/kofun-module-resolver"
touch "$ROOT/build/module-resolver/kofun-module-resolver"

verify_real_cc=$(command -v "${CC:-cc}") || fail 'a C11 compiler is required'
KOFUN_VERIFY_REAL_CC=$verify_real_cc
export KOFUN_VERIFY_REAL_CC
kofun_stage2_semantic_compiler_identity "$ROOT" || exit 2
KOFUN_VERIFY_REAL_CC_PATH=$KOFUN_STAGE2_SEMANTIC_COMPILER_PATH
KOFUN_VERIFY_REAL_CC_SHA256=$KOFUN_STAGE2_SEMANTIC_COMPILER_SHA256
KOFUN_VERIFY_CC_LOG=$combined
CC=$ROOT/bootstrap/stage2/verify-cc-wrapper.sh
export KOFUN_VERIFY_REAL_CC KOFUN_VERIFY_REAL_CC_PATH \
    KOFUN_VERIFY_REAL_CC_SHA256 KOFUN_VERIFY_CC_LOG CC

KOFUN_STAGE2_COMPILER=$stage2
KOFUN_STAGE2_SEMANTIC_OBJECT_DIR=$semantic_objects
KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR=$fuzz_sanitizer_objects
KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG=$fuzz_sanitizer_census
KOFUN_STAGE2_EVENTS_BUILD_DIR=$work/stage2-events-cli
KOFUN_STAGE2_KIF_BUILD_DIR=$work/stage2-kif-cli
export KOFUN_STAGE2_COMPILER KOFUN_STAGE2_SEMANTIC_OBJECT_DIR \
    KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR \
    KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG \
    KOFUN_STAGE2_EVENTS_BUILD_DIR KOFUN_STAGE2_KIF_BUILD_DIR

# The runner's order: the fuzz and object reuse gates first, then the census
# that reads their appended rows.
KOFUN_FUZZ_SANITIZER_REUSE_WORK=$work/fuzz-sanitizer-reuse
KOFUN_FUZZ_SANITIZER_REUSE_BUNDLE=$fuzz_sanitizer_objects
KOFUN_FUZZ_SANITIZER_REUSE_CENSUS=$fuzz_sanitizer_census
export KOFUN_FUZZ_SANITIZER_REUSE_WORK \
    KOFUN_FUZZ_SANITIZER_REUSE_BUNDLE KOFUN_FUZZ_SANITIZER_REUSE_CENSUS
task fuzz-sanitizer-reuse

KOFUN_VERIFY_OBJECT_REUSE_WORK=$work/verify-object-reuse
KOFUN_VERIFY_OBJECT_REUSE_CENSUS_LOG=$KOFUN_VERIFY_CC_LOG
export KOFUN_VERIFY_OBJECT_REUSE_WORK KOFUN_VERIFY_OBJECT_REUSE_CENSUS_LOG
task verify-object-reuse

suite_wall_ns=0
for wall in "$agg_dir"/prepare/wall_ns "$agg_dir"/shard-*/wall_ns; do
    test -f "$wall" || fail "missing $wall"
    suite_wall_ns=$((suite_wall_ns + $(cat "$wall")))
done
KOFUN_COMPILE_CENSUS_LOG=$KOFUN_VERIFY_CC_LOG
KOFUN_COMPILE_CENSUS_SUITE_WALL_NS=$suite_wall_ns
export KOFUN_COMPILE_CENSUS_LOG KOFUN_COMPILE_CENSUS_SUITE_WALL_NS
task compile-census

printf '%s\n' 'PASS: every shard was archived and the aggregate ran the census over their union'

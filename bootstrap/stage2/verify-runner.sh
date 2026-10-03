#!/bin/sh
set -eu

# Own one complete verify lifecycle.  The caller supplies the parallel task
# names after ROOT and JOBS; roadmap and the completed-run census follow them
# under the same compiler instrumentation.
test "$#" -ge 3 || {
    printf '%s\n' 'usage: verify-runner.sh ROOT JOBS TASK...' >&2
    exit 2
}

verify_root=$(CDPATH= cd -P -- "$1" && pwd)
verify_jobs=$2
shift 2
. "$verify_root/bootstrap/stage2/semantic-objects.sh"
. "$verify_root/bootstrap/stage2/fuzz-sanitizer-object.sh"

mkdir -p "$verify_root/build"
verify_run=$(mktemp -d "$verify_root/build/verify.XXXXXX")
case $verify_run in
    "$verify_root"/build/verify.*) ;;
    *)
        printf '%s\n' "verify runner: unsafe run directory: $verify_run" >&2
        exit 2
        ;;
esac

# Copy the completed census out before the run directory goes, when a caller
# asks for it. #1205's final measurement had to be reconstructed from a comment
# because the only copy of its evidence was deleted at exit; a measurement
# whose input cannot be produced again is a reading, not a method (#1485).
#
# In the cleanup rather than after the last task, so a run that fails still
# leaves the census that explains it.
archive_verify_census() {
    if test -n "${KOFUN_VERIFY_CENSUS_ARCHIVE:-}" &&
       test -n "${KOFUN_VERIFY_CC_LOG:-}" &&
       test -f "${KOFUN_VERIFY_CC_LOG:-}"
    then
        cp "$KOFUN_VERIFY_CC_LOG" "$KOFUN_VERIFY_CENSUS_ARCHIVE" 2>/dev/null ||
            printf '%s\n' \
                "verify runner: cannot archive the census to $KOFUN_VERIFY_CENSUS_ARCHIVE" >&2
    fi
}

cleanup_verify_run() {
    archive_verify_census
    if test -n "${verify_run:-}"; then
        kofun_stage2_owned_tree_remove "$verify_run" 2>/dev/null || true
    fi
}
trap cleanup_verify_run 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

verify_real_cc=$(command -v "${CC:-cc}") || {
    printf '%s\n' 'verify runner: a C11 compiler is required; set CC' >&2
    exit 2
}
verify_cc_wrapper=$verify_root/bootstrap/stage2/verify-cc-wrapper.sh
if test "$verify_real_cc" -ef "$verify_cc_wrapper"; then
    printf '%s\n' \
        'verify runner: CC resolves to the compiler census wrapper itself' >&2
    exit 2
fi
KOFUN_VERIFY_REAL_CC=$verify_real_cc
export KOFUN_VERIFY_REAL_CC
kofun_stage2_semantic_compiler_identity "$verify_root" || exit 2
KOFUN_VERIFY_REAL_CC_PATH=$KOFUN_STAGE2_SEMANTIC_COMPILER_PATH
KOFUN_VERIFY_REAL_CC_SHA256=$KOFUN_STAGE2_SEMANTIC_COMPILER_SHA256
verify_started_ns=$(date +%s%N)
KOFUN_VERIFY_CC_LOG=$verify_run/semantic-compile-census.tsv
CC=$verify_cc_wrapper
export KOFUN_VERIFY_REAL_CC KOFUN_VERIFY_REAL_CC_PATH \
    KOFUN_VERIFY_REAL_CC_SHA256 KOFUN_VERIFY_CC_LOG CC
: >"$KOFUN_VERIFY_CC_LOG"

verify_semantic_objects=$verify_run/semantic-objects
verify_fuzz_sanitizer_objects=$verify_run/fuzz-sanitizer-object
verify_fuzz_sanitizer_census=$verify_run/fuzz-sanitizer-census.tsv

if test -n "${KOFUN_VERIFY_REUSE_DIR:-}"; then
    # #1684. A shard copies the prepare job's prebuilt artifacts instead of
    # rebuilding them. Rebuilding in every shard would put identical pre-lane
    # compiles into every shard's census, and the union would then carry N-1
    # extra repeats per pre-lane family that the single-run ceiling does not
    # have. The prepare job also archives the census that covers these builds.
    for kofun_reuse_member in kofun-stage2 semantic-objects \
        fuzz-sanitizer-object fuzz-sanitizer-census.tsv \
        module-resolver/kofun-module-resolver
    do
        test -e "$KOFUN_VERIFY_REUSE_DIR/$kofun_reuse_member" || {
            printf '%s\n' \
                "verify runner: reuse dir is missing $kofun_reuse_member" >&2
            exit 2
        }
    done
    verify_stage2=$verify_run/kofun-stage2
    cp "$KOFUN_VERIFY_REUSE_DIR/kofun-stage2" "$verify_stage2"
    chmod +x "$verify_stage2"
    cp -R "$KOFUN_VERIFY_REUSE_DIR/semantic-objects" "$verify_semantic_objects"
    cp -R "$KOFUN_VERIFY_REUSE_DIR/fuzz-sanitizer-object" \
        "$verify_fuzz_sanitizer_objects"
    # The fuzz sanitizer census is a two-part record: the prepare job's one
    # compile and the link rows the fuzz consumers append while the lane runs.
    # The shard starts its copy empty so its archive carries only its own link
    # rows; the aggregate adds the prepare census back exactly once. Copying
    # the compile row into every shard would make the union carry four
    # compiles where the single-run census has one.
    : >"$verify_fuzz_sanitizer_census"

    # The artifact upload/download round trip does not carry a bundle's
    # read-only modes, and both validators refuse a mutable bundle: the
    # directory must be 0555 and every member 0444
    # (`kofun_stage2_semantic_objects_validate`,
    # `kofun_stage2_fuzz_sanitizer_objects_validate`). Restore them on the copy
    # rather than weakening the validators, which are what make the reuse a
    # bundle of immutable objects and not a directory anything may edit.
    for kofun_reuse_bundle in "$verify_semantic_objects" \
        "$verify_fuzz_sanitizer_objects"
    do
        find "$kofun_reuse_bundle" -type f -exec chmod 0444 {} +
        find "$kofun_reuse_bundle" -type d -exec chmod 0555 {} +
    done

    # Restore the shared launcher resolver so `bin/kofun` reuses it instead of
    # rebuilding the same family in this runner. It is touched newer than the
    # seed source, which is the condition `ensure_module_resolver` checks.
    mkdir -p "$verify_root/build/module-resolver"
    cp "$KOFUN_VERIFY_REUSE_DIR/module-resolver/kofun-module-resolver" \
        "$verify_root/build/module-resolver/kofun-module-resolver"
    chmod 0755 "$verify_root/build/module-resolver/kofun-module-resolver"
    touch "$verify_root/build/module-resolver/kofun-module-resolver"
else
    verify_stage2=${KOFUN_STAGE2_COMPILER:-}
    if test -z "$verify_stage2"; then
        verify_stage2=$verify_run/kofun-stage2
        . "$verify_root/bootstrap/stage2/build.sh"
        kofun_stage2_build "$verify_root" "$verify_stage2"
    elif test ! -x "$verify_stage2"; then
        printf '%s\n' \
            "verify runner: KOFUN_STAGE2_COMPILER is not executable: $verify_stage2" >&2
        exit 2
    fi

    kofun_stage2_semantic_objects_build \
        "$verify_root" "$verify_semantic_objects"

    kofun_stage2_fuzz_sanitizer_objects_build \
        "$verify_root" "$verify_fuzz_sanitizer_objects" \
        "$verify_fuzz_sanitizer_census" "$verify_real_cc"
fi

KOFUN_STAGE2_COMPILER=$verify_stage2
KOFUN_STAGE2_SEMANTIC_OBJECT_DIR=$verify_semantic_objects
KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR=$verify_fuzz_sanitizer_objects
KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG=$verify_fuzz_sanitizer_census
KOFUN_STAGE2_EVENTS_BUILD_DIR=$verify_run/stage2-events-cli
KOFUN_STAGE2_KIF_BUILD_DIR=$verify_run/stage2-kif-cli
export KOFUN_STAGE2_COMPILER KOFUN_STAGE2_SEMANTIC_OBJECT_DIR \
    KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR \
    KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG \
    KOFUN_STAGE2_EVENTS_BUILD_DIR KOFUN_STAGE2_KIF_BUILD_DIR

# #1684. The prepare job builds the shared pre-lane once and archives it, so
# every shard reuses one set of objects and one census for those builds. It
# stops before the lane: its output is the artifact set, not a gate.
if test -n "${KOFUN_VERIFY_PREPARE_ARCHIVE:-}"; then
    prepare_archive=$KOFUN_VERIFY_PREPARE_ARCHIVE
    mkdir -p "$prepare_archive"

    # `bin/kofun` builds `kofun-module-resolver` on demand into
    # `build/module-resolver` and reuses it for the rest of the run. Left to
    # each runner, a sharded verify would compile it once per runner, and the
    # compile census would count N+1 against a ledger that records the
    # single-run one. Build it here, from a run-scoped module program whose own
    # compiles the census excludes, and let every shard and the aggregate
    # restore and reuse it.
    prepare_resolver_seed=$verify_run/resolver-seed
    mkdir -p "$prepare_resolver_seed/pkg/lib" "$prepare_resolver_seed/pkg/app"
    printf 'module lib.math\n\npub fn identity(value: Int) -> Int {\n    return value\n}\n' \
        >"$prepare_resolver_seed/pkg/lib/math.kofun"
    printf 'module app.main\nimport lib.math\n\nfn main() -> Int {\n    return 0\n}\n' \
        >"$prepare_resolver_seed/pkg/app/main.kofun"
    KOFUN_MODULE_RESOLVER_BUILD_DIR=$prepare_archive/module-resolver \
        "$verify_root/bin/kofun" build \
        "$prepare_resolver_seed/pkg/app/main.kofun" \
        -o "$prepare_resolver_seed/main" || exit 1

    cp "$KOFUN_VERIFY_CC_LOG" "$prepare_archive/compile-census.tsv"
    cp "$verify_fuzz_sanitizer_census" \
        "$prepare_archive/fuzz-sanitizer-census.tsv"
    cp -R "$verify_semantic_objects" "$prepare_archive/semantic-objects"
    cp -R "$verify_fuzz_sanitizer_objects" "$prepare_archive/fuzz-sanitizer-object"
    cp "$verify_stage2" "$prepare_archive/kofun-stage2"
    printf '%s\n' "$(($(date +%s%N) - verify_started_ns))" \
        >"$prepare_archive/wall_ns"
    printf 'PASS: verify prepare archived to %s\n' "$prepare_archive"
    exit 0
fi

# #1684. A measured run records one wall-time row per lane task and stops before
# the global gates: those are not sharded, so they need no weight, and running
# them on a partial census would fail rather than measure. The seam is set only
# by the partition measurement, never by `task verify`.
if test -n "${KOFUN_VERIFY_TASK_TIMES:-}"; then
    sh "$verify_root/tests/verify-shards/time-tasks.sh" \
        "$KOFUN_VERIFY_TASK_TIMES" "$verify_jobs" "$@" roadmap || exit 1
    exit 0
fi

# #1684. A shard run executes exactly the tasks it was handed — `roadmap` is in
# that list for whichever shard owns it — then archives the artifacts the
# aggregate needs and stops. The global gates below are deliberately not run
# here: they read a census of the whole run, and a shard has a census of its
# own. Running them would fail on a partial census, which is the difference
# between a shard and a gate that passed because it could not look.
if test -n "${KOFUN_VERIFY_SHARD:-}"; then
    test -n "${KOFUN_VERIFY_SHARD_ARCHIVE:-}" || {
        printf '%s\n' \
            'verify runner: KOFUN_VERIFY_SHARD requires KOFUN_VERIFY_SHARD_ARCHIVE' >&2
        exit 2
    }
    task --parallel --failfast -C "$verify_jobs" "$@" || exit 1
    shard_archive=$KOFUN_VERIFY_SHARD_ARCHIVE
    mkdir -p "$shard_archive"
    # Only the shard's own census and wall time are its to report: the shared
    # pre-lane objects and the fuzz census belong to the prepare job, and
    # uploading them from every shard would multiply the artifact by the shard
    # count for no reader.
    cp "$KOFUN_VERIFY_CC_LOG" "$shard_archive/compile-census.tsv"
    cp "$verify_fuzz_sanitizer_census" \
        "$shard_archive/fuzz-sanitizer-census.tsv"
    printf '%s\n' "$(($(date +%s%N) - verify_started_ns))" \
        >"$shard_archive/wall_ns"
    printf 'PASS: verify shard %s archived to %s\n' "$KOFUN_VERIFY_SHARD" "$shard_archive"
    exit 0
fi

task --parallel --failfast -C "$verify_jobs" "$@"
task roadmap

# The fuzz gate runs after all five consumers have appended their one link row.
# In runner mode it validates that completed census and the supplied immutable
# bundle without rebuilding the expensive compiler translation unit.
KOFUN_FUZZ_SANITIZER_REUSE_WORK=$verify_run/fuzz-sanitizer-reuse
KOFUN_FUZZ_SANITIZER_REUSE_BUNDLE=$verify_fuzz_sanitizer_objects
KOFUN_FUZZ_SANITIZER_REUSE_CENSUS=$verify_fuzz_sanitizer_census
export KOFUN_FUZZ_SANITIZER_REUSE_WORK \
    KOFUN_FUZZ_SANITIZER_REUSE_BUNDLE KOFUN_FUZZ_SANITIZER_REUSE_CENSUS
task fuzz-sanitizer-reuse

# This gate runs only after every instrumented consumer is complete.  It sees
# the final census and still executes its independent source/object
# differential using KOFUN_VERIFY_REAL_CC, outside the runner-standard count.
KOFUN_VERIFY_OBJECT_REUSE_WORK=$verify_run/verify-object-reuse
KOFUN_VERIFY_OBJECT_REUSE_CENSUS_LOG=$KOFUN_VERIFY_CC_LOG
export KOFUN_VERIFY_OBJECT_REUSE_WORK KOFUN_VERIFY_OBJECT_REUSE_CENSUS_LOG
task verify-object-reuse

# #1485. The standing form of #1205's last measurement: same completed census,
# read for how much of it is work already done. It runs last for the same
# reason the gate above does — every instrumented consumer must have appended
# its rows — and it reports the suite wall it was measured against so the share
# is never quoted without its conditions.
KOFUN_COMPILE_CENSUS_LOG=$KOFUN_VERIFY_CC_LOG
KOFUN_COMPILE_CENSUS_SUITE_WALL_NS=$((
    $(date +%s%N) - verify_started_ns
))
export KOFUN_COMPILE_CENSUS_LOG KOFUN_COMPILE_CENSUS_SUITE_WALL_NS
task compile-census

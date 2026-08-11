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

cleanup_verify_run() {
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
KOFUN_VERIFY_CC_LOG=$verify_run/semantic-compile-census.tsv
CC=$verify_cc_wrapper
export KOFUN_VERIFY_REAL_CC KOFUN_VERIFY_CC_LOG CC
: >"$KOFUN_VERIFY_CC_LOG"

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

verify_semantic_objects=$verify_run/semantic-objects
kofun_stage2_semantic_objects_build \
    "$verify_root" "$verify_semantic_objects"

verify_fuzz_sanitizer_objects=$verify_run/fuzz-sanitizer-object
verify_fuzz_sanitizer_census=$verify_run/fuzz-sanitizer-census.tsv
kofun_stage2_fuzz_sanitizer_objects_build \
    "$verify_root" "$verify_fuzz_sanitizer_objects" \
    "$verify_fuzz_sanitizer_census" "$verify_real_cc"

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

#!/bin/sh
set -eu

# #1656: the scheduled fuzz lane runs `task fuzz` on a fresh checkout with no
# KOFUN_STAGE2_COMPILER, and `arithmetic-c11.sh` reaches the Stage 2 compiler
# through `bin/kofun build`, which builds it on first use. The runner times
# every adapter invocation, so the first case timed a compile of
# `bootstrap/stage2/compiler.c` instead of a program, and failed once that
# compile outgrew the bound on a hosted runner.
#
# A test that waited for the timeout would pass or fail with the speed of the
# machine. This one asks where the compile happens instead: CC is a stand-in
# that answers a compile of the Stage 2 compiler with a prebuilt copy, and
# refuses it when the semantic runner's adapter environment is present -- the
# only place that variable is set is the timed `timeout ADAPTER ...` call.
# Before #1656 the refusal fails the first case; after it the generator has
# already prepared the compiler, untimed, and no adapter ever asks.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_SEMANTIC_COLD_TEST_WORK:-"$ROOT/build/semantic-cold-toolchain-test"}
ASSERT_CONTEXT='semantic cold toolchain'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/build.sh"

rm -rf "$WORK"
mkdir -p "$WORK/stage2-build"

# The copy the stand-in hands out. Under `task verify` this copies the
# compiler the runner already exported, so the test adds no compile of
# `compiler.c` to the verify census; standalone it builds one, once.
kofun_stage2_build "$ROOT" "$WORK/prebuilt-stage2"

cat >"$WORK/cc" <<'EOF'
#!/bin/sh
set -eu
stage2=false
output=
previous=
for argument do
    case $argument in
        */bootstrap/stage2/compiler.c) stage2=true ;;
    esac
    if test "$previous" = -o; then
        output=$argument
    fi
    previous=$argument
done
if test "$stage2" = false; then
    exec "$KOFUN_COLD_TEST_REAL_CC" "$@"
fi
if test -n "${KOFUN_SEMANTIC_PROTOCOL_LIB:-}"; then
    printf '%s\n' adapter >>"$KOFUN_COLD_TEST_LOG"
    printf '%s\n' \
        'cold toolchain test: the Stage 2 compiler was built inside a timed adapter invocation' >&2
    exit 97
fi
printf '%s\n' prepare >>"$KOFUN_COLD_TEST_LOG"
cp "$KOFUN_COLD_TEST_STAGE2" "$output"
EOF
chmod +x "$WORK/cc"
: >"$WORK/stage2-compiles.log"

set +e
(
    unset KOFUN_STAGE2_COMPILER KOFUN_SEMANTIC_PROTOCOL_LIB
    KOFUN_COLD_TEST_REAL_CC=${CC:-cc}
    KOFUN_COLD_TEST_LOG=$WORK/stage2-compiles.log
    KOFUN_COLD_TEST_STAGE2=$WORK/prebuilt-stage2
    CC=$WORK/cc
    KOFUN_STAGE2_BUILD_DIR=$WORK/stage2-build
    KOFUN_SEMANTIC_FUZZ_WORK=$WORK/fuzz
    KOFUN_SEMANTIC_FUZZ_CASES=1
    export KOFUN_COLD_TEST_REAL_CC KOFUN_COLD_TEST_LOG KOFUN_COLD_TEST_STAGE2 \
        CC KOFUN_STAGE2_BUILD_DIR KOFUN_SEMANTIC_FUZZ_WORK \
        KOFUN_SEMANTIC_FUZZ_CASES
    exec sh "$ROOT/tests/fuzz/semantic_differential.sh"
) >"$WORK/run.stdout" 2>"$WORK/run.stderr"
run_status=$?
set -e

if test "$run_status" -ne 0; then
    sed 's/^/  /' "$WORK/run.stderr" >&2
fi
adapter_builds=$(awk '$1 == "adapter" { n++ } END { print n + 0 }' \
    "$WORK/stage2-compiles.log")
prepare_builds=$(awk '$1 == "prepare" { n++ } END { print n + 0 }' \
    "$WORK/stage2-compiles.log")
assert_num "Stage 2 compiles inside a timed adapter" "$adapter_builds" -eq 0
assert_num "cold semantic fuzz status" "$run_status" -eq 0
assert_num "untimed Stage 2 compiles before the first case" \
    "$prepare_builds" -eq 1
assert_grep "run.stdout" -Fqx \
    'PASS: semantic fuzz matched independent model and all declared backends for 1 programs' \
    "$WORK/run.stdout"

printf '%s\n' \
    'PASS: semantic fuzz prepares the Stage 2 compiler before any timed adapter invocation'

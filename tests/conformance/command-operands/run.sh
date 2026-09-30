#!/usr/bin/env sh
# #1666. A program the C11 Stage 2 backend compiles receives its operands and
# writes a line to standard error.
#
# The decision is `spec/c11-command-io-v1.md` (#1665): the operand surface is
# `Text`, at most 256 operands of at most 255 bytes each, `argv[0]` observable,
# an over-bound operand a named refusal; standard error is a `Text` line of at
# most 255 bytes plus `\n`; and a failed command-I/O operation reports an `Int`
# status. The source surface is
#
#   stage2_command_operand_count()          -> Int
#   stage2_command_operand_text(index)      -> Text
#   stage2_command_stderr(text)             -> Int
#
# Four things are proved here, and each one the issue named:
#
#   1. the count includes `argv[0]` and every operand round-trips byte-exact
#      and in order, including an empty operand, one containing a space, and
#      one of non-ASCII UTF-8;
#   2. the count and length bounds are each enforced by supplying a set at the
#      bound and one past it -- 257 operands and a 256-byte operand are refused
#      before the program sees a truncated value;
#   3. the standard-error line writes exactly its bytes and terminator to fd 2
#      and nothing to fd 1, proved by capturing the two streams separately;
#   4. the surface is lowered identically by both halves of the pair, checked
#      on the emitted C and the scope HIR, and a program that uses neither
#      surface is unchanged (`int main(void)`, no command runtime).
#
# `args()` keeps its own disposition: it is the profile's `List[Text]` surface,
# which this slice does not execute, so it stays `E2S10` with exit 3 rather
# than becoming an operand alias. That expectation moved into this gate.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/command-operands"
WORK=${KOFUN_COMMAND_OPERANDS_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}command-operands"}
KOFUN=${KOFUN_COMMAND_OPERANDS_KOFUN:-"$ROOT/bin/kofun"}
CC=${CC:-cc}
SOURCE="$ROOT/bootstrap/stage2/compiler.c"
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: command operands: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the pair check'
case $WORK in
    */command-operands|*/command-operands.*) ;;
    *) fail "work directory must end in command-operands[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/refusals"

COMPILER="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$COMPILER"

# Compile one source to C with the C half, then link it. `--compile-outcome`
# writes the C only on success, so a positive program that refused fails here
# rather than at the run.
build() {
    program=$1
    source=$2
    "$COMPILER" --compile-outcome \
        "$source" "$program.c" "$program.ir" "$program.tokens" \
        >"$program.build.stdout" 2>"$program.build.stderr" ||
        fail "$(basename "$source") did not compile: $(head -n 1 "$program.build.stdout")"
    test ! -s "$program.build.stderr" ||
        fail "$(basename "$source") wrote internal stderr"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        "$program.c" -o "$program" 2>"$program.cc" ||
        fail "$(basename "$source") emitted C that does not compile: $(head -n 1 "$program.cc")"
}

# -------------------------------------------------------------- the operands
#
# The program prints `argv[0..count-1]`, one per line. Run from `$WORK` as
# `./operands`, so the expected output is exactly `./operands` followed by the
# operands the gate supplied. An empty operand and a UTF-8 operand are in the
# three-operand case on purpose: a carrier that dropped an empty string or
# mangled a multi-byte one would still pass a two-ASCII-operand run.
build "$WORK/operands" "$CASES/operands.kofun"

operands_case() {
    label=$1
    shift
    set +e
    (cd "$WORK" && "./operands" "$@" >"$WORK/operands.$label.out" \
        2>"$WORK/operands.$label.err")
    status=$?
    set -e
    test "$status" -eq 0 ||
        fail "operands $label exited $status instead of 0"
    test ! -s "$WORK/operands.$label.err" ||
        fail "operands $label wrote to stderr"
    : >"$WORK/operands.$label.expected"
    printf '%s\n' './operands' >>"$WORK/operands.$label.expected"
    for operand in "$@"; do
        printf '%s\n' "$operand" >>"$WORK/operands.$label.expected"
    done
    cmp "$WORK/operands.$label.expected" "$WORK/operands.$label.out" >/dev/null ||
        fail "operands $label did not print exactly argv[0..count-1] in order"
}

operands_case zero
operands_case one 'hello'
operands_case three '' 'two words' '日本語'

# ------------------------------------------------- the count and length bounds
#
# `argv[0]` counts, so 256 operands is 255 arguments and 257 operands is 256.
# Each refusal must print nothing, exit 1, and report its golden.
at_bound=''
i=0
while test "$i" -lt 255; do
    at_bound="$at_bound space"
    i=$((i + 1))
done
# shellcheck disable=SC2086
operands_case cardinality-at-bound $at_bound

long_operand=$(awk 'BEGIN { while (i++ < 256) printf "a" }')
short_operand=$(awk 'BEGIN { while (i++ < 255) printf "b" }')

refusal() {
    stem=$1
    code=$2
    shift 2
    build "$WORK/refusals/$stem" "$CASES/$stem.kofun"
    for run in first second; do
        set +e
        (cd "$WORK/refusals" && "./$stem" "$@" \
            >"$WORK/refusals/$stem.$run.out" 2>"$WORK/refusals/$stem.$run.err")
        status=$?
        set -e
        test "$status" -eq 1 ||
            fail "$stem exited $status instead of 1 on its $run run"
        cmp "$CASES/$stem.stderr" "$WORK/refusals/$stem.$run.err" >/dev/null ||
            fail "$stem did not report its golden diagnostic on its $run run"
        grep -qF "error[$code]:" "$WORK/refusals/$stem.$run.err" ||
            fail "$stem did not name $code"
        test ! -s "$WORK/refusals/$stem.$run.out" ||
            fail "$stem printed after its refusal on its $run run"
    done
}

# One past the count bound.
# shellcheck disable=SC2046
refusal operand_count_over R034 $(seq 1 256)
# One past the length bound, and the length at the bound accepted.
refusal operand_length_over R036 "$long_operand"
build "$WORK/refusals/operand_length_at_bound" "$CASES/operand_length_over.kofun"
(cd "$WORK/refusals" && "./operand_length_at_bound" "$short_operand" \
    >"$WORK/refusals/length_at_bound.out" 2>"$WORK/refusals/length_at_bound.err") ||
    fail 'the 255-byte operand at the bound was refused'
test ! -s "$WORK/refusals/length_at_bound.err" ||
    fail 'the 255-byte operand at the bound reported a refusal'
printf '%s\n' "$short_operand" >"$WORK/refusals/length_at_bound.expected"
cmp "$WORK/refusals/length_at_bound.expected" \
    "$WORK/refusals/length_at_bound.out" >/dev/null ||
    fail 'the 255-byte operand at the bound did not round-trip exactly'
# An index outside `0..count-1`.
refusal operand_index_out R035
# A standard-error line one byte over the bound.
refusal stderr_line_over R037

# ------------------------------------------------------------- std::stderr
build "$WORK/stderr_line" "$CASES/stderr_line.kofun"
(cd "$WORK" && "./stderr_line" >"$WORK/stderr_line.out" 2>"$WORK/stderr_line.err") ||
    fail 'stderr_line exited non-zero'
printf 'stdout line\n' >"$WORK/stderr_line.expected.out"
printf 'stderr line\n' >"$WORK/stderr_line.expected.err"
cmp "$WORK/stderr_line.expected.out" "$WORK/stderr_line.out" >/dev/null ||
    fail 'the stdout stream is not exactly `print` output'
cmp "$WORK/stderr_line.expected.err" "$WORK/stderr_line.err" >/dev/null ||
    fail 'the stderr stream is not exactly the line plus its terminator'

# --------------------------------------------------------- the old disposition
set +e
"$COMPILER" --compile-outcome "$CASES/args_unsupported.kofun" \
    "$WORK/args.c" "$WORK/args.ir" "$WORK/args.tokens" \
    >"$WORK/args.stdout" 2>"$WORK/args.stderr"
args_status=$?
set -e
test "$args_status" -eq 3 ||
    fail "args() exited $args_status instead of 3"
cmp "$CASES/args_unsupported.stdout" "$WORK/args.stdout" >/dev/null ||
    fail 'args() no longer reports its E2S10 disposition'
test ! -e "$WORK/args.c" || fail 'args() emitted C'
test ! -s "$WORK/args.stderr" || fail 'args() wrote internal stderr'

# ------------------------------------------------------- neither surface used
printf 'fn main() -> Int {\n    print(0)\n    return 0\n}\n' \
    >"$WORK/plain.kofun"
"$COMPILER" --compile-outcome \
    "$WORK/plain.kofun" "$WORK/plain.c" "$WORK/plain.ir" "$WORK/plain.tokens" \
    >/dev/null
grep -q 'int main(void) {' "$WORK/plain.c" ||
    fail 'a program without the command surface changed its entrypoint'
! grep -q 'KOFUN_COMMAND\|stage2_command_' "$WORK/plain.c" ||
    fail 'a program without the command surface emitted the command runtime'

# --------------------------------------------------------- the shipped CLI path
# `bin/kofun build` is what a user runs, so one positive program goes through
# it. The C half is handed in so the build does not compile the seed again.
mkdir -p "$WORK/cli"
KOFUN_STAGE2_COMPILER="$COMPILER" \
KOFUN_BUILD_DIR="$WORK/cli/stage1" \
KOFUN_STAGE2_BUILD_DIR="$WORK/cli/stage2" \
    "$KOFUN" build "$CASES/operands.kofun" -o "$WORK/cli/operands" \
    --emit-c "$WORK/cli/operands.c" \
    >"$WORK/cli/operands.build.stdout" 2>"$WORK/cli/operands.build.stderr" ||
    fail "bin/kofun build did not build the operand program: $(head -n 1 "$WORK/cli/operands.build.stderr")"
(cd "$WORK/cli" && "./operands" 'cli operand' >"$WORK/cli/operands.out" \
    2>"$WORK/cli/operands.err") ||
    fail 'the bin/kofun-built operand program exited non-zero'
{ printf '%s\n' './operands'; printf '%s\n' 'cli operand'; } \
    >"$WORK/cli/operands.expected"
cmp "$WORK/cli/operands.expected" "$WORK/cli/operands.out" >/dev/null ||
    fail 'the bin/kofun-built operand program did not print its operand'

# ----------------------------------------------------------------- the pair
# Every fixture, through both halves, on outcome, emitted C, and scope HIR.
node "$CASES/pair.mjs" "$COMPILER" "$WORK/pair" "$CASES"/*.kofun

printf '%s\n' \
    "PASS: a compiled program prints every operand it receives, argv[0] included, byte-exact and in order for an empty, a spaced, and a non-ASCII UTF-8 operand" \
    'PASS: the 256-operand and 255-byte bounds are accepted at the bound and refused one past it with R034/R035/R036, exit 1, and nothing printed after' \
    'PASS: the standard-error line writes exactly its bytes and terminator to fd 2, and print still writes fd 1 only' \
    'PASS: the surface is lowered identically in both halves of the pair, args() keeps its E2S10 disposition, and a program using neither surface is unchanged'

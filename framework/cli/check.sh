#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_CLI_FRAMEWORK_WORK:-"$ROOT/build/cli-framework"}
CC=${CC:-cc}
PROGRAM="$WORK/kofun-tool"
SOURCE="$ROOT/examples/cli_tool.kofun"
ASSERT_CONTEXT='cli framework'
. "$ROOT/tests/assertions/assert.sh"

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '%s\n' "FAIL: native CLI gate requires $1" >&2
        exit 1
    }
}

for tool in "$CC" ld readelf file ldd "$ROOT/bin/kofun-digest" cmp sed grep script dd
do
    require_tool "$tool"
done

rm -rf "$WORK"
mkdir -p "$WORK/template" "$WORK/spies"

(
    cd "$ROOT/framework/cli"
    "$ROOT/bin/kofun-digest" -c SHA256SUMS
)

# Rebuild the audited freestanding runtime twice with the active host toolchain.
# Compiler versions may choose different instruction sequences and can move the
# page-aligned config segment, so cross-toolchain byte equality is not a valid
# reproducibility claim. Instead, require byte stability within this toolchain
# and execute a compiler built against the reproduced prefix.
"$CC" -std=c11 -Os -ffreestanding -fno-builtin \
    -fno-stack-protector -fno-pie \
    -fno-asynchronous-unwind-tables -fno-unwind-tables \
    -Wall -Wextra -Werror \
    -c "$ROOT/framework/cli/runtime.c" -o "$WORK/template/runtime.o"
"$CC" -c -fno-pie \
    "$ROOT/framework/cli/start.S" -o "$WORK/template/start.o"
ld -nostdlib -static --build-id=none \
    -T "$ROOT/framework/cli/runtime.ld" \
    "$WORK/template/start.o" "$WORK/template/runtime.o" \
    -o "$WORK/template/runtime.elf"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/framework/cli/template_to_inc.c" \
    -o "$WORK/template/template-to-inc"
"$WORK/template/template-to-inc" \
    "$WORK/template/runtime.elf" "$WORK/template/first.inc"
"$WORK/template/template-to-inc" \
    "$WORK/template/runtime.elf" "$WORK/template/second.inc"
cmp "$WORK/template/first.inc" "$WORK/template/second.inc"
cp "$ROOT/framework/cli/compiler.c" "$WORK/template/compiler.c"
cp "$WORK/template/first.inc" "$WORK/template/runtime_template.inc"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/template/compiler.c" \
    -o "$WORK/template/reproduced-compiler"
"$WORK/template/reproduced-compiler" \
    "$SOURCE" "$WORK/template/reproduced-program"
assert_eq "output of template/reproduced-program sum -8 50" \
    "$("$WORK/template/reproduced-program" sum -8 50)" 42
"$WORK/template/reproduced-program" --help \
    >"$WORK/template/reproduced-help.txt"
assert_grep "template/reproduced-help.txt" \
    -Fq \
    'Usage: kofun-tool <command> [options]' \
    "$WORK/template/reproduced-help.txt"

# Build the declaration compiler with strict warnings and with ASAN/UBSAN.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/framework/cli/compiler.c" -o "$WORK/compiler"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/framework/cli/compiler.c" -o "$WORK/compiler-sanitized"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" "$SOURCE" "$WORK/sanitized-output"

"$WORK/compiler" "$SOURCE" "$WORK/direct-output"
cmp "$WORK/direct-output" "$WORK/sanitized-output"

# Prime the normal CLI compiler, then prove an application build cannot invoke
# cc/as/ld/clang/gcc while emitting its final executable.
KOFUN_CLI_BUILD_DIR="$WORK/active-compiler" \
    "$ROOT/bin/kofun" build "$SOURCE" --framework cli \
    -o "$PROGRAM" >/dev/null
for tool in cc as ld gcc clang
do
    printf '%s\n' '#!/usr/bin/env sh' 'exit 99' >"$WORK/spies/$tool"
    chmod +x "$WORK/spies/$tool"
done
PATH="$WORK/spies:$PATH" \
CC="$WORK/spies/cc" \
KOFUN_CLI_BUILD_DIR="$WORK/active-compiler" \
    "$ROOT/bin/kofun" build "$SOURCE" --framework cli \
    -o "$WORK/no-host-tool-output" >/dev/null
cmp "$PROGRAM" "$WORK/no-host-tool-output"

# The product is an actual static, dependency-free, executable ELF.
file "$PROGRAM" >"$WORK/file.txt"
assert_grep "file.txt" \
    -q 'ELF 64-bit.*x86-64.*statically linked' "$WORK/file.txt"
readelf -lW "$PROGRAM" >"$WORK/program-headers.txt"
assert_num "^  LOAD lines in program-headers.txt" \
    "$(grep -c '^  LOAD' "$WORK/program-headers.txt")" -eq 2
assert_not_grep "program-headers.txt" \
    -Eq 'INTERP|DYNAMIC' "$WORK/program-headers.txt"
readelf -dW "$PROGRAM" >"$WORK/dynamic.txt" 2>&1 || true
assert_not_grep "dynamic.txt" -q 'NEEDED' "$WORK/dynamic.txt"
readelf -hW "$PROGRAM" >"$WORK/header.txt"
assert_grep "header.txt" \
    -Eq 'Number of section headers:[[:space:]]+0' "$WORK/header.txt"
set +e
ldd "$PROGRAM" >"$WORK/ldd.txt" 2>&1
ldd_status=$?
set -e
assert_num "ldd status" "$ldd_status" -ne 0
assert_grep "ldd.txt" \
    -Eq 'not a dynamic executable|statically linked' "$WORK/ldd.txt"

# Help and dispatch are generated from the same declaration metadata.
"$PROGRAM" --help >"$WORK/help.txt"
assert_grep "help.txt" -Fq 'kofun-tool 1.0.0' "$WORK/help.txt"
assert_grep "help.txt" -Fq '  greet	Greet a person' "$WORK/help.txt"
assert_grep "help.txt" \
    -Fq '  sum	Add two signed 64-bit integers' "$WORK/help.txt"
assert_grep "help.txt" \
    -Fq '  env	Print an environment variable' "$WORK/help.txt"
assert_grep "help.txt" \
    -Fq '  status	Render a terminal-aware progress status' "$WORK/help.txt"
"$PROGRAM" greet --help >"$WORK/greet-help.txt"
assert_grep "greet-help.txt" \
    -Fq 'Usage: kofun-tool greet <NAME> [options]' "$WORK/greet-help.txt"
assert_grep "greet-help.txt" \
    -Fq '  --prefix <VALUE>	Greeting prefix' "$WORK/greet-help.txt"

sed \
    -e 's/name "kofun-tool"/name "changed-tool"/' \
    -e 's/command greet/command welcome/' \
    -e 's/Greet a person/Welcome a person/' \
    -e 's/"--prefix"/"--salutation"/' \
    "$SOURCE" >"$WORK/metamorphic.kofun"
"$WORK/compiler" "$WORK/metamorphic.kofun" "$WORK/metamorphic"
assert_eq "output of metamorphic welcome Lin --salutation Ahoy" \
    "$("$WORK/metamorphic" welcome Lin --salutation Ahoy)" 'Ahoy, Lin!'
"$WORK/metamorphic" --help >"$WORK/metamorphic-help.txt"
assert_grep "metamorphic-help.txt" \
    -Fq 'changed-tool 1.0.0' "$WORK/metamorphic-help.txt"
assert_grep "metamorphic-help.txt" \
    -Fq '  welcome	Welcome a person' "$WORK/metamorphic-help.txt"
assert_not_grep "metamorphic-help.txt" \
    -Fq '  greet	' "$WORK/metamorphic-help.txt"
if cmp -s "$PROGRAM" "$WORK/metamorphic"; then
    printf '%s\n' "FAIL: declaration mutation did not change emitted ELF" >&2
    exit 1
fi

expect_program_failure() {
    label=$1
    expected_status=$2
    expected_stderr=$3
    shift 3
    set +e
    "$PROGRAM" "$@" >"$WORK/$label.stdout" 2>"$WORK/$label.stderr"
    actual_status=$?
    set -e
    assert_num "actual status" "$actual_status" -eq "$expected_status"
    assert_file_empty "$label.stdout" "$WORK/$label.stdout"
    printf '%s\n' "$expected_stderr" >"$WORK/$label.expected"
    cmp "$WORK/$label.expected" "$WORK/$label.stderr"
}

# Runtime values—not compiler-known answers—drive each action.
assert_eq "output of $PROGRAM greet Ada" \
    "$("$PROGRAM" greet Ada)" 'Hello, Ada!'
assert_eq "output of $PROGRAM greet Grace --prefix=Welcome" \
    "$("$PROGRAM" greet Grace --prefix=Welcome)" 'Welcome, Grace!'
assert_eq "output of $PROGRAM greet Lin --prefix Ahoy --shout" \
    "$("$PROGRAM" greet Lin --prefix Ahoy --shout)" 'AHOY, LIN!'
assert_eq "output of $PROGRAM greet -- --shout" \
    "$("$PROGRAM" greet -- --shout)" 'Hello, --shout!'
assert_eq "output of $PROGRAM sum 1 2" "$("$PROGRAM" sum 1 2)" 3
assert_eq "output of $PROGRAM sum -8 50" "$("$PROGRAM" sum -8 50)" 42
assert_eq "output of KOFUN_CLI_VALUE=runtime $PROGRAM env KOFUN_CLI_VALUE" \
    "$(KOFUN_CLI_VALUE=runtime "$PROGRAM" env KOFUN_CLI_VALUE)" runtime
assert_eq "output of $PROGRAM status indexing" \
    "$("$PROGRAM" status indexing)" 'status: indexing'

expect_program_failure unknown-command 2 \
    'kofun-tool: unknown command: missing' missing
expect_program_failure missing-position 2 \
    'kofun-tool: missing argument NAME for greet' greet
expect_program_failure unknown-option 2 \
    'kofun-tool: unknown option for greet: --quiet' greet Ada --quiet
expect_program_failure missing-option-value 2 \
    'kofun-tool: missing value for option: --prefix' \
    greet Ada --prefix
expect_program_failure duplicate-option 2 \
    'kofun-tool: duplicate option: --prefix' \
    greet Ada --prefix Hi --prefix Bye
expect_program_failure boolean-value 2 \
    'kofun-tool: boolean option does not take a value: --shout' \
    greet Ada --shout=true
expect_program_failure bad-integer 2 \
    'kofun-tool: sum expects two Int64 values without overflow' \
    sum 9223372036854775807 1

set +e
env -u KOFUN_CLI_MISSING "$PROGRAM" env KOFUN_CLI_MISSING \
    >"$WORK/missing-env.stdout" 2>"$WORK/missing-env.stderr"
missing_env_status=$?
set -e
assert_num "missing env status" "$missing_env_status" -eq 3
assert_file_empty "missing-env.stdout" "$WORK/missing-env.stdout"
printf '%s\n' \
    'kofun-tool: environment variable not set: KOFUN_CLI_MISSING' \
    >"$WORK/missing-env.expected"
cmp "$WORK/missing-env.expected" "$WORK/missing-env.stderr"

# TTY detection controls both color and the progress/status rendering path.
escape=$(printf '\033')
env -u NO_COLOR script -qefc \
    "'$PROGRAM' greet Ada" /dev/null >"$WORK/tty-color.txt"
assert_grep "tty-color.txt" -Fq "${escape}[32m" "$WORK/tty-color.txt"
NO_COLOR=1 script -qefc \
    "'$PROGRAM' greet Ada" /dev/null >"$WORK/tty-no-color.txt"
assert_not_grep "tty-no-color.txt" -Fq "$escape" "$WORK/tty-no-color.txt"
env -u NO_COLOR script -qefc \
    "'$PROGRAM' status compiling" /dev/null >"$WORK/tty-status.txt"
assert_grep "tty-status.txt" \
    -Fq "${escape}[36m... compiling" "$WORK/tty-status.txt"
assert_grep "tty-status.txt" \
    -Fq "${escape}[K${escape}[32mdone compiling" "$WORK/tty-status.txt"
"$PROGRAM" status compiling >"$WORK/non-tty-status.txt"
assert_eq "contents of non-tty-status.txt" \
    "$(cat "$WORK/non-tty-status.txt")" 'status: compiling'
assert_not_grep "non-tty-status.txt" -Fq "$escape" "$WORK/non-tty-status.txt"

expect_compiler_failure() {
    label=$1
    source=$2
    expected=$3
    set +e
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/compiler-sanitized" "$source" "$WORK/$label-output" \
        >"$WORK/$label.stdout" 2>"$WORK/$label.stderr"
    status=$?
    set -e
    assert_num "status" "$status" -eq 2
    assert_absent "$label-output" "$WORK/$label-output"
    grep -Fq "$expected" "$WORK/$label.stderr"
}

expect_compiler_failure malformed-action \
    "$ROOT/tests/framework/cli/malformed_action.kofun" \
    'action must be greet, sum, env, or status'
expect_compiler_failure missing-command \
    "$ROOT/tests/framework/cli/missing_command.kofun" \
    'application requires at least two commands'
expect_compiler_failure duplicate-option-source \
    "$ROOT/tests/framework/cli/duplicate_option.kofun" \
    'duplicate option identifier or long name'
dd if=/dev/zero of="$WORK/oversized.kofun" bs=65537 count=1 status=none
expect_compiler_failure oversized "$WORK/oversized.kofun" \
    'source exceeds 65536-byte profile limit'

# `kofun new` creates a clean, buildable project, not a documentation stub.
KOFUN_CLI_BUILD_DIR="$WORK/scaffold-compiler" \
    "$ROOT/bin/kofun" new "$WORK/demo-cli" --template cli >/dev/null
assert_regular_file "demo-cli/src/main.kofun" "$WORK/demo-cli/src/main.kofun"
assert_regular_file "demo-cli/README.md" "$WORK/demo-cli/README.md"
KOFUN_CLI_BUILD_DIR="$WORK/scaffold-compiler" \
    "$ROOT/bin/kofun" build "$WORK/demo-cli/src/main.kofun" \
    --framework cli -o "$WORK/demo-cli/build/demo-cli" >/dev/null
assert_eq "output of demo-cli/build/demo-cli greet World" \
    "$("$WORK/demo-cli/build/demo-cli" greet World)" 'Hello, World!'
"$WORK/demo-cli/build/demo-cli" --help |
    grep -Fq 'Usage: demo-cli <command> [options]'

printf '%s\n' \
    'PASS: CLI declarations generate help and runtime argv dispatch' \
    'PASS: long options, --, subcommands, env, exits, TTY color, and status execute' \
    'PASS: direct ELF has two PT_LOAD segments and no interpreter/dependencies' \
    'PASS: active application build invokes no host compiler/assembler/linker' \
    'PASS: compiler limits and malformed sources pass ASAN/UBSAN rejection' \
    'PASS: kofun new --template cli scaffolds a clean working application'

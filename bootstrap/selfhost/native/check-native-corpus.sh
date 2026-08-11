#!/usr/bin/env sh
set -eu

# Self-host Core native parity.
#
# The frozen single-expression self-host Core program is lowered to a native
# executable two fully independent ways, and both must print the pinned golden:
#
#   1. Self-host C11 path: the compiler built from the frozen S (A1), produced
#      exactly as in bootstrap/selfhost/check-compiler-driver.sh via
#      `kofun-stage2 --selfhost-compile`, emits deterministic C11 that the
#      declared host cc links into a native binary.
#   2. Direct-native path: the audited x86-64/AArch64 ELF backend emits a
#      statically linked image with no assembler, linker, or cc.
#
# Honesty boundaries:
#   * This does NOT claim self-application (S compiling S). A1 compiles an
#     ordinary Core input, exactly like the driver gate.
#   * This does NOT add a direct-native dependency to the #271/#272 C11 fixed
#     point, which stays cc-based and native-independent. It is separate parity
#     evidence that the self-host Core reaches a real native binary through two
#     independent backends.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cd "$ROOT"
SELF="$ROOT/bootstrap/selfhost/native"
KOFUN="$ROOT/bin/kofun"
WORK=${KOFUN_SELFHOST_NATIVE_WORK:-"$ROOT/build/selfhost-native"}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: selfhost native parity: $*" >&2
    exit 1
}

command -v readelf >/dev/null 2>&1 || fail "readelf is required"

AARCH64_RUNNER=${QEMU_AARCH64-}
if test -n "$AARCH64_RUNNER" && command -v "$AARCH64_RUNNER" >/dev/null 2>&1; then
    :
elif command -v qemu-aarch64 >/dev/null 2>&1; then
    AARCH64_RUNNER=$(command -v qemu-aarch64)
elif command -v qemu-aarch64-static >/dev/null 2>&1; then
    AARCH64_RUNNER=$(command -v qemu-aarch64-static)
else
    AARCH64_RUNNER=
fi

rm -rf "$WORK"
mkdir -p "$WORK"

CORE="$SELF/corpus_core.kofun"
GOLDEN="$SELF/corpus_core.stdout"

# The frozen S digest still matches the pinned profile.
profile_digest=$(awk -F '|' '$1 == "source_sha256" { print $2 }' \
    bootstrap/selfhost/profile.meta)
actual_digest=$("$ROOT/bin/kofun-digest" bootstrap/stage1/compiler.kofun | awk '{ print $1 }')
test "$profile_digest" = "$actual_digest" ||
    fail "S digest differs from the frozen profile"

# Path 1: the compiler built from S (A1) lowers the Core to C11, then cc links.
kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"
"$WORK/kofun-stage2" --selfhost-compile \
    bootstrap/stage1/compiler.kofun "$WORK/S.c" "$profile_digest" >/dev/null
cmp bootstrap/selfhost/driver/S.c "$WORK/S.c" ||
    fail "compiler-from-S differs from the checked-in driver evidence"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    -I unicode "$WORK/S.c" -o "$WORK/kofun-a1"

# Two programs go through both paths. The frozen single expression is the
# original evidence and stays exactly as it was. The self-host driver's success
# corpus is the program A1 already compiles on the C11 path, and it is the one
# that makes the claim worth something: five prints, two inferred Int locals,
# floor division, floor modulo, and truncating division.
CASES="core answer"
case_source() {
    case $1 in
        core) printf '%s\n' "$CORE" ;;
        answer) printf '%s\n' "$ROOT/bootstrap/selfhost/driver/corpus_answer.kofun" ;;
    esac
}
case_golden() {
    case $1 in
        core) printf '%s\n' "$GOLDEN" ;;
        answer) printf '%s\n' "$ROOT/bootstrap/selfhost/driver/corpus_answer.stdout" ;;
    esac
}

for case_name in $CASES; do
    source=$(case_source "$case_name")
    golden=$(case_golden "$case_name")
    cp "$source" "$WORK/$case_name.kofun"
    (cd "$WORK" && ./kofun-a1 "$case_name.kofun" "$case_name.a1.c" >/dev/null)
    test -s "$WORK/$case_name.a1.c" ||
        fail "$case_name: A1 emitted no C11"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror \
        "$WORK/$case_name.a1.c" -o "$WORK/$case_name.a1"
    "$WORK/$case_name.a1" >"$WORK/$case_name.a1.stdout"
    cmp "$golden" "$WORK/$case_name.a1.stdout" ||
        fail "$case_name: self-host C11 path output differs from the golden"
done

# Path 2: the direct-native backend emits a deterministic static ELF per target.
for case_name in $CASES; do
    source=$(case_source "$case_name")
    for target in x86_64-linux aarch64-linux; do
        case $target in
            x86_64-linux)
                stem="$case_name-x86_64"
                machine='Advanced Micro Devices X86-64'
                ;;
            aarch64-linux)
                stem="$case_name-aarch64"
                machine='AArch64'
                ;;
        esac
        "$KOFUN" build "$source" --target "$target" \
            -o "$WORK/$stem.elf" >/dev/null
        "$KOFUN" build "$source" --target "$target" \
            -o "$WORK/$stem.second.elf" >/dev/null
        cmp "$WORK/$stem.elf" "$WORK/$stem.second.elf" ||
            fail "$stem native image is not deterministic"
        test -s "$WORK/$stem.elf" || fail "$stem native image is empty"
        readelf -h "$WORK/$stem.elf" >"$WORK/$stem.header.txt"
        grep -Eq 'Class:[[:space:]]+ELF64' "$WORK/$stem.header.txt" ||
            fail "$stem native image is not ELF64"
        grep -Eq "Machine:[[:space:]]+$machine" "$WORK/$stem.header.txt" ||
            fail "$stem native image reports the wrong machine"
        readelf -l "$WORK/$stem.elf" >"$WORK/$stem.program-headers.txt"
        ! grep -Eq 'INTERP|DYNAMIC' "$WORK/$stem.program-headers.txt" ||
            fail "$stem native image is not statically linked"
    done
done

# Path independence: the same relative source from two directories emits
# byte-identical images on each target, so no absolute build path leaks into
# either artifact.
for case_name in $CASES; do
    source=$(case_source "$case_name")
    mkdir -p "$WORK/remap-$case_name-a/nested" "$WORK/remap-$case_name-b"
    cp "$source" "$WORK/remap-$case_name-a/nested/input.kofun"
    cp "$source" "$WORK/remap-$case_name-b/input.kofun"
    for target in x86_64-linux aarch64-linux; do
        (cd "$WORK/remap-$case_name-a/nested" &&
            "$KOFUN" build input.kofun --target "$target" \
                -o "out-$target" >/dev/null)
        (cd "$WORK/remap-$case_name-b" &&
            "$KOFUN" build input.kofun --target "$target" \
                -o "out-$target" >/dev/null)
        cmp \
            "$WORK/remap-$case_name-a/nested/out-$target" \
            "$WORK/remap-$case_name-b/out-$target" ||
            fail "$case_name $target image depends on the build directory"
    done
done

# Differential: both independent native binaries print the same pinned golden.
for case_name in $CASES; do
    golden=$(case_golden "$case_name")
    "$WORK/$case_name-x86_64.elf" >"$WORK/$case_name.native-x86_64.stdout"
    cmp "$golden" "$WORK/$case_name.native-x86_64.stdout" ||
        fail "$case_name: direct-native x86-64 output differs from the golden"
    cmp "$WORK/$case_name.a1.stdout" \
        "$WORK/$case_name.native-x86_64.stdout" ||
        fail "$case_name: the self-host C11 and direct-native backends disagree"
done

if test -n "$AARCH64_RUNNER"; then
    for case_name in $CASES; do
        golden=$(case_golden "$case_name")
        "$AARCH64_RUNNER" "$WORK/$case_name-aarch64.elf" \
            >"$WORK/$case_name.native-aarch64.stdout"
        cmp "$golden" "$WORK/$case_name.native-aarch64.stdout" ||
            fail "$case_name: direct-native AArch64 output differs under $AARCH64_RUNNER"
    done
    printf '%s\n' "PASS: AArch64 native parity under $AARCH64_RUNNER"
else
    printf '%s\n' \
        "SKIP: AArch64 execution (no qemu-aarch64 runner); ELF64 machine verified"
fi

# Negative: the native Core is still bounded, and the boundary is still
# enforced rather than assumed. This program needs List[Int], which only the
# single-`main` front end lowers, together with several `print` statements,
# which only the function profile accepts. Neither can take it, so it is
# refused with a stable diagnostic and writes no image.
set +e
"$KOFUN" build bootstrap/native/fixtures/unsupported_native_core.kofun \
    --target x86_64-linux -o "$WORK/refused.elf" \
    >"$WORK/refused.stdout" 2>"$WORK/refused.stderr"
refuse_status=$?
set -e
test "$refuse_status" -eq 1 ||
    fail "native backend must refuse the out-of-Core program with exit 1"
test ! -e "$WORK/refused.elf" ||
    fail "a refused native build must not write an image"
grep -q 'unsupported Core' "$WORK/refused.stderr" ||
    fail "native refusal is missing its bounded diagnostic"

printf '%s\n' \
    "PASS: the frozen Core and the self-host success corpus both lower to identical native output via A1/C11 and direct-native x86-64" \
    "PASS: direct-native x86-64/AArch64 images are static ELF64, deterministic, and path-independent" \
    "PASS: the native Core still refuses a program outside both front ends and writes nothing"

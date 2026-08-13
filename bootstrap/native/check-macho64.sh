#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
NATIVE="$ROOT/bootstrap/native"
KOFUN="$ROOT/bin/kofun"
WORK=${KOFUN_NATIVE_MACHO64_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}native-macho64-check"}
ASSERT_CONTEXT=native-macho64
. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

# The canonical List[Int] writer is indexed by Stage 2 in the caller. Until
# List-returning functions lower through the full compiler, materialise its
# exact scalar fields through the bounded Kofun bridge.
"$KOFUN" build "$NATIVE/fixtures/macho64_images.kofun" \
    --emit-c "$WORK/emitter.c" \
    -o "$WORK/emitter" >/dev/null
"$WORK/emitter" >"$WORK/stream.first"
"$WORK/emitter" >"$WORK/stream.second"
cmp "$WORK/stream.first" "$WORK/stream.second"

: >"$WORK/x86_64-macos.macho"
: >"$WORK/aarch64-macos.macho"
state=x86
while IFS= read -r field; do
    case $field in
        ''|*[!0-9]*)
            printf '%s\n' "native-macho64: invalid numeric field: $field" >&2
            exit 1
            ;;
    esac
    if test "$field" -eq 999; then
        test "$state" = x86 || {
            printf '%s\n' "native-macho64: duplicate image delimiter" >&2
            exit 1
        }
        state=arm
        continue
    fi
    test "$field" -le 255 || {
        printf '%s\n' "native-macho64: byte outside 0..255: $field" >&2
        exit 1
    }
    octal=$(printf '%03o' "$field")
    if test "$state" = x86; then
        printf "\\$octal" >>"$WORK/x86_64-macos.macho"
    else
        printf "\\$octal" >>"$WORK/aarch64-macos.macho"
    fi
done <"$WORK/stream.first"
test "$state" = arm || {
    printf '%s\n' "native-macho64: AArch64 image delimiter is absent" >&2
    exit 1
}

assert_num "x86-64 Mach-O 64 size" \
    "$(wc -c <"$WORK/x86_64-macos.macho" | tr -d ' ')" -eq 4096
assert_num "AArch64 Mach-O 64 size" \
    "$(wc -c <"$WORK/aarch64-macos.macho" | tr -d ' ')" -eq 16384

# Execute the same scalar refusal predicate the canonical List[Int] writer
# calls, keeping invalid-input evidence on the canonical implementation.
awk '
    /^# macho64-request-validator:start$/ { emit = 1; next }
    /^# macho64-request-validator:end$/ { emit = 0; next }
    emit { print }
' "$NATIVE/encoder.kofun" >"$WORK/request-validator.kofun"
cat >>"$WORK/request-validator.kofun" <<'KOFUN'

fn main() {
    print(macho64_request_status(16777223, 9, 0, 255))
    print(macho64_request_status(0, 9, 0, 255))
    print(macho64_request_status(16777223, 0, 0, 0))
    print(macho64_request_status(16777228, 3585, 0, 255))
    print(macho64_request_status(16777223, 9, -1, 255))
    print(macho64_request_status(16777228, 12, 0, 256))
}
KOFUN
"$KOFUN" build "$WORK/request-validator.kofun" \
    --emit-c "$WORK/request-validator.c" \
    -o "$WORK/request-validator" >/dev/null
"$WORK/request-validator" >"$WORK/request-validator.actual"
cat >"$WORK/request-validator.expected" <<'EXPECTED'
0
1
2
2
3
3
EXPECTED
cmp "$WORK/request-validator.expected" "$WORK/request-validator.actual"

node "$NATIVE/macho64-check.mjs" \
    "$WORK/x86_64-macos.macho" \
    "$WORK/aarch64-macos.macho"

if command -v file >/dev/null 2>&1; then
    file "$WORK/x86_64-macos.macho" >"$WORK/file-x86.actual"
    file "$WORK/aarch64-macos.macho" >"$WORK/file-arm.actual"
    assert_grep "file x86-64 identity" 'Mach-O 64-bit x86_64 executable' \
        "$WORK/file-x86.actual"
    assert_grep "file AArch64 identity" 'Mach-O 64-bit arm64 executable' \
        "$WORK/file-arm.actual"
fi

if command -v llvm-readobj >/dev/null 2>&1; then
    llvm-readobj --file-headers --sections --macho-segment --macho-version-min \
        "$WORK/x86_64-macos.macho" >"$WORK/llvm-x86.actual"
    llvm-readobj --file-headers --sections --macho-segment --macho-version-min \
        "$WORK/aarch64-macos.macho" >"$WORK/llvm-arm.actual"
    assert_grep "LLVM x86-64 CPU identity" 'CpuType: X86-64' \
        "$WORK/llvm-x86.actual"
    assert_grep "LLVM AArch64 CPU identity" 'CpuType: Arm64' \
        "$WORK/llvm-arm.actual"
fi

printf '%s\n' \
    "PASS: Kofun emitted deterministic x86-64 and AArch64 Mach-O 64 images"
printf '%s\n' \
    "PASS: Mach-O invalid CPU/code/size inputs refuse before image writing"

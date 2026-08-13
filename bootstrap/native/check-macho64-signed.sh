#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
NATIVE="$ROOT/bootstrap/native"
KOFUN="$ROOT/bin/kofun"
WORK=${KOFUN_NATIVE_MACHO64_SIGNED_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}native-macho64-signed-check"}
ASSERT_CONTEXT=native-macho64-signed
. "$ROOT/tests/assertions/assert.sh"

case $WORK in
    */macho64-signed|*/macho64-signed.*|*/native-macho64-signed-check|*/native-macho64-signed-check.*) ;;
    *) assert_fail "work directory must end in macho64-signed or native-macho64-signed-check: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

# Prepend the exact SHA-256 compression core from the canonical encoder. The
# bridge supplies a bounded byte-at-offset page reader, so no foreign digest or
# precomputed page hash enters the producing path.
awk '
    /^# native-signing-sha256:start$/ { emit = 1; next }
    /^# native-signing-sha256-core:end$/ { emit = 0; next }
    emit { print }
' "$NATIVE/encoder.kofun" >"$WORK/emitter.kofun"
awk '{ print }' "$NATIVE/fixtures/macho64_signed_images.kofun" \
    >>"$WORK/emitter.kofun"

"$KOFUN" build "$WORK/emitter.kofun" \
    --emit-c "$WORK/emitter.c" \
    -o "$WORK/emitter" >/dev/null
"$WORK/emitter" >"$WORK/stream.first"
"$WORK/emitter" >"$WORK/stream.second"
cmp "$WORK/stream.first" "$WORK/stream.second"

: >"$WORK/x86_64-macos-signed.macho"
: >"$WORK/aarch64-macos-signed.macho"
state=x86
while IFS= read -r field; do
    case $field in
        ''|*[!0-9]*)
            assert_fail "invalid numeric field: $field"
            ;;
    esac
    if test "$field" -eq 999; then
        test "$state" = x86 || assert_fail 'duplicate image delimiter'
        state=arm
        continue
    fi
    test "$field" -le 255 || assert_fail "byte outside 0..255: $field"
    octal=$(printf '%03o' "$field")
    if test "$state" = x86; then
        printf "\\$octal" >>"$WORK/x86_64-macos-signed.macho"
    else
        printf "\\$octal" >>"$WORK/aarch64-macos-signed.macho"
    fi
done <"$WORK/stream.first"
test "$state" = arm || assert_fail 'AArch64 image delimiter is absent'

assert_num "signed x86-64 Mach-O size" \
    "$(wc -c <"$WORK/x86_64-macos-signed.macho" | tr -d ' ')" -eq 4256
assert_num "signed AArch64 Mach-O size" \
    "$(wc -c <"$WORK/aarch64-macos-signed.macho" | tr -d ' ')" -eq 16544

# Execute the exact scalar predicate the canonical signed-image writer calls.
awk '
    /^# macho64-signing-request-validator:start$/ { emit = 1; next }
    /^# macho64-signing-request-validator:end$/ { emit = 0; next }
    emit { print }
' "$NATIVE/encoder.kofun" >"$WORK/request-validator.kofun"
awk '{ print }' "$NATIVE/fixtures/macho64_signing_requests.kofun" \
    >>"$WORK/request-validator.kofun"
"$KOFUN" build "$WORK/request-validator.kofun" \
    --emit-c "$WORK/request-validator.c" \
    -o "$WORK/request-validator" >/dev/null
"$WORK/request-validator" >"$WORK/request-validator.actual"
printf '%s\n' 0 1 2 2 3 3 4 4 5 5 >"$WORK/request-validator.expected"
cmp "$WORK/request-validator.expected" "$WORK/request-validator.actual"

node "$NATIVE/macho64-signed-check.mjs" \
    "$WORK/x86_64-macos-signed.macho" \
    "$WORK/aarch64-macos-signed.macho"

if command -v file >/dev/null 2>&1; then
    file "$WORK/x86_64-macos-signed.macho" >"$WORK/file-x86.actual"
    file "$WORK/aarch64-macos-signed.macho" >"$WORK/file-arm.actual"
    assert_grep "file signed x86-64 identity" \
        'Mach-O 64-bit x86_64 executable' "$WORK/file-x86.actual"
    assert_grep "file signed AArch64 identity" \
        'Mach-O 64-bit arm64 executable' "$WORK/file-arm.actual"
fi

if command -v llvm-objdump >/dev/null 2>&1; then
    llvm-objdump --macho --private-headers \
        "$WORK/x86_64-macos-signed.macho" >"$WORK/llvm-x86.actual"
    llvm-objdump --macho --private-headers \
        "$WORK/aarch64-macos-signed.macho" >"$WORK/llvm-arm.actual"
    assert_grep "LLVM signed x86-64 CodeDirectory command" \
        'cmd LC_CODE_SIGNATURE' "$WORK/llvm-x86.actual"
    assert_grep "LLVM signed AArch64 CodeDirectory command" \
        'cmd LC_CODE_SIGNATURE' "$WORK/llvm-arm.actual"
    assert_grep "LLVM signed x86-64 linkedit" \
        'segname __LINKEDIT' "$WORK/llvm-x86.actual"
    assert_grep "LLVM signed AArch64 linkedit" \
        'segname __LINKEDIT' "$WORK/llvm-arm.actual"
fi

printf '%s\n' \
    'PASS: Kofun emitted deterministic ad-hoc signed x86-64 and AArch64 Mach-O images' \
    'PASS: Kofun SHA-256 page slots agree with the independent validator' \
    'PASS: invalid CPU, code, byte, and identifier requests refuse before image writing'

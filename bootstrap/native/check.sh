#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
NATIVE="$ROOT/bootstrap/native"
KOFUN="$ROOT/bin/kofun"
WORK=${KOFUN_NATIVE_CHECK_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}native-check"}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"
ASSERT_CONTEXT=native
. "$ROOT/tests/assertions/assert.sh"

AARCH64_RUNNER=${QEMU_AARCH64-}
if test -n "$AARCH64_RUNNER" &&
   command -v "$AARCH64_RUNNER" >/dev/null 2>&1
then
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

kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"
"$WORK/kofun-stage2" \
    "$NATIVE/encoder.kofun" \
    "$WORK/encoder.kofun" \
    "$WORK/encoder.ir" \
    "$WORK/encoder.tokens" >/dev/null
cmp "$NATIVE/encoder.kofun" "$WORK/encoder.kofun"
assert_grep "encoder.ir" \
    '^function|elf64_core_answer_debug_image|0|' "$WORK/encoder.ir"
assert_grep "encoder.ir" \
    '^function|dwarf_debug_strings_for|1|' "$WORK/encoder.ir"
assert_grep "encoder.ir" '^function|dwarf_debug_info_for|8|' "$WORK/encoder.ir"
assert_grep "encoder.ir" '^function|dwarf_debug_line_for|6|' "$WORK/encoder.ir"
assert_grep "encoder.ir" '^function|pe32plus_image|2|' "$WORK/encoder.ir"
assert_grep "encoder.ir" '^function|pe32plus_entry_image|1|' "$WORK/encoder.ir"
assert_grep "encoder.ir" '^function|macho64_image|2|' "$WORK/encoder.ir"
assert_grep "encoder.ir" '^function|macho64_entry_image|1|' "$WORK/encoder.ir"
assert_grep "encoder.ir" '^function|native_sha256_absorb|2|' "$WORK/encoder.ir"
assert_grep "encoder.ir" '^function|macho64_ad_hoc_signature|3|' "$WORK/encoder.ir"
assert_grep "encoder.ir" '^function|macho64_signed_image|3|' "$WORK/encoder.ir"
assert_grep "encoder.ir" '^function|macho64_signed_entry_image|1|' "$WORK/encoder.ir"

KOFUN_NATIVE_PE32PLUS_WORK="$WORK/pe32plus" \
    sh "$NATIVE/check-pe32plus.sh"
KOFUN_NATIVE_MACHO64_WORK="$WORK/macho64" \
    sh "$NATIVE/check-macho64.sh"
KOFUN_NATIVE_MACHO64_SIGNED_WORK="$WORK/macho64-signed" \
    sh "$NATIVE/check-macho64-signed.sh"

expand_fixture() (
    fixture=$1
    stem=$2
    expected_size=$3
    emitter="$WORK/emit-$stem-rle"
    rle="$WORK/$stem.rle"
    image="$WORK/$stem.elf"

    "$KOFUN" build "$fixture" \
        -o "$emitter" \
        --emit-c "$WORK/emit-$stem-rle.c" >/dev/null
    "$emitter" >"$rle"

    : >"$image"
    pending=
    while IFS= read -r field; do
        case $field in
            ''|*[!0-9]*)
                printf '%s\n' "native-check: invalid RLE field: $field" >&2
                exit 1
                ;;
        esac

        if test -z "$pending"; then
            test "$field" -le 255 || {
                printf '%s\n' "native-check: byte outside 0..255: $field" >&2
                exit 1
            }
            pending=$field
            continue
        fi

        test "$field" -gt 0 || {
            printf '%s\n' "native-check: run length must be positive" >&2
            exit 1
        }
        octal=$(printf '%03o' "$pending")
        count=0
        while test "$count" -lt "$field"; do
            printf "\\$octal" >>"$image"
            count=$((count + 1))
        done
        pending=
    done <"$rle"

    test -z "$pending" || {
        printf '%s\n' "native-check: RLE stream ended without a run length" >&2
        exit 1
    }
    assert_num "size of $image" \
        "$(wc -c <"$image" | tr -d ' ')" -eq "$expected_size"
)

expand_fixture \
    "$NATIVE/fixtures/exit_42.rle.kofun" \
    exit_42 \
    188
expand_fixture \
    "$NATIVE/fixtures/print_sum_42.rle.kofun" \
    print_sum_42 \
    4099
expand_fixture \
    "$NATIVE/fixtures/core_answer.rle.kofun" \
    core_answer \
    231

"$NATIVE/emit-fixture.sh" \
    -o "$WORK/core_answer_release_option.elf"
cmp \
    "$WORK/core_answer.elf" \
    "$WORK/core_answer_release_option.elf"

"$NATIVE/emit-fixture.sh" \
    -g \
    -o "$WORK/core_answer_debug.elf"

CORE_SOURCE="$NATIVE/fixtures/core_return_42.kofun"
for target in x86_64-linux aarch64-linux; do
    case $target in
        x86_64-linux) stem=core_return_42-x86_64 ;;
        aarch64-linux) stem=core_return_42-aarch64 ;;
    esac
    "$KOFUN" build "$CORE_SOURCE" \
        --target "$target" -o "$WORK/$stem.elf" >/dev/null
    "$KOFUN" build "$CORE_SOURCE" \
        --target "$target" -o "$WORK/$stem.second.elf" >/dev/null
    cmp "$WORK/$stem.elf" "$WORK/$stem.second.elf"
    assert_num "size of $stem.elf" \
        "$(wc -c <"$WORK/$stem.elf" | tr -d ' ')" -eq 4099
done

DEBUG_SOURCE="bootstrap/native/fixtures/core_debug_lines_42.kofun"
(
    cd "$ROOT"
    "$KOFUN" build "$DEBUG_SOURCE" \
        --target x86_64-linux \
        -o "$WORK/core_debug_lines_42-release.elf" >/dev/null
    "$KOFUN" build "$DEBUG_SOURCE" \
        --target x86_64-linux \
        -g \
        -o "$WORK/core_debug_lines_42-debug.elf" >/dev/null
    "$KOFUN" build "$DEBUG_SOURCE" \
        --target x86_64-linux \
        -g \
        -o "$WORK/core_debug_lines_42-debug.second.elf" >/dev/null
)
cmp \
    "$WORK/core_debug_lines_42-debug.elf" \
    "$WORK/core_debug_lines_42-debug.second.elf"

# The same single-main Core carries debug metadata on AArch64. Both targets
# build the identical release image, so the debug build is compared against
# that image rather than against a target-specific expectation.
(
    cd "$ROOT"
    "$KOFUN" build "$DEBUG_SOURCE" \
        --target aarch64-linux \
        -o "$WORK/core_debug_lines_42-aarch64-release.elf" >/dev/null
    "$KOFUN" build "$DEBUG_SOURCE" \
        --target aarch64-linux \
        -g \
        -o "$WORK/core_debug_lines_42-aarch64-debug.elf" >/dev/null
    "$KOFUN" build "$DEBUG_SOURCE" \
        --target aarch64-linux \
        -g \
        -o "$WORK/core_debug_lines_42-aarch64-debug.second.elf" >/dev/null
)
cmp \
    "$WORK/core_debug_lines_42-aarch64-debug.elf" \
    "$WORK/core_debug_lines_42-aarch64-debug.second.elf"
cmp \
    "$WORK/core_return_42-aarch64.elf" \
    "$WORK/core_debug_lines_42-aarch64-release.elf"

set +e
(
    cd "$ROOT"
    "$KOFUN" build "$DEBUG_SOURCE" \
        -g \
        -o "$WORK/core_debug_lines_42-missing-target.elf"
) >"$WORK/core_debug_lines_42-missing-target.stdout" \
    2>"$WORK/core_debug_lines_42-missing-target.stderr"
missing_target_status=$?
(
    cd "$ROOT"
    "$KOFUN" build "$DEBUG_SOURCE" \
        --target wasm32 \
        -g \
        -o "$WORK/core_debug_lines_42-wasm32-debug.wasm"
) >"$WORK/core_debug_lines_42-wasm32-debug.stdout" \
    2>"$WORK/core_debug_lines_42-wasm32-debug.stderr"
wasm32_debug_status=$?
# AArch64 List/Text lowering records no source-line rows yet, so `-g` there is
# an explicit rejection instead of a debug image with an empty line table.
(
    cd "$ROOT"
    "$KOFUN" build "$NATIVE/fixtures/core_list_index_42.kofun" \
        --target aarch64-linux \
        -g \
        -o "$WORK/core_list_index_42-aarch64-debug.elf"
) >"$WORK/core_list_index_42-aarch64-debug.stdout" \
    2>"$WORK/core_list_index_42-aarch64-debug.stderr"
aarch64_aggregate_debug_status=$?
set -e
assert_num "missing target status" "$missing_target_status" -eq 2
assert_num "wasm32 debug status" "$wasm32_debug_status" -eq 2
assert_num "aarch64 aggregate debug status" \
    "$aarch64_aggregate_debug_status" -eq 1
assert_absent "core_debug_lines_42-missing-target.elf" \
    "$WORK/core_debug_lines_42-missing-target.elf"
assert_absent "core_debug_lines_42-wasm32-debug.wasm" \
    "$WORK/core_debug_lines_42-wasm32-debug.wasm"
assert_absent "core_list_index_42-aarch64-debug.elf" \
    "$WORK/core_list_index_42-aarch64-debug.elf"
assert_grep "core_debug_lines_42-missing-target.stderr" \
    -q \
    -- \
    '-g requires --target x86_64-linux or --target aarch64-linux' \
    "$WORK/core_debug_lines_42-missing-target.stderr"
assert_grep "core_debug_lines_42-wasm32-debug.stderr" \
    -q \
    -- \
    '-g currently requires --target x86_64-linux or --target aarch64-linux' \
    "$WORK/core_debug_lines_42-wasm32-debug.stderr"
assert_grep "core_list_index_42-aarch64-debug.stderr" \
    -q \
    -- \
    '-g for the AArch64 List/Text Core is not implemented yet' \
    "$WORK/core_list_index_42-aarch64-debug.stderr"

# Source formatting and debug mode must not perturb the release artifact.
cmp \
    "$WORK/core_return_42-x86_64.elf" \
    "$WORK/core_debug_lines_42-release.elf"
assert_num "size of core_debug_lines_42-release.elf" \
    "$(wc -c <"$WORK/core_debug_lines_42-release.elf" | tr -d ' ')" -eq 4099
assert_num "size of core_debug_lines_42-debug.elf" \
    "$(wc -c <"$WORK/core_debug_lines_42-debug.elf" | tr -d ' ')" -gt 4099

# Apart from the ELF section-table fields in the first 64 bytes, the complete
# loaded release image is byte-identical in the debug file.
dd if="$WORK/core_debug_lines_42-release.elf" \
    of="$WORK/core_debug_lines_42-release.loaded" \
    bs=1 skip=64 count=4035 2>/dev/null
dd if="$WORK/core_debug_lines_42-debug.elf" \
    of="$WORK/core_debug_lines_42-debug.loaded" \
    bs=1 skip=64 count=4035 2>/dev/null
cmp \
    "$WORK/core_debug_lines_42-release.loaded" \
    "$WORK/core_debug_lines_42-debug.loaded"

(
    cd "$WORK"
    "$ROOT/bin/kofun-digest" -c "$NATIVE/SHA256SUMS"
)

command -v readelf >/dev/null 2>&1 || {
    printf '%s\n' "native-check: readelf is required" >&2
    exit 1
}

for stem in exit_42 print_sum_42 core_answer core_answer_debug; do
    image="$WORK/$stem.elf"
    readelf -h "$image" >"$WORK/$stem.elf-header.txt"
    readelf -l "$image" >"$WORK/$stem.program-headers.txt"
    assert_grep "$stem.elf-header.txt" \
        -Eq 'Class:[[:space:]]+ELF64' "$WORK/$stem.elf-header.txt"
    assert_grep "$stem.elf-header.txt" \
        -Eq \
        'Machine:[[:space:]]+Advanced Micro Devices X86-64' \
        "$WORK/$stem.elf-header.txt"
    assert_grep "$stem.elf-header.txt" \
        -Eq \
        'Entry point address:[[:space:]]+0x4000b0' \
        "$WORK/$stem.elf-header.txt"
    assert_grep "$stem.elf-header.txt" \
        -Eq \
        'Number of program headers:[[:space:]]+2' \
        "$WORK/$stem.elf-header.txt"
    assert_num "LOAD lines in $stem.program-headers.txt" \
        "$(grep -c 'LOAD' "$WORK/$stem.program-headers.txt")" -eq 2
done

# Debug metadata is opt-in. The canonical 231-byte release image still has no
# section headers, while `-g` appends a complete section table and DWARF v4.
assert_grep "core_answer.elf-header.txt" \
    -Eq \
    'Number of section headers:[[:space:]]+0' \
    "$WORK/core_answer.elf-header.txt"
assert_grep "core_answer_debug.elf-header.txt" \
    -Eq \
    'Number of section headers:[[:space:]]+10' \
    "$WORK/core_answer_debug.elf-header.txt"
assert_num "size of core_answer.elf" \
    "$(wc -c <"$WORK/core_answer.elf" | tr -d ' ')" -eq 231
assert_num "size of core_answer_debug.elf" \
    "$(wc -c <"$WORK/core_answer_debug.elf" | tr -d ' ')" -eq 1360

dd if="$WORK/core_answer.elf" \
    of="$WORK/core_answer.release-program-headers" \
    bs=1 skip=64 count=112 2>/dev/null
dd if="$WORK/core_answer_debug.elf" \
    of="$WORK/core_answer.debug-program-headers" \
    bs=1 skip=64 count=112 2>/dev/null
cmp \
    "$WORK/core_answer.release-program-headers" \
    "$WORK/core_answer.debug-program-headers"

dd if="$WORK/core_answer.elf" \
    of="$WORK/core_answer.release-runtime" \
    bs=1 skip=176 count=55 2>/dev/null
dd if="$WORK/core_answer_debug.elf" \
    of="$WORK/core_answer.debug-runtime" \
    bs=1 skip=176 count=55 2>/dev/null
cmp \
    "$WORK/core_answer.release-runtime" \
    "$WORK/core_answer.debug-runtime"

readelf --wide --sections "$WORK/core_answer_debug.elf" \
    >"$WORK/core_answer_debug.sections.txt"
for section in \
    .text \
    .rodata \
    .debug_abbrev \
    .debug_info \
    .debug_line \
    .debug_str \
    .symtab \
    .strtab \
    .shstrtab
do
    assert_grep "core_answer_debug.sections.txt" \
        -F "$section" "$WORK/core_answer_debug.sections.txt"
done

readelf --wide --symbols "$WORK/core_answer_debug.elf" \
    >"$WORK/core_answer_debug.symbols.txt"
assert_grep "core_answer_debug.symbols.txt" \
    -Eq \
    '[[:space:]]FUNC[[:space:]]+GLOBAL.*[[:space:]]main$' \
    "$WORK/core_answer_debug.symbols.txt"

readelf --wide --debug-dump=info "$WORK/core_answer_debug.elf" \
    >"$WORK/core_answer_debug.info.txt"
assert_grep "core_answer_debug.info.txt" \
    -q 'DW_TAG_compile_unit' "$WORK/core_answer_debug.info.txt"
assert_grep "core_answer_debug.info.txt" \
    -q 'DW_TAG_subprogram' "$WORK/core_answer_debug.info.txt"
assert_grep "core_answer_debug.info.txt" \
    -Eq 'DW_AT_name[[:space:]]+:.*main$' "$WORK/core_answer_debug.info.txt"

readelf --wide --debug-dump=decodedline "$WORK/core_answer_debug.elf" \
    >"$WORK/core_answer_debug.lines.txt"
assert_grep "core_answer_debug.lines.txt" \
    -Eq \
    'bootstrap/native/fixtures/core_answer_debug.kofun[[:space:]]+2[[:space:]]+0x4000be' \
    "$WORK/core_answer_debug.lines.txt"
assert_grep "core_answer_debug.lines.txt" \
    -Eq \
    'bootstrap/native/fixtures/core_answer_debug.kofun[[:space:]]+6[[:space:]]+0x4000e2' \
    "$WORK/core_answer_debug.lines.txt"

readelf -h "$WORK/core_return_42-aarch64.elf" \
    >"$WORK/core_return_42-aarch64.elf-header.txt"
readelf -l "$WORK/core_return_42-aarch64.elf" \
    >"$WORK/core_return_42-aarch64.program-headers.txt"
assert_grep "core_return_42-aarch64.elf-header.txt" \
    -Eq 'Class:[[:space:]]+ELF64' "$WORK/core_return_42-aarch64.elf-header.txt"
assert_grep "core_return_42-aarch64.elf-header.txt" \
    -Eq \
    'Machine:[[:space:]]+AArch64' \
    "$WORK/core_return_42-aarch64.elf-header.txt"
assert_grep "core_return_42-aarch64.elf-header.txt" \
    -Eq \
    'Entry point address:[[:space:]]+0x4000b0' \
    "$WORK/core_return_42-aarch64.elf-header.txt"
assert_grep "core_return_42-aarch64.elf-header.txt" \
    -Eq \
    'Number of program headers:[[:space:]]+2' \
    "$WORK/core_return_42-aarch64.elf-header.txt"
assert_num "LOAD lines in core_return_42-aarch64.program-headers.txt" \
    "$(grep -c 'LOAD' "$WORK/core_return_42-aarch64.program-headers.txt")" \
    -eq 2

readelf -h "$WORK/core_debug_lines_42-release.elf" \
    >"$WORK/core_debug_lines_42-release.header.txt"
readelf -h "$WORK/core_debug_lines_42-debug.elf" \
    >"$WORK/core_debug_lines_42-debug.header.txt"
assert_grep "core_debug_lines_42-release.header.txt" \
    -Eq \
    'Number of section headers:[[:space:]]+0' \
    "$WORK/core_debug_lines_42-release.header.txt"
assert_grep "core_debug_lines_42-debug.header.txt" \
    -Eq \
    'Number of section headers:[[:space:]]+10' \
    "$WORK/core_debug_lines_42-debug.header.txt"

readelf --wide --sections "$WORK/core_debug_lines_42-debug.elf" \
    >"$WORK/core_debug_lines_42-debug.sections.txt"
for section in \
    .text \
    .data \
    .debug_abbrev \
    .debug_info \
    .debug_line \
    .debug_str \
    .symtab \
    .strtab \
    .shstrtab
do
    assert_grep "core_debug_lines_42-debug.sections.txt" \
        -F "$section" "$WORK/core_debug_lines_42-debug.sections.txt"
done

readelf --wide --symbols "$WORK/core_debug_lines_42-debug.elf" \
    >"$WORK/core_debug_lines_42-debug.symbols.txt"
assert_grep "core_debug_lines_42-debug.symbols.txt" \
    -Eq \
    '[[:space:]]FUNC[[:space:]]+GLOBAL.*[[:space:]]main$' \
    "$WORK/core_debug_lines_42-debug.symbols.txt"

readelf --wide --debug-dump=info \
    "$WORK/core_debug_lines_42-debug.elf" \
    >"$WORK/core_debug_lines_42-debug.info.txt"
assert_grep "core_debug_lines_42-debug.info.txt" \
    -q 'DW_TAG_compile_unit' "$WORK/core_debug_lines_42-debug.info.txt"
assert_grep "core_debug_lines_42-debug.info.txt" \
    -q 'DW_TAG_subprogram' "$WORK/core_debug_lines_42-debug.info.txt"
assert_grep "core_debug_lines_42-debug.info.txt" \
    -Eq \
    'DW_AT_name[[:space:]]+:.*core_debug_lines_42.kofun$' \
    "$WORK/core_debug_lines_42-debug.info.txt"
assert_grep "core_debug_lines_42-debug.info.txt" \
    -Eq \
    'DW_AT_name[[:space:]]+:.*main$' \
    "$WORK/core_debug_lines_42-debug.info.txt"

readelf --wide --debug-dump=decodedline \
    "$WORK/core_debug_lines_42-debug.elf" \
    >"$WORK/core_debug_lines_42-debug.lines.txt"
assert_grep "core_debug_lines_42-debug.lines.txt" \
    -Eq \
    'bootstrap/native/fixtures/core_debug_lines_42.kofun[[:space:]]+3[[:space:]]+0x4000b0' \
    "$WORK/core_debug_lines_42-debug.lines.txt"
assert_grep "core_debug_lines_42-debug.lines.txt" \
    -Eq \
    'bootstrap/native/fixtures/core_debug_lines_42.kofun[[:space:]]+4[[:space:]]+0x4000c1' \
    "$WORK/core_debug_lines_42-debug.lines.txt"

# The AArch64 debug image carries the same section set, the same symbol, the
# same DIEs, and the same retained source lines, at its own instruction
# addresses. The release image keeps no section table and stays byte-identical
# inside the loaded region.
readelf -h "$WORK/core_debug_lines_42-aarch64-release.elf" \
    >"$WORK/core_debug_lines_42-aarch64-release.header.txt"
readelf -h "$WORK/core_debug_lines_42-aarch64-debug.elf" \
    >"$WORK/core_debug_lines_42-aarch64-debug.header.txt"
assert_grep "core_debug_lines_42-aarch64-debug.header.txt" \
    -Eq \
    'Machine:[[:space:]]+AArch64' \
    "$WORK/core_debug_lines_42-aarch64-debug.header.txt"
assert_grep "core_debug_lines_42-aarch64-debug.header.txt" \
    -Eq \
    'Entry point address:[[:space:]]+0x4000b0' \
    "$WORK/core_debug_lines_42-aarch64-debug.header.txt"
assert_grep "core_debug_lines_42-aarch64-release.header.txt" \
    -Eq \
    'Number of section headers:[[:space:]]+0' \
    "$WORK/core_debug_lines_42-aarch64-release.header.txt"
assert_grep "core_debug_lines_42-aarch64-debug.header.txt" \
    -Eq \
    'Number of section headers:[[:space:]]+10' \
    "$WORK/core_debug_lines_42-aarch64-debug.header.txt"
assert_num "size of core_debug_lines_42-aarch64-release.elf" \
    "$(wc -c <"$WORK/core_debug_lines_42-aarch64-release.elf" | tr -d ' ')" \
    -eq 4099
assert_num "size of core_debug_lines_42-aarch64-debug.elf" \
    "$(wc -c <"$WORK/core_debug_lines_42-aarch64-debug.elf" | tr -d ' ')" \
    -gt 4099

dd if="$WORK/core_debug_lines_42-aarch64-release.elf" \
    of="$WORK/core_debug_lines_42-aarch64-release.loaded" \
    bs=1 skip=64 count=4035 2>/dev/null
dd if="$WORK/core_debug_lines_42-aarch64-debug.elf" \
    of="$WORK/core_debug_lines_42-aarch64-debug.loaded" \
    bs=1 skip=64 count=4035 2>/dev/null
cmp \
    "$WORK/core_debug_lines_42-aarch64-release.loaded" \
    "$WORK/core_debug_lines_42-aarch64-debug.loaded"

readelf --wide --sections "$WORK/core_debug_lines_42-aarch64-debug.elf" \
    >"$WORK/core_debug_lines_42-aarch64-debug.sections.txt"
for section in \
    .text \
    .data \
    .debug_abbrev \
    .debug_info \
    .debug_line \
    .debug_str \
    .symtab \
    .strtab \
    .shstrtab
do
    assert_grep "core_debug_lines_42-aarch64-debug.sections.txt" \
        -F "$section" "$WORK/core_debug_lines_42-aarch64-debug.sections.txt"
done

readelf --wide --symbols "$WORK/core_debug_lines_42-aarch64-debug.elf" \
    >"$WORK/core_debug_lines_42-aarch64-debug.symbols.txt"
assert_grep "core_debug_lines_42-aarch64-debug.symbols.txt" \
    -Eq \
    '[[:space:]]FUNC[[:space:]]+GLOBAL.*[[:space:]]main$' \
    "$WORK/core_debug_lines_42-aarch64-debug.symbols.txt"

readelf --wide --debug-dump=info \
    "$WORK/core_debug_lines_42-aarch64-debug.elf" \
    >"$WORK/core_debug_lines_42-aarch64-debug.info.txt"
assert_grep "core_debug_lines_42-aarch64-debug.info.txt" \
    -q 'DW_TAG_compile_unit' "$WORK/core_debug_lines_42-aarch64-debug.info.txt"
assert_grep "core_debug_lines_42-aarch64-debug.info.txt" \
    -q 'DW_TAG_subprogram' "$WORK/core_debug_lines_42-aarch64-debug.info.txt"
assert_grep "core_debug_lines_42-aarch64-debug.info.txt" \
    -Eq \
    'DW_AT_name[[:space:]]+:.*core_debug_lines_42.kofun$' \
    "$WORK/core_debug_lines_42-aarch64-debug.info.txt"
assert_grep "core_debug_lines_42-aarch64-debug.info.txt" \
    -Eq \
    'DW_AT_name[[:space:]]+:.*main$' \
    "$WORK/core_debug_lines_42-aarch64-debug.info.txt"

readelf --wide --debug-dump=decodedline \
    "$WORK/core_debug_lines_42-aarch64-debug.elf" \
    >"$WORK/core_debug_lines_42-aarch64-debug.lines.txt"
assert_grep "core_debug_lines_42-aarch64-debug.lines.txt" \
    -Eq \
    'bootstrap/native/fixtures/core_debug_lines_42.kofun[[:space:]]+3[[:space:]]+0x4000b0' \
    "$WORK/core_debug_lines_42-aarch64-debug.lines.txt"
assert_grep "core_debug_lines_42-aarch64-debug.lines.txt" \
    -Eq \
    'bootstrap/native/fixtures/core_debug_lines_42.kofun[[:space:]]+4[[:space:]]+0x4000bc' \
    "$WORK/core_debug_lines_42-aarch64-debug.lines.txt"
# Every AArch64 debug row must land on a 4-byte instruction boundary.
awk '
    $3 ~ /^0x[0-9a-f]+$/ {
        last = substr($3, length($3), 1)
        if (last != "0" && last != "4" && last != "8" && last != "c") {
            exit 1
        }
    }
' "$WORK/core_debug_lines_42-aarch64-debug.lines.txt"

chmod +x \
    "$WORK/exit_42.elf" \
    "$WORK/print_sum_42.elf" \
    "$WORK/core_answer.elf" \
    "$WORK/core_answer_debug.elf" \
    "$WORK/core_return_42-x86_64.elf" \
    "$WORK/core_return_42-aarch64.elf" \
    "$WORK/core_debug_lines_42-release.elf" \
    "$WORK/core_debug_lines_42-debug.elf"

# The digits are not pre-baked in the file: native arithmetic fills both zero
# bytes before write(1, buffer, 3). Only the newline starts initialized.
printf '\000\000\n' >"$WORK/print_sum_42.initial-buffer.expected"
tail -c 3 "$WORK/print_sum_42.elf" \
    >"$WORK/print_sum_42.initial-buffer"
cmp \
    "$WORK/print_sum_42.initial-buffer.expected" \
    "$WORK/print_sum_42.initial-buffer"

# Prove the compact Core image contains resolved forward call and
# RIP-relative message fixups, not zero placeholders.
call_bytes=$(od -An -tu1 -j 176 -N 5 "$WORK/core_answer.elf" |
    awk '{$1=$1; print}')
lea_bytes=$(od -An -tu1 -j 212 -N 7 "$WORK/core_answer.elf" |
    awk '{$1=$1; print}')
assert_eq "call bytes" "$call_bytes" "232 9 0 0 0"
assert_eq "lea bytes" "$lea_bytes" "72 141 53 9 0 0 0"

set +e
"$WORK/exit_42.elf" >"$WORK/exit_42.stdout" 2>"$WORK/exit_42.stderr"
status=$?
set -e
assert_num "exit_42 exit status" "$status" -eq 42
assert_file_empty "exit_42.stdout" "$WORK/exit_42.stdout"
assert_file_empty "exit_42.stderr" "$WORK/exit_42.stderr"

set +e
"$WORK/print_sum_42.elf" \
    >"$WORK/print_sum_42.stdout" \
    2>"$WORK/print_sum_42.stderr"
status=$?
set -e
assert_num "print_sum_42 exit status" "$status" -eq 0
printf '42\n' >"$WORK/print_sum_42.expected"
cmp "$WORK/print_sum_42.expected" "$WORK/print_sum_42.stdout"
assert_file_empty "print_sum_42.stderr" "$WORK/print_sum_42.stderr"

set +e
"$WORK/core_answer.elf" \
    >"$WORK/core_answer.stdout" \
    2>"$WORK/core_answer.stderr"
status=$?
set -e
assert_num "core_answer exit status" "$status" -eq 42
printf '42\n' >"$WORK/core_answer.expected"
cmp "$WORK/core_answer.expected" "$WORK/core_answer.stdout"
assert_file_empty "core_answer.stderr" "$WORK/core_answer.stderr"

set +e
"$WORK/core_answer_debug.elf" \
    >"$WORK/core_answer_debug.stdout" \
    2>"$WORK/core_answer_debug.stderr"
status=$?
set -e
assert_num "core_answer_debug exit status" "$status" -eq 42
cmp "$WORK/core_answer.expected" "$WORK/core_answer_debug.stdout"
assert_file_empty "core_answer_debug.stderr" "$WORK/core_answer_debug.stderr"

for mode in release debug; do
    set +e
    "$WORK/core_debug_lines_42-$mode.elf" \
        >"$WORK/core_debug_lines_42-$mode.stdout" \
        2>"$WORK/core_debug_lines_42-$mode.stderr"
    status=$?
    set -e
    assert_num "core_debug_lines_42-$mode exit status" "$status" -eq 0
    printf '42\n' >"$WORK/core_debug_lines_42.expected"
    cmp \
        "$WORK/core_debug_lines_42.expected" \
        "$WORK/core_debug_lines_42-$mode.stdout"
    assert_file_empty "core_debug_lines_42-$mode.stderr" \
        "$WORK/core_debug_lines_42-$mode.stderr"
done

if command -v gdb >/dev/null 2>&1; then
    (
        cd "$ROOT"
        gdb -q -nx -batch \
            -ex 'set debuginfod enabled off' \
            -ex 'set pagination off' \
            -ex 'break main' \
            -ex 'run' \
            -ex 'bt' \
            -ex 'next' \
            -ex 'next' \
            -ex 'frame' \
            "$WORK/core_answer_debug.elf"
    ) >"$WORK/core_answer_debug.gdb.txt" 2>&1
    assert_grep "core_answer_debug.gdb.txt" \
        -Eq \
        'Breakpoint 1, main .*core_answer_debug.kofun:2' \
        "$WORK/core_answer_debug.gdb.txt"
    assert_grep "core_answer_debug.gdb.txt" \
        -Eq \
        '#0[[:space:]]+main .*core_answer_debug.kofun:2' \
        "$WORK/core_answer_debug.gdb.txt"
    assert_grep "core_answer_debug.gdb.txt" \
        -Eq \
        'main .*core_answer_debug.kofun:4' \
        "$WORK/core_answer_debug.gdb.txt"

    (
        cd "$ROOT"
        gdb -q -nx -batch \
            -ex 'set debuginfod enabled off' \
            -ex 'set pagination off' \
            -ex 'break main' \
            -ex 'run' \
            -ex 'bt' \
            -ex 'next' \
            -ex 'frame' \
            "$WORK/core_debug_lines_42-debug.elf"
    ) >"$WORK/core_debug_lines_42-debug.gdb.txt" 2>&1
    assert_grep "core_debug_lines_42-debug.gdb.txt" \
        -Eq \
        'Breakpoint 1, main .*core_debug_lines_42.kofun:3' \
        "$WORK/core_debug_lines_42-debug.gdb.txt"
    assert_grep "core_debug_lines_42-debug.gdb.txt" \
        -Eq \
        '#0[[:space:]]+main .*core_debug_lines_42.kofun:3' \
        "$WORK/core_debug_lines_42-debug.gdb.txt"
    assert_grep "core_debug_lines_42-debug.gdb.txt" \
        -Eq \
        'main .*core_debug_lines_42.kofun:4' \
        "$WORK/core_debug_lines_42-debug.gdb.txt"
    printf '%s\n' \
        "PASS: gdb stepped CLI-built Kofun lines and named main in backtrace"
else
    printf '%s\n' \
        "SKIP: gdb unavailable; readelf DWARF structure was still verified"
fi

# Debug metadata may not change what the AArch64 image does. Missing tooling
# can only skip this dynamic check; the structural gates above always ran.
if test -n "$AARCH64_RUNNER"; then
    chmod +x "$WORK/core_debug_lines_42-aarch64-release.elf" \
        "$WORK/core_debug_lines_42-aarch64-debug.elf"
    set +e
    "$AARCH64_RUNNER" "$WORK/core_debug_lines_42-aarch64-release.elf" \
        >"$WORK/core_debug_lines_42-aarch64-release.stdout" \
        2>"$WORK/core_debug_lines_42-aarch64-release.stderr"
    aarch64_release_status=$?
    "$AARCH64_RUNNER" "$WORK/core_debug_lines_42-aarch64-debug.elf" \
        >"$WORK/core_debug_lines_42-aarch64-debug.stdout" \
        2>"$WORK/core_debug_lines_42-aarch64-debug.stderr"
    aarch64_debug_run_status=$?
    set -e
    assert_num "aarch64 debug run status" \
        "$aarch64_debug_run_status" -eq "$aarch64_release_status"
    cmp \
        "$WORK/core_debug_lines_42.expected" \
        "$WORK/core_debug_lines_42-aarch64-release.stdout"
    cmp \
        "$WORK/core_debug_lines_42-aarch64-release.stdout" \
        "$WORK/core_debug_lines_42-aarch64-debug.stdout"
    cmp \
        "$WORK/core_debug_lines_42-aarch64-release.stderr" \
        "$WORK/core_debug_lines_42-aarch64-debug.stderr"
    printf '%s\n' \
        "PASS: AArch64 debug image observes exactly what release observes"
else
    printf '%s\n' \
        "SKIP: AArch64 debug execution (qemu-aarch64 unavailable)"
fi

# Source stepping needs both the emulator's gdbstub and a debugger that knows
# AArch64. When either is missing this is an explicit tooling skip: the ELF and
# DWARF structure was already validated unconditionally above.
AARCH64_DEBUGGER=${KOFUN_AARCH64_GDB-}
if test -z "$AARCH64_DEBUGGER"; then
    for candidate in gdb-multiarch aarch64-linux-gnu-gdb; do
        if command -v "$candidate" >/dev/null 2>&1; then
            AARCH64_DEBUGGER=$(command -v "$candidate")
            break
        fi
    done
fi
if test -n "$AARCH64_RUNNER" && test -n "$AARCH64_DEBUGGER"; then
    gdbstub_port=${KOFUN_AARCH64_GDB_PORT:-45023}
    "$AARCH64_RUNNER" -g "$gdbstub_port" \
        "$WORK/core_debug_lines_42-aarch64-debug.elf" \
        >"$WORK/core_debug_lines_42-aarch64-gdbstub.stdout" \
        2>"$WORK/core_debug_lines_42-aarch64-gdbstub.stderr" &
    gdbstub_pid=$!
    trap 'kill -KILL "$gdbstub_pid" 2>/dev/null || true' 0 1 2 15
    (
        cd "$ROOT"
        "$AARCH64_DEBUGGER" -q -nx -batch \
            -ex 'set debuginfod enabled off' \
            -ex 'set pagination off' \
            -ex 'set architecture aarch64' \
            -ex "target remote localhost:$gdbstub_port" \
            -ex 'break main' \
            -ex 'continue' \
            -ex 'bt' \
            -ex 'next' \
            -ex 'frame' \
            -ex 'detach' \
            "$WORK/core_debug_lines_42-aarch64-debug.elf"
    ) >"$WORK/core_debug_lines_42-aarch64-debug.gdb.txt" 2>&1
    wait "$gdbstub_pid" || true
    trap - 0 1 2 15
    assert_grep "core_debug_lines_42-aarch64-debug.gdb.txt" \
        -Eq \
        'Breakpoint 1, main .*core_debug_lines_42.kofun:3' \
        "$WORK/core_debug_lines_42-aarch64-debug.gdb.txt"
    assert_grep "core_debug_lines_42-aarch64-debug.gdb.txt" \
        -Eq \
        '#0[[:space:]]+main .*core_debug_lines_42.kofun:3' \
        "$WORK/core_debug_lines_42-aarch64-debug.gdb.txt"
    assert_grep "core_debug_lines_42-aarch64-debug.gdb.txt" \
        -Eq \
        'main .*core_debug_lines_42.kofun:4' \
        "$WORK/core_debug_lines_42-aarch64-debug.gdb.txt"
    printf '%s\n' \
        "PASS: AArch64 gdb broke in Kofun main, stepped, and named the frame"
else
    printf '%s\n' \
        "SKIP: AArch64 source stepping (qemu gdbstub or AArch64 gdb unavailable)"
fi

# The same target-independent parsed Core must drive both instruction
# encoders. x86-64 executes directly; AArch64 executes under qemu when the
# emulator is installed. The C11 Stage 1 result is the reference observation.
run_native_core_differential() (
    source=$1
    name=$2

    "$KOFUN" build "$source" --backend c \
        -o "$WORK/$name-reference" \
        --emit-c "$WORK/$name-reference.c" >/dev/null
    "$KOFUN" build "$source" --target x86_64-linux \
        -o "$WORK/$name-x86_64.elf" >/dev/null
    "$KOFUN" build "$source" --target aarch64-linux \
        -o "$WORK/$name-aarch64.elf" >/dev/null

    "$WORK/$name-reference" \
        >"$WORK/$name-reference.stdout" \
        2>"$WORK/$name-reference.stderr"
    reference_status=$?
    "$WORK/$name-x86_64.elf" \
        >"$WORK/$name-x86_64.stdout" \
        2>"$WORK/$name-x86_64.stderr"
    x86_status=$?
    assert_num "x86 status" "$x86_status" -eq "$reference_status"
    cmp "$WORK/$name-reference.stdout" "$WORK/$name-x86_64.stdout"
    cmp "$WORK/$name-reference.stderr" "$WORK/$name-x86_64.stderr"

    if test -n "$AARCH64_RUNNER"; then
        "$AARCH64_RUNNER" "$WORK/$name-aarch64.elf" \
            >"$WORK/$name-aarch64.stdout" \
            2>"$WORK/$name-aarch64.stderr"
        aarch64_status=$?
        assert_num "aarch64 status" "$aarch64_status" -eq "$reference_status"
        cmp "$WORK/$name-reference.stdout" "$WORK/$name-aarch64.stdout"
        cmp "$WORK/$name-reference.stderr" "$WORK/$name-aarch64.stderr"
        printf '%s\n' "PASS: $name differential under qemu-aarch64"
    else
        printf '%s\n' \
            "SKIP: $name AArch64 execution (qemu-aarch64 unavailable)"
    fi
)

run_native_core_differential \
    "$NATIVE/fixtures/core_return_42.kofun" \
    core_return_42
run_native_core_differential \
    "$NATIVE/fixtures/core_precedence_42.kofun" \
    core_precedence_42

# The multi-function Int Core is lowered directly to native calls for both
# x86-64 and AArch64. This runs the public example rather than a reduced
# surrogate, so arbitrary-width integer printing, recursion, parameters,
# returns, and call fixups are all observable in one static ELF. x86-64
# executes directly; AArch64 executes under qemu when the emulator is present.
"$KOFUN" build "$ROOT/examples/fibonacci_native.kofun" \
    --target x86_64-linux \
    -o "$WORK/fibonacci-native.elf" >/dev/null
"$WORK/fibonacci-native.elf" \
    >"$WORK/fibonacci-native.stdout" \
    2>"$WORK/fibonacci-native.stderr"
printf '6765\n' >"$WORK/fibonacci-native.expected"
cmp "$WORK/fibonacci-native.expected" "$WORK/fibonacci-native.stdout"
assert_file_empty "fibonacci-native.stderr" "$WORK/fibonacci-native.stderr"

"$KOFUN" build "$ROOT/examples/fibonacci_native.kofun" \
    --target aarch64-linux \
    -o "$WORK/fibonacci-native-aarch64.elf" >/dev/null
readelf -h "$WORK/fibonacci-native-aarch64.elf" \
    >"$WORK/fibonacci-native-aarch64.elf-header.txt"
assert_grep "fibonacci-native-aarch64.elf-header.txt" \
    -Eq \
    'Machine:[[:space:]]+AArch64' \
    "$WORK/fibonacci-native-aarch64.elf-header.txt"

"$KOFUN" build "$NATIVE/fixtures/function_overflow.kofun" \
    --target x86_64-linux \
    -o "$WORK/function-overflow.elf" >/dev/null
"$KOFUN" build "$NATIVE/fixtures/function_overflow.kofun" \
    --target aarch64-linux \
    -o "$WORK/function-overflow-aarch64.elf" >/dev/null
set +e
"$WORK/function-overflow.elf" \
    >"$WORK/function-overflow.stdout" \
    2>"$WORK/function-overflow.stderr"
function_overflow_status=$?
"$KOFUN" build "$NATIVE/fixtures/function_unknown.kofun" \
    --target x86_64-linux \
    -o "$WORK/function-unknown.elf" \
    >"$WORK/function-unknown.stdout" \
    2>"$WORK/function-unknown.stderr"
function_unknown_status=$?
"$KOFUN" build "$NATIVE/fixtures/function_arity.kofun" \
    --target x86_64-linux \
    -o "$WORK/function-arity.elf" \
    >"$WORK/function-arity.stdout" \
    2>"$WORK/function-arity.stderr"
function_arity_status=$?
# The unknown-symbol and arity diagnostics are selected before instruction
# selection, so AArch64 rejects the same programs with the same messages.
"$KOFUN" build "$NATIVE/fixtures/function_unknown.kofun" \
    --target aarch64-linux \
    -o "$WORK/function-unknown-aarch64.elf" \
    >"$WORK/function-unknown-aarch64.stdout" \
    2>"$WORK/function-unknown-aarch64.stderr"
function_unknown_aarch64_status=$?
set -e
assert_num "function overflow status" "$function_overflow_status" -eq 1
assert_file_empty "function-overflow.stdout" "$WORK/function-overflow.stdout"
printf 'error[R010]: integer overflow in operator `*`\n' \
    >"$WORK/function-overflow.expected"
cmp "$WORK/function-overflow.expected" \
    "$WORK/function-overflow.stderr"
assert_num "function unknown status" "$function_unknown_status" -eq 1
assert_absent "function-unknown.elf" "$WORK/function-unknown.elf"
assert_grep "function-unknown.stderr" \
    'unknown native Core function `missing`' "$WORK/function-unknown.stderr"
assert_num "function arity status" "$function_arity_status" -eq 1
assert_absent "function-arity.elf" "$WORK/function-arity.elf"
assert_grep "function-arity.stderr" \
    'native Core function `add` expects 2 arguments, got 1' \
    "$WORK/function-arity.stderr"
assert_num "function unknown aarch64 status" \
    "$function_unknown_aarch64_status" -eq 1
assert_absent "function-unknown-aarch64.elf" \
    "$WORK/function-unknown-aarch64.elf"
assert_grep "function-unknown-aarch64.stderr" \
    'unknown native Core function `missing`' \
    "$WORK/function-unknown-aarch64.stderr"

# AArch64 user-defined functions now execute. Under qemu the fibonacci example
# and the checked-overflow fixture must match the x86-64 observations exactly:
# identical stdout, identical diagnostic text, and identical exit status.
if test -n "$AARCH64_RUNNER"; then
    "$AARCH64_RUNNER" "$WORK/fibonacci-native-aarch64.elf" \
        >"$WORK/fibonacci-native-aarch64.stdout" \
        2>"$WORK/fibonacci-native-aarch64.stderr"
    cmp "$WORK/fibonacci-native.expected" \
        "$WORK/fibonacci-native-aarch64.stdout"
    assert_file_empty "fibonacci-native-aarch64.stderr" \
        "$WORK/fibonacci-native-aarch64.stderr"

    set +e
    "$AARCH64_RUNNER" "$WORK/function-overflow-aarch64.elf" \
        >"$WORK/function-overflow-aarch64.stdout" \
        2>"$WORK/function-overflow-aarch64.stderr"
    function_overflow_aarch64_status=$?
    set -e
    assert_num "function overflow aarch64 status" \
        "$function_overflow_aarch64_status" -eq 1
    assert_file_empty "function-overflow-aarch64.stdout" \
        "$WORK/function-overflow-aarch64.stdout"
    cmp "$WORK/function-overflow.expected" \
        "$WORK/function-overflow-aarch64.stderr"
    printf '%s\n' \
        "PASS: fibonacci and overflow differential under qemu-aarch64"
else
    printf '%s\n' \
        "SKIP: AArch64 function execution (qemu-aarch64 unavailable)"
fi

# The bounded x86-64 compiler-shaped Text bridge uses the existing
# `[byte_length:i64][UTF-8 bytes]` ABI for two Text arguments, a returned
# Text pointer, one immutable frame local, concatenation, and print(Text).
# Build the producer directly as well as through the public CLI and require
# byte-identical static ELF output. An independent C program supplies the
# observation oracle; it is not part of Kofun artifact production.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$NATIVE/core_compiler.c" \
    -o "$WORK/kofun-native-function-text"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$NATIVE/fixtures/function_text_reference.c" \
    -o "$WORK/function-text-reference"

FUNCTION_TEXT_SOURCE="$NATIVE/fixtures/function_text_helper.kofun"
FUNCTION_TEXT_UTF8_SOURCE="$NATIVE/fixtures/function_text_helper_utf8.kofun"
"$WORK/kofun-native-function-text" \
    "$FUNCTION_TEXT_SOURCE" x86_64-linux \
    "$WORK/function-text-direct.elf"
"$WORK/kofun-native-function-text" \
    "$FUNCTION_TEXT_SOURCE" x86_64-linux \
    "$WORK/function-text-direct.second.elf"
"$KOFUN" build "$FUNCTION_TEXT_SOURCE" \
    --target x86_64-linux \
    -o "$WORK/function-text-cli.elf" >/dev/null
"$KOFUN" build "$FUNCTION_TEXT_SOURCE" \
    --target x86_64-linux \
    -o "$WORK/function-text-cli.second.elf" >/dev/null
cmp \
    "$WORK/function-text-direct.elf" \
    "$WORK/function-text-direct.second.elf"
cmp \
    "$WORK/function-text-direct.elf" \
    "$WORK/function-text-cli.elf"
cmp \
    "$WORK/function-text-cli.elf" \
    "$WORK/function-text-cli.second.elf"
chmod +x "$WORK/function-text-direct.elf"

"$WORK/function-text-reference" \
    >"$WORK/function-text-reference.stdout" \
    2>"$WORK/function-text-reference.stderr"
"$WORK/function-text-direct.elf" \
    >"$WORK/function-text.stdout" \
    2>"$WORK/function-text.stderr"
cmp \
    "$NATIVE/fixtures/function_text_helper.stdout" \
    "$WORK/function-text-reference.stdout"
cmp \
    "$WORK/function-text-reference.stdout" \
    "$WORK/function-text.stdout"
assert_file_empty "function-text-reference.stderr" \
    "$WORK/function-text-reference.stderr"
assert_file_empty "function-text.stderr" "$WORK/function-text.stderr"

"$WORK/kofun-native-function-text" \
    "$FUNCTION_TEXT_UTF8_SOURCE" x86_64-linux \
    "$WORK/function-text-utf8.elf"
"$KOFUN" build "$FUNCTION_TEXT_UTF8_SOURCE" \
    --target x86_64-linux \
    -o "$WORK/function-text-utf8-cli.elf" >/dev/null
cmp \
    "$WORK/function-text-utf8.elf" \
    "$WORK/function-text-utf8-cli.elf"
chmod +x "$WORK/function-text-utf8.elf"
"$WORK/function-text-reference" utf8 \
    >"$WORK/function-text-utf8-reference.stdout" \
    2>"$WORK/function-text-utf8-reference.stderr"
"$WORK/function-text-utf8.elf" \
    >"$WORK/function-text-utf8.stdout" \
    2>"$WORK/function-text-utf8.stderr"
cmp \
    "$NATIVE/fixtures/function_text_helper_utf8.stdout" \
    "$WORK/function-text-utf8-reference.stdout"
cmp \
    "$WORK/function-text-utf8-reference.stdout" \
    "$WORK/function-text-utf8.stdout"
assert_file_empty "function-text-utf8-reference.stderr" \
    "$WORK/function-text-utf8-reference.stderr"
assert_file_empty "function-text-utf8.stderr" "$WORK/function-text-utf8.stderr"

readelf -h "$WORK/function-text-direct.elf" \
    >"$WORK/function-text.header"
readelf -l "$WORK/function-text-direct.elf" \
    >"$WORK/function-text.program-headers"
assert_grep "function-text.header" \
    -Eq \
    'Machine:[[:space:]]+Advanced Micro Devices X86-64' \
    "$WORK/function-text.header"
assert_num "LOAD lines in function-text.program-headers" \
    "$(grep -c 'LOAD' "$WORK/function-text.program-headers")" -eq 2
assert_not_grep "function-text.program-headers" \
    -Eq 'INTERP|DYNAMIC' "$WORK/function-text.program-headers"

# Every unsupported signature/body is diagnosed before artifact commit.
expect_function_text_rejection() {
    stem=$1
    message=$2
    set +e
    "$KOFUN" build "$NATIVE/fixtures/$stem.kofun" \
        --target x86_64-linux \
        -o "$WORK/$stem.elf" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    rejection_status=$?
    set -e
    assert_num "rejection status" "$rejection_status" -eq 1
    assert_absent "$stem.elf" "$WORK/$stem.elf"
    grep -F "$message" "$WORK/$stem.stderr" >/dev/null
}

expect_function_text_rejection \
    function_text_wrong_arity \
    'native Core function `label` expects 2 arguments, got 1'
expect_function_text_rejection \
    function_text_wrong_argument \
    'native Core function `label` argument 1 requires Text'
expect_function_text_rejection \
    function_text_too_many_arguments \
    'native Core Text helpers support at most two arguments'
expect_function_text_rejection \
    function_text_result_mismatch \
    'native Core function must return Text'
expect_function_text_rejection \
    function_text_missing_return \
    'native Core Text function must end with return'
expect_function_text_rejection \
    function_text_mutable_local \
    'native Core mutable function locals are unsupported'
expect_function_text_rejection \
    function_text_list_signature \
    'native Core function List parameter/result types are unsupported'
expect_function_text_rejection \
    function_text_unsupported_loop \
    'unknown native Core binding `while`'
expect_function_text_rejection \
    function_text_file_operation \
    'unknown native Core function `read_text`'

# A function body used to be allowed exactly one local, and that local had to
# be annotated `Text`. Both limits are widened: an unannotated local takes its
# initializer's type, and both targets accept the same 32-slot frame boundary.
# Two Text locals in one body were a refusal until this change, so they are
# gated positively rather than merely no longer refused.
TWO_LOCALS_SOURCE="$NATIVE/fixtures/function_text_two_locals.kofun"
"$WORK/kofun-native-function-text" \
    "$TWO_LOCALS_SOURCE" x86_64-linux "$WORK/function-text-two-locals.elf"
chmod +x "$WORK/function-text-two-locals.elf"
"$WORK/function-text-two-locals.elf" \
    >"$WORK/function-text-two-locals.stdout" \
    2>"$WORK/function-text-two-locals.stderr"
cmp \
    "$NATIVE/fixtures/function_text_two_locals.stdout" \
    "$WORK/function-text-two-locals.stdout"
assert_file_empty "function-text-two-locals.stderr" \
    "$WORK/function-text-two-locals.stderr"
expect_function_text_rejection \
    function_text_local_type_mismatch \
    'native Core local `label` is not Int'

LOCAL_BOUNDARY_SOURCE="$NATIVE/fixtures/function_local_frame_boundary.kofun"
for target in x86_64-linux aarch64-linux; do
    "$KOFUN" build "$LOCAL_BOUNDARY_SOURCE" --target "$target" \
        -o "$WORK/function-local-frame-$target.elf" >/dev/null
    "$KOFUN" build "$LOCAL_BOUNDARY_SOURCE" --target "$target" \
        -o "$WORK/function-local-frame-$target.second.elf" >/dev/null
    cmp \
        "$WORK/function-local-frame-$target.elf" \
        "$WORK/function-local-frame-$target.second.elf"
done
chmod +x "$WORK/function-local-frame-x86_64-linux.elf"
"$WORK/function-local-frame-x86_64-linux.elf" \
    >"$WORK/function-local-frame.stdout" \
    2>"$WORK/function-local-frame.stderr"
printf '6\n' >"$WORK/function-local-frame.expected"
cmp \
    "$WORK/function-local-frame.expected" \
    "$WORK/function-local-frame.stdout"
assert_file_empty "function-local-frame.stderr" \
    "$WORK/function-local-frame.stderr"
if test -n "$AARCH64_RUNNER"; then
    "$AARCH64_RUNNER" "$WORK/function-local-frame-aarch64-linux.elf" \
        >"$WORK/function-local-frame-aarch64.stdout" \
        2>"$WORK/function-local-frame-aarch64.stderr"
    cmp \
        "$WORK/function-local-frame.expected" \
        "$WORK/function-local-frame-aarch64.stdout"
    assert_file_empty "function-local-frame-aarch64.stderr" \
        "$WORK/function-local-frame-aarch64.stderr"
fi
expect_function_text_rejection \
    function_too_many_locals \
    'native Core function has too many locals'

# AArch64 parity (issue #623): the same Text helper now lowers to a direct
# AArch64 ELF with the shared Text ABI. Build twice for determinism, audit the
# static image, and run the qemu differential against the pinned observation
# when the emulator is available; otherwise skip execution but still audit.
"$KOFUN" build "$FUNCTION_TEXT_SOURCE" \
    --target aarch64-linux \
    -o "$WORK/function-text-aarch64.elf" >/dev/null
"$KOFUN" build "$FUNCTION_TEXT_SOURCE" \
    --target aarch64-linux \
    -o "$WORK/function-text-aarch64.second.elf" >/dev/null
cmp \
    "$WORK/function-text-aarch64.elf" \
    "$WORK/function-text-aarch64.second.elf"
"$KOFUN" build "$FUNCTION_TEXT_UTF8_SOURCE" \
    --target aarch64-linux \
    -o "$WORK/function-text-utf8-aarch64.elf" >/dev/null

readelf -h "$WORK/function-text-aarch64.elf" \
    >"$WORK/function-text-aarch64.header"
readelf -l "$WORK/function-text-aarch64.elf" \
    >"$WORK/function-text-aarch64.program-headers"
assert_grep "function-text-aarch64.header" \
    -Eq 'Machine:[[:space:]]+AArch64' "$WORK/function-text-aarch64.header"
assert_num "LOAD lines in function-text-aarch64.program-headers" \
    "$(grep -c 'LOAD' "$WORK/function-text-aarch64.program-headers")" -eq 2
assert_not_grep "function-text-aarch64.program-headers" \
    -Eq 'INTERP|DYNAMIC' "$WORK/function-text-aarch64.program-headers"

if test -n "$AARCH64_RUNNER"; then
    chmod +x "$WORK/function-text-aarch64.elf" \
        "$WORK/function-text-utf8-aarch64.elf"
    "$AARCH64_RUNNER" "$WORK/function-text-aarch64.elf" \
        >"$WORK/function-text-aarch64.stdout" \
        2>"$WORK/function-text-aarch64.stderr"
    cmp \
        "$NATIVE/fixtures/function_text_helper.stdout" \
        "$WORK/function-text-aarch64.stdout"
    assert_file_empty "function-text-aarch64.stderr" \
        "$WORK/function-text-aarch64.stderr"
    "$AARCH64_RUNNER" "$WORK/function-text-utf8-aarch64.elf" \
        >"$WORK/function-text-utf8-aarch64.stdout" \
        2>"$WORK/function-text-utf8-aarch64.stderr"
    cmp \
        "$NATIVE/fixtures/function_text_helper_utf8.stdout" \
        "$WORK/function-text-utf8-aarch64.stdout"
    assert_file_empty "function-text-utf8-aarch64.stderr" \
        "$WORK/function-text-utf8-aarch64.stderr"
    printf '%s\n' \
        "PASS: function Text AArch64 differential under qemu-aarch64"
else
    printf '%s\n' \
        "SKIP: function Text AArch64 execution (qemu-aarch64 unavailable)"
fi

set +e
(
    ulimit -v 512
    exec "$WORK/function-text-direct.elf"
) >"$WORK/function-text-oom.stdout" \
    2>"$WORK/function-text-oom.stderr"
function_text_oom_status=$?
set -e
assert_num "function text oom status" "$function_text_oom_status" -eq 70
assert_file_empty "function-text-oom.stdout" "$WORK/function-text-oom.stdout"
printf 'kofun: out of memory\n' >"$WORK/function-text-oom.expected"
cmp \
    "$WORK/function-text-oom.expected" \
    "$WORK/function-text-oom.stderr"

# The checked provenance pins every producer/reference input and the canonical
# direct ELF. It contains repository-relative paths and a literal reproduction
# command, never a work-directory path.
provenance="$NATIVE/fixtures/function_text_provenance.txt"
while IFS='|' read -r kind path expected_digest; do
    case $kind in
        producer|source|reference|expected)
            actual_digest=$("$ROOT/bin/kofun-digest" "$ROOT/$path" | awk '{ print $1 }')
            assert_eq "$kind digest for $path" \
                "$actual_digest" "$expected_digest"
            ;;
        output)
            actual_digest=$(
                "$ROOT/bin/kofun-digest" "$WORK/function-text-direct.elf" |
                    awk '{ print $1 }'
            )
            assert_eq "provenance output digest for function-text-direct.elf" \
                "$actual_digest" "$expected_digest"
            ;;
        reproduce|'#'|'') ;;
        *)
            printf '%s\n' \
                "native-check: invalid function Text provenance row: $kind" >&2
            exit 1
            ;;
    esac
done <"$provenance"
assert_not_grep "work-directory path in the provenance file" \
    -F "$WORK" "$provenance"

# Value placement in the bounded x86-64 function profile is decided by a
# compiled allocation pass instead of a native-stack machine. The leaf helper
# below reuses its parameter twice and must read it out of a register both
# times, and no body may move `rsp` while an operand is live, which is what
# keeps every SysV call boundary 16-byte aligned. The pinned leaf prologue
# proves the register residency without freezing the rest of the body; the
# three refused byte signatures are exactly what the previous load/push/pop
# lowering emitted, so a regression to it cannot pass quietly.
REGALLOC_SOURCE="$NATIVE/fixtures/function_register_allocation.kofun"
"$WORK/kofun-native-function-text" \
    "$REGALLOC_SOURCE" x86_64-linux \
    "$WORK/function-regalloc-direct.elf"
"$KOFUN" build "$REGALLOC_SOURCE" \
    --target x86_64-linux \
    -o "$WORK/function-regalloc-cli.elf" >/dev/null
"$KOFUN" build "$REGALLOC_SOURCE" \
    --target x86_64-linux \
    -o "$WORK/function-regalloc-cli.second.elf" >/dev/null
cmp \
    "$WORK/function-regalloc-direct.elf" \
    "$WORK/function-regalloc-cli.elf"
cmp \
    "$WORK/function-regalloc-cli.elf" \
    "$WORK/function-regalloc-cli.second.elf"
chmod +x "$WORK/function-regalloc-direct.elf"
"$WORK/function-regalloc-direct.elf" \
    >"$WORK/function-regalloc.stdout" \
    2>"$WORK/function-regalloc.stderr"
printf '40\n' >"$WORK/function-regalloc.expected"
cmp \
    "$WORK/function-regalloc.expected" \
    "$WORK/function-regalloc.stdout"
assert_file_empty "function-regalloc.stderr" "$WORK/function-regalloc.stderr"

# push rbp; mov rbp, rsp; sub rsp, 0x10; mov [rbp-0x10], rbx; mov rbx, rdi;
# mov r10, rbx
regalloc_leaf=$(od -An -v -tx1 -j 192 -N 18 \
    "$WORK/function-regalloc-direct.elf" |
    awk '{$1=$1; printf "%s%s", separator, $0; separator=" "} END{print ""}')
assert_eq "regalloc leaf" \
    "$regalloc_leaf" "55 48 89 e5 48 83 ec 10 48 89 5d f0 48 8b df 4c 8b d3"

for regalloc_image in \
    "$WORK/function-regalloc-direct.elf" \
    "$WORK/fibonacci-native.elf" \
    "$WORK/function-text-direct.elf" \
    "$WORK/function-overflow.elf"
do
    regalloc_hex=$(od -An -v -tx1 "$regalloc_image" | tr -d ' \n')
    # mov rax, [rbp + disp32] followed by push rax
    ! printf '%s' "$regalloc_hex" | grep -Eq '488b85[0-9a-f]{8}50'
    # push rax; pop rdi: the previous call-argument hand-off
    ! printf '%s' "$regalloc_hex" | grep -Eq '505f'
    # pop rcx; pop rax: the previous binary-operator hand-off
    ! printf '%s' "$regalloc_hex" | grep -Eq '5958'
done

# AArch64 now decides value placement the same way, from the same
# target-independent analysis, so the same claim is gated on that target. The
# leaf below reuses its parameter twice and must read it out of a register both
# times; the pinned prologue proves the residency without freezing the rest of
# the body. The three refused byte signatures are exactly what the previous
# stack-machine lowering emitted for every operand, so a regression to it
# cannot pass quietly. The images are built twice and compared, because
# allocation must not depend on anything but the source.
for regalloc_case in \
    "function_register_allocation:$NATIVE/fixtures/function_register_allocation.kofun" \
    "fibonacci:$ROOT/examples/fibonacci_native.kofun" \
    "function_text_helper:$NATIVE/fixtures/function_text_helper.kofun" \
    "function_overflow:$NATIVE/fixtures/function_overflow.kofun"
do
    regalloc_stem=${regalloc_case%%:*}
    regalloc_source=${regalloc_case#*:}
    "$KOFUN" build "$regalloc_source" \
        --target aarch64-linux \
        -o "$WORK/$regalloc_stem-regalloc-aarch64.elf" >/dev/null
    "$KOFUN" build "$regalloc_source" \
        --target aarch64-linux \
        -o "$WORK/$regalloc_stem-regalloc-aarch64.second.elf" >/dev/null
    cmp \
        "$WORK/$regalloc_stem-regalloc-aarch64.elf" \
        "$WORK/$regalloc_stem-regalloc-aarch64.second.elf"
    regalloc_hex=$(od -An -v -tx1 \
        "$WORK/$regalloc_stem-regalloc-aarch64.elf" | tr -d ' \n')
    # str x0, [sp, #-16]!: the previous per-operand push
    ! printf '%s' "$regalloc_hex" | grep -Eq 'e00f1ff8'
    # ldr x0, [sp], #16: the previous left-operand and result pop
    ! printf '%s' "$regalloc_hex" | grep -Eq 'e00741f8'
    # ldr x1, [sp], #16: the previous right-operand pop
    ! printf '%s' "$regalloc_hex" | grep -Eq 'e10741f8'
done

# stp x29, x30, [sp, #-16]!; mov x29, sp; sub sp, sp, #0x10; mov x14, x0;
# mov x12, x14 — the parameter reaches a register and is read from it.
regalloc_leaf_aarch64=$(od -An -v -tx1 -j 192 -N 20 \
    "$WORK/function_register_allocation-regalloc-aarch64.elf" |
    awk '{$1=$1; printf "%s%s", separator, $0; separator=" "} END{print ""}')
assert_eq "regalloc leaf aarch64" \
    "$regalloc_leaf_aarch64" \
    "fd 7b bf a9 fd 03 00 91 ff 43 00 d1 ee 03 00 aa ec 03 0e aa"

if test -n "$AARCH64_RUNNER"; then
    "$AARCH64_RUNNER" \
        "$WORK/function_register_allocation-regalloc-aarch64.elf" \
        >"$WORK/function-regalloc-aarch64.stdout" \
        2>"$WORK/function-regalloc-aarch64.stderr"
    cmp \
        "$WORK/function-regalloc.expected" \
        "$WORK/function-regalloc-aarch64.stdout"
    assert_file_empty "function-regalloc-aarch64.stderr" \
        "$WORK/function-regalloc-aarch64.stderr"
    regalloc_summary="PASS: x86-64/AArch64 allocate values and ran identically"
else
    printf '%s\n' \
        "SKIP: AArch64 register-allocation execution (qemu-aarch64 unavailable)"
    regalloc_summary="PASS: AArch64 allocation pinned and audited; execution skipped"
fi

# A returned call is lowered as a branch on both targets, so recursion written
# in a returned position runs in constant stack instead of one frame per step.
# The two positive fixtures recurse three million deep — direct in
# function_tail_self, alternating between two functions in function_tail_mutual.
# Every execution below runs under an explicitly lowered 1 MiB stack limit
# rather than whatever the host happens to allow, so the result does not depend
# on the machine: three million frames cannot fit and one frame always does.
# The control fixture recurses exactly as deep with the call in a non-returned
# position and must still die on the stack under the same limit, which is what
# keeps the two positive cases from passing by accident.
#
# Each run is wrapped in its own `sh -c` so that the signal the control takes is
# reported by that shell, into that shell's discarded stderr, instead of by the
# shell running this gate.
tail_expected_self=4500001500000
tail_expected_mutual=0
tail_stack_kib=1024
bounded_stack_status() {
    # usage: bounded_stack_status PROGRAM STDOUT STDERR
    sh -c '
        ulimit -c 0
        ulimit -s '"$tail_stack_kib"'
        "$0" >"$1" 2>"$2"
        printf %s "$?"
    ' "$1" "$2" "$3" 2>/dev/null
}
for tail_case in function_tail_self function_tail_mutual; do
    tail_source="$NATIVE/fixtures/$tail_case.kofun"
    "$WORK/kofun-native-function-text" \
        "$tail_source" x86_64-linux "$WORK/$tail_case-direct.elf"
    "$KOFUN" build "$tail_source" \
        --target x86_64-linux \
        -o "$WORK/$tail_case-cli.elf" >/dev/null
    "$KOFUN" build "$tail_source" \
        --target x86_64-linux \
        -o "$WORK/$tail_case-cli.second.elf" >/dev/null
    cmp "$WORK/$tail_case-direct.elf" "$WORK/$tail_case-cli.elf"
    cmp "$WORK/$tail_case-cli.elf" "$WORK/$tail_case-cli.second.elf"
    chmod +x "$WORK/$tail_case-direct.elf"
    tail_status=$(bounded_stack_status \
        "$WORK/$tail_case-direct.elf" \
        "$WORK/$tail_case.stdout" \
        "$WORK/$tail_case.stderr")
    assert_num "tail status" "$tail_status" -eq 0
    case $tail_case in
        function_tail_self)
            printf '%s\n' "$tail_expected_self" \
                >"$WORK/$tail_case.expected"
            ;;
        *)
            printf '%s\n' "$tail_expected_mutual" \
                >"$WORK/$tail_case.expected"
            ;;
    esac
    cmp "$WORK/$tail_case.expected" "$WORK/$tail_case.stdout"
    assert_file_empty "$tail_case.stderr" "$WORK/$tail_case.stderr"

    # The AArch64 image for the same source is always built twice and audited;
    # only its execution depends on the emulator.
    "$KOFUN" build "$tail_source" \
        --target aarch64-linux \
        -o "$WORK/$tail_case-aarch64.elf" >/dev/null
    "$KOFUN" build "$tail_source" \
        --target aarch64-linux \
        -o "$WORK/$tail_case-aarch64.second.elf" >/dev/null
    cmp \
        "$WORK/$tail_case-aarch64.elf" \
        "$WORK/$tail_case-aarch64.second.elf"
    readelf -h "$WORK/$tail_case-aarch64.elf" \
        >"$WORK/$tail_case-aarch64.header"
    assert_grep "$tail_case-aarch64.header" \
        -Eq 'Machine:[[:space:]]+AArch64' "$WORK/$tail_case-aarch64.header"
    readelf -l "$WORK/$tail_case-aarch64.elf" \
        >"$WORK/$tail_case-aarch64.program-headers"
    assert_not_grep "$tail_case-aarch64.program-headers" \
        -Eq 'INTERP|DYNAMIC' "$WORK/$tail_case-aarch64.program-headers"
done

# The same depth with the call outside the returned position exhausts the
# stack, so the two cases above cannot pass by accident.
"$WORK/kofun-native-function-text" \
    "$NATIVE/fixtures/function_deep_non_tail.kofun" \
    x86_64-linux "$WORK/function-deep-non-tail.elf"
chmod +x "$WORK/function-deep-non-tail.elf"
deep_non_tail_status=$(bounded_stack_status \
    "$WORK/function-deep-non-tail.elf" \
    "$WORK/function-deep-non-tail.stdout" \
    "$WORK/function-deep-non-tail.stderr")
assert_num "deep non tail status" "$deep_non_tail_status" -eq 139
assert_file_empty "function-deep-non-tail.stdout" \
    "$WORK/function-deep-non-tail.stdout"

# The hand-off itself is pinned, so the constant-stack result above cannot come
# from anything but the branch. On x86-64 the direct case reassigns both
# parameters and jumps back to the instruction after the prologue; the mutual
# case moves the argument to the boundary, restores the one register it
# claimed, drops the frame with `leave`, and jumps to the callee, which is why
# it returns straight to this function's caller.
tail_self_edge=$(od -An -v -tx1 -j 280 -N 11 \
    "$WORK/function_tail_self-direct.elf" |
    awk '{$1=$1; printf "%s%s", separator, $0; separator=" "} END{print ""}')
assert_eq "tail self edge" "$tail_self_edge" "4d 8b e2 4d 8b eb e9 b7 ff ff ff"
tail_mutual_edge=$(od -An -v -tx1 -j 257 -N 13 \
    "$WORK/function_tail_mutual-direct.elf" |
    awk '{$1=$1; printf "%s%s", separator, $0; separator=" "} END{print ""}')
assert_eq "tail mutual edge" \
    "$tail_mutual_edge" "49 8b fa 48 8b 5d f0 c9 e9 06 00 00 00"

# AArch64 makes the same two hand-offs, now in registers rather than through
# frame slots: the direct case reassigns both parameters with `mov` and
# branches back past the prologue, and the mutual case moves the argument to
# the boundary, reloads the one register it claimed, drops the frame with
# `mov sp, x29` / `ldp x29, x30, [sp], #16`, and branches to the callee.
tail_self_edge_aarch64=$(od -An -v -tx1 -j 280 -N 12 \
    "$WORK/function_tail_self-aarch64.elf" |
    awk '{$1=$1; printf "%s%s", separator, $0; separator=" "} END{print ""}')
assert_eq "tail self edge aarch64" \
    "$tail_self_edge_aarch64" "f3 03 0c aa f4 03 0d aa ef ff ff 17"
tail_mutual_edge_aarch64=$(od -An -v -tx1 -j 256 -N 20 \
    "$WORK/function_tail_mutual-aarch64.elf" |
    awk '{$1=$1; printf "%s%s", separator, $0; separator=" "} END{print ""}')
assert_eq "tail mutual edge aarch64" \
    "$tail_mutual_edge_aarch64" \
    "e0 03 0c aa f3 07 40 f9 bf 03 00 91 fd 7b c1 a8 05 00 00 14"

if test -n "$AARCH64_RUNNER"; then
    for tail_case in function_tail_self function_tail_mutual; do
        "$AARCH64_RUNNER" "$WORK/$tail_case-aarch64.elf" \
            >"$WORK/$tail_case-aarch64.stdout" \
            2>"$WORK/$tail_case-aarch64.stderr"
        cmp \
            "$WORK/$tail_case.expected" \
            "$WORK/$tail_case-aarch64.stdout"
        assert_file_empty "$tail_case-aarch64.stderr" \
            "$WORK/$tail_case-aarch64.stderr"
    done
    tail_summary="PASS: x86-64/AArch64 returned calls branch and ran 3e6 deep"
else
    printf '%s\n' \
        "SKIP: AArch64 tail-call execution (qemu-aarch64 unavailable)"
    tail_summary="PASS: AArch64 tail-call images built/pinned; execution skipped"
fi

# Integer division. `//` and `%` are compared against the C11 backend by
# tests/conformance/functions/division_floor_signs.kofun, so what is gated here
# is what that corpus cannot express: each runtime zero-divisor operator, and
# the refusal of `/`. The divisor in every zero fixture is computed rather than
# written, so a check that only looked at literals would fail these.
#
# `/` is not defined on Int (#687): with no implicit numeric promotion it
# cannot produce a fractional value from two Ints, and truncating it while `//`
# floors would make two near-identical operators disagree on negative operands.
# Both targets must refuse it with the same diagnostic, and neither may emit an
# artifact — a backend that quietly accepted `/` again would otherwise only be
# caught by reading the disassembly.
SLASH_SOURCE="$NATIVE/fixtures/reject_slash_operator.kofun"
printf '%s\n' \
    'kofun native: unsupported function Core at byte 282: native Core `/` is not defined on Int; use `//` for the integer quotient' \
    >"$WORK/reject-slash.expected"
for slash_target in x86_64-linux aarch64-linux; do
    set +e
    "$WORK/kofun-native-function-text" \
        "$SLASH_SOURCE" "$slash_target" "$WORK/reject-slash-$slash_target.elf" \
        >"$WORK/reject-slash-$slash_target.stdout" \
        2>"$WORK/reject-slash-$slash_target.stderr"
    slash_status=$?
    set -e
    assert_num "slash status" "$slash_status" -ne 0
    assert_file_empty "reject-slash-$slash_target.stdout" \
        "$WORK/reject-slash-$slash_target.stdout"
    cmp "$WORK/reject-slash.expected" "$WORK/reject-slash-$slash_target.stderr"
    assert_file_empty "reject-slash-$slash_target.elf" \
        "$WORK/reject-slash-$slash_target.elf"
done

printf 'error[R010]: operator `//` failed: division by zero\n' \
    >"$WORK/function_floor_divide_zero.expected"
printf 'error[R010]: operator `%%` failed: division by zero\n' \
    >"$WORK/function_floor_modulo_zero.expected"
for divide_case in \
    function_floor_divide_zero \
    function_floor_modulo_zero
do
    divide_source="$NATIVE/fixtures/$divide_case.kofun"
    "$WORK/kofun-native-function-text" \
        "$divide_source" x86_64-linux "$WORK/$divide_case.elf"
    chmod +x "$WORK/$divide_case.elf"
    set +e
    "$WORK/$divide_case.elf" \
        >"$WORK/$divide_case.stdout" \
        2>"$WORK/$divide_case.stderr"
    divide_status=$?
    set -e
    assert_num "$divide_case exit status" "$divide_status" -eq 1
    assert_file_empty "$divide_case.stdout" "$WORK/$divide_case.stdout"
    cmp "$WORK/$divide_case.expected" "$WORK/$divide_case.stderr"
done

# The function profile can construct INT64_MIN from accepted small literals,
# so the non-representable quotient guard is executable evidence rather than
# an unreachable code-path claim. The quotient operator must reject
# INT64_MIN // -1; modulo by -1 remains exactly zero.
printf 'error[R010]: integer overflow in operator `//`\n' \
    >"$WORK/function_floor_divide_overflow.expected"
for divide_case in \
    function_floor_divide_overflow
do
    divide_source="$NATIVE/fixtures/$divide_case.kofun"
    "$WORK/kofun-native-function-text" \
        "$divide_source" x86_64-linux "$WORK/$divide_case.elf"
    chmod +x "$WORK/$divide_case.elf"
    set +e
    "$WORK/$divide_case.elf" \
        >"$WORK/$divide_case.stdout" \
        2>"$WORK/$divide_case.stderr"
    divide_status=$?
    set -e
    assert_num "$divide_case exit status" "$divide_status" -eq 1
    assert_file_empty "$divide_case.stdout" "$WORK/$divide_case.stdout"
    cmp "$WORK/$divide_case.expected" "$WORK/$divide_case.stderr"
done

MODULO_MIN_SOURCE="$NATIVE/fixtures/function_floor_modulo_min.kofun"
"$WORK/kofun-native-function-text" \
    "$MODULO_MIN_SOURCE" x86_64-linux "$WORK/function-floor-modulo-min.elf"
chmod +x "$WORK/function-floor-modulo-min.elf"
"$WORK/function-floor-modulo-min.elf" \
    >"$WORK/function-floor-modulo-min.stdout" \
    2>"$WORK/function-floor-modulo-min.stderr"
printf '0\n' >"$WORK/function-floor-modulo-min.expected"
cmp \
    "$WORK/function-floor-modulo-min.expected" \
    "$WORK/function-floor-modulo-min.stdout"
assert_file_empty "function-floor-modulo-min.stderr" \
    "$WORK/function-floor-modulo-min.stderr"

# AArch64 divides with `sdiv`, which unlike `idiv` never faults: a zero divisor
# silently yields zero there. Both guards therefore have to be emitted, and the
# images are built twice and audited whether or not the emulator is present.
for divide_case in \
    function_floor_divide_zero \
    function_floor_modulo_zero \
    function_floor_divide_overflow \
    function_floor_modulo_min
do
    divide_source="$NATIVE/fixtures/$divide_case.kofun"
    "$KOFUN" build "$divide_source" --target aarch64-linux \
        -o "$WORK/$divide_case-aarch64.elf" >/dev/null
    "$KOFUN" build "$divide_source" --target aarch64-linux \
        -o "$WORK/$divide_case-aarch64.second.elf" >/dev/null
    cmp \
        "$WORK/$divide_case-aarch64.elf" \
        "$WORK/$divide_case-aarch64.second.elf"
    readelf -h "$WORK/$divide_case-aarch64.elf" \
        >"$WORK/$divide_case-aarch64.header"
    assert_grep "$divide_case-aarch64.header" \
        -Eq 'Machine:[[:space:]]+AArch64' "$WORK/$divide_case-aarch64.header"
done

if test -n "$AARCH64_RUNNER"; then
    for divide_case in \
        function_floor_divide_zero \
        function_floor_modulo_zero
    do
        set +e
        "$AARCH64_RUNNER" "$WORK/$divide_case-aarch64.elf" \
            >"$WORK/$divide_case-aarch64.stdout" \
            2>"$WORK/$divide_case-aarch64.stderr"
        divide_status=$?
        set -e
        assert_num "$divide_case exit status (aarch64)" "$divide_status" -eq 1
        assert_file_empty "$divide_case-aarch64.stdout" \
            "$WORK/$divide_case-aarch64.stdout"
        cmp \
            "$WORK/$divide_case.expected" \
            "$WORK/$divide_case-aarch64.stderr"
    done
    for divide_case in \
        function_floor_divide_overflow
    do
        set +e
        "$AARCH64_RUNNER" "$WORK/$divide_case-aarch64.elf" \
            >"$WORK/$divide_case-aarch64.stdout" \
            2>"$WORK/$divide_case-aarch64.stderr"
        divide_status=$?
        set -e
        assert_num "$divide_case exit status (aarch64)" "$divide_status" -eq 1
        assert_file_empty "$divide_case-aarch64.stdout" \
            "$WORK/$divide_case-aarch64.stdout"
        cmp \
            "$WORK/$divide_case.expected" \
            "$WORK/$divide_case-aarch64.stderr"
    done
    "$AARCH64_RUNNER" "$WORK/function_floor_modulo_min-aarch64.elf" \
        >"$WORK/function-floor-modulo-min-aarch64.stdout" \
        2>"$WORK/function-floor-modulo-min-aarch64.stderr"
    cmp \
        "$WORK/function-floor-modulo-min.expected" \
        "$WORK/function-floor-modulo-min-aarch64.stdout"
    assert_file_empty "function-floor-modulo-min-aarch64.stderr" \
        "$WORK/function-floor-modulo-min-aarch64.stderr"
    divide_summary="PASS: x86-64/AArch64 divide, floor, and reject zero/non-representable quotients alike"
else
    printf '%s\n' \
        "SKIP: AArch64 division execution (qemu-aarch64 unavailable)"
    divide_summary="PASS: AArch64 division/trap images built/audited; execution skipped"
fi

# The function profile accepts literal magnitudes through INT64_MAX. Exercise
# each native immediate-encoding boundary; the pre-existing divide gates above
# independently retain all three INT64_MIN/-1 runtime boundaries.
INT64_SOURCE="$NATIVE/fixtures/function_int64_boundaries.kofun"
"$WORK/kofun-native-function-text" \
    "$INT64_SOURCE" x86_64-linux "$WORK/function-int64-direct.elf"
"$KOFUN" build "$INT64_SOURCE" --target x86_64-linux \
    -o "$WORK/function-int64-cli.elf" >/dev/null
cmp "$WORK/function-int64-direct.elf" "$WORK/function-int64-cli.elf"
chmod +x "$WORK/function-int64-direct.elf"
"$WORK/function-int64-direct.elf" \
    >"$WORK/function-int64.stdout" 2>"$WORK/function-int64.stderr"
printf '%s\n' \
    9223372036854775807 \
    -9223372036854775808 \
    9223372036854775806 \
    -9223372036854775807 \
    0 \
    -9223372036854775808 \
    65535 \
    65536 \
    2147483647 \
    2147483648 \
    4294967295 \
    4294967296 \
    -2147483648 \
    -2147483649 \
    -4294967296 \
    >"$WORK/function-int64.expected"
cmp "$WORK/function-int64.expected" "$WORK/function-int64.stdout"
assert_file_empty "function-int64.stderr" "$WORK/function-int64.stderr"

for int64_target in x86_64-linux aarch64-linux; do
    too_large="$WORK/function-int64-too-large-$int64_target.elf"
    set +e
    "$KOFUN" build "$NATIVE/fixtures/function_int64_too_large.kofun" \
        --target "$int64_target" -o "$too_large" \
        >"$WORK/function-int64-too-large-$int64_target.stdout" \
        2>"$WORK/function-int64-too-large-$int64_target.stderr"
    too_large_status=$?
    set -e
    assert_num "too large status" "$too_large_status" -eq 1
    assert_absent "too large" "$too_large"
    assert_file_empty "function-int64-too-large-$int64_target.stdout" \
        "$WORK/function-int64-too-large-$int64_target.stdout"
    assert_grep "function-int64-too-large-$int64_target.stderr" \
        -F \
        "native Core integer literal exceeds 9223372036854775807" \
        "$WORK/function-int64-too-large-$int64_target.stderr"
done
cmp \
    "$WORK/function-int64-too-large-x86_64-linux.stderr" \
    "$WORK/function-int64-too-large-aarch64-linux.stderr"

"$KOFUN" build "$INT64_SOURCE" --target aarch64-linux \
    -o "$WORK/function_int64_boundaries-aarch64.elf" >/dev/null
"$KOFUN" build "$INT64_SOURCE" --target aarch64-linux \
    -o "$WORK/function_int64_boundaries-aarch64.second.elf" >/dev/null
cmp "$WORK/function_int64_boundaries-aarch64.elf" \
    "$WORK/function_int64_boundaries-aarch64.second.elf"

if test -n "$AARCH64_RUNNER"; then
    "$AARCH64_RUNNER" "$WORK/function_int64_boundaries-aarch64.elf" \
        >"$WORK/function-int64-aarch64.stdout" \
        2>"$WORK/function-int64-aarch64.stderr"
    cmp "$WORK/function-int64.expected" "$WORK/function-int64-aarch64.stdout"
    assert_file_empty "function-int64-aarch64.stderr" \
        "$WORK/function-int64-aarch64.stderr"
    int64_summary="PASS: x86-64/AArch64 carry wide Int64 values at every encoding boundary"
else
    printf '%s\n' \
        "SKIP: AArch64 Int64 literal execution (qemu-aarch64 unavailable)"
    int64_summary="PASS: AArch64 wide-Int64 image built/audited; execution skipped"
fi

# All arithmetic failures share one write/exit runtime and keep their exact
# messages in the RW page. This fixture references all seven trap kinds at
# once; both PT_LOAD segments must remain inside their fixed one-page budgets.
# There is no `/` trap pair: `/` is not defined on Int (#687).
TRAP_PRESSURE_SOURCE="$NATIVE/fixtures/function_all_traps_pressure.kofun"
for trap_target in x86_64-linux aarch64-linux; do
    trap_image="$WORK/function-all-traps-$trap_target.elf"
    "$KOFUN" build "$TRAP_PRESSURE_SOURCE" --target "$trap_target" \
        -o "$trap_image" >/dev/null
    "$KOFUN" build "$TRAP_PRESSURE_SOURCE" --target "$trap_target" \
        -o "$trap_image.second" >/dev/null
    cmp "$trap_image" "$trap_image.second"
    LC_ALL=C readelf -lW "$trap_image" >"$trap_image.program-headers"
    awk '
        $1 == "LOAD" {
            loads += 1
            if (loads == 1 &&
                !($2 == "0x000000" &&
                  $3 == "0x0000000000400000" &&
                  $4 == "0x0000000000400000" &&
                  $5 == $6 &&
                  $7 == "R" &&
                  $8 == "E" &&
                  $9 == "0x1000")) invalid = 1
            if (loads == 2 &&
                !($2 == "0x001000" &&
                  $3 == "0x0000000000401000" &&
                  $4 == "0x0000000000401000" &&
                  $6 == "0x001000" &&
                  $7 == "RW" &&
                  $8 == "0x1000")) invalid = 1
        }
        END {
            if (loads != 2 || invalid) exit 1
        }
    ' "$trap_image.program-headers"
    trap_rx_size=$(
        awk \
            '$1 == "LOAD" && $7 == "R" && $8 == "E" { print $5 }' \
            "$trap_image.program-headers"
    )
    trap_rw_size=$(
        awk '$1 == "LOAD" && $7 == "RW" { print $5 }' \
            "$trap_image.program-headers"
    )
    assert_nonempty "trap rx size" "$trap_rx_size"
    assert_nonempty "trap rw size" "$trap_rw_size"
    assert_num "$((trap_rx_size))" "$((trap_rx_size))" -le 4096
    assert_num "$((trap_rw_size))" "$((trap_rw_size))" -le 4096
done

printf '42\n42\n42\n42\n42\n42\n' \
    >"$WORK/function-all-traps.expected"
chmod +x "$WORK/function-all-traps-x86_64-linux.elf"
"$WORK/function-all-traps-x86_64-linux.elf" \
    >"$WORK/function-all-traps.stdout" \
    2>"$WORK/function-all-traps.stderr"
cmp "$WORK/function-all-traps.expected" "$WORK/function-all-traps.stdout"
assert_file_empty "function-all-traps.stderr" "$WORK/function-all-traps.stderr"

if test -n "$AARCH64_RUNNER"; then
    "$AARCH64_RUNNER" "$WORK/function-all-traps-aarch64-linux.elf" \
        >"$WORK/function-all-traps-aarch64.stdout" \
        2>"$WORK/function-all-traps-aarch64.stderr"
    cmp \
        "$WORK/function-all-traps.expected" \
        "$WORK/function-all-traps-aarch64.stdout"
    assert_file_empty "function-all-traps-aarch64.stderr" \
        "$WORK/function-all-traps-aarch64.stderr"
    trap_pressure_summary="PASS: all x86-64/AArch64 R010 traps fit and execute"
else
    printf '%s\n' \
        "SKIP: AArch64 all-trap execution (qemu-aarch64 unavailable)"
    trap_pressure_summary="PASS: all AArch64 R010 traps fit the RX/RW pages"
fi

# The self-host driver's success corpus is out of reach of the single-`main`
# aggregate Core and inside the function profile, so it reaches a native image
# only through the fallback. `bootstrap/selfhost/native/` runs the full
# two-path differential; what is gated here is that the fallback itself is
# deterministic and produces the same image through the CLI and directly.
ANSWER_SOURCE="$ROOT/bootstrap/selfhost/driver/corpus_answer.kofun"
"$WORK/kofun-native-function-text" \
    "$ANSWER_SOURCE" x86_64-linux "$WORK/corpus-answer-direct.elf"
"$KOFUN" build "$ANSWER_SOURCE" --target x86_64-linux \
    -o "$WORK/corpus-answer-cli.elf" >/dev/null
cmp "$WORK/corpus-answer-direct.elf" "$WORK/corpus-answer-cli.elf"
chmod +x "$WORK/corpus-answer-direct.elf"
"$WORK/corpus-answer-direct.elf" \
    >"$WORK/corpus-answer.stdout" \
    2>"$WORK/corpus-answer.stderr"
cmp \
    "$ROOT/bootstrap/selfhost/driver/corpus_answer.stdout" \
    "$WORK/corpus-answer.stdout"
assert_file_empty "corpus-answer.stderr" "$WORK/corpus-answer.stderr"

# Debug information belongs to the aggregate single-main profile. A source that
# reaches the function profile only through fallback stays an explicit,
# transactional rejection under `-g`.
set +e
"$KOFUN" build "$ANSWER_SOURCE" --target x86_64-linux -g \
    -o "$WORK/corpus-answer-debug.elf" \
    >"$WORK/corpus-answer-debug.stdout" \
    2>"$WORK/corpus-answer-debug.stderr"
answer_debug_status=$?
set -e
assert_num "answer debug status" "$answer_debug_status" -eq 1
assert_absent "corpus-answer-debug.elf" "$WORK/corpus-answer-debug.elf"
assert_grep "corpus-answer-debug.stderr" \
    -F 'unsupported Core' "$WORK/corpus-answer-debug.stderr"

# List[Int] uses the same Core AST and value ABI on x86-64 and AArch64. An
# independent C11 executable is the normative Python-free differential
# reference for bindings, indexing, map, filter, fold, and their edge cases.
# Every AArch64 case is built twice and audited even without qemu.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$NATIVE/fixtures/list_int_reference.c" \
    -o "$WORK/core-list-reference"
LIST_CORPUS="$ROOT/tests/conformance/list"

# The aggregate Core promises exactly one known Int print in 10..99. Preserve
# literal List contents across a local binding for validation, and require the
# shared frontend to refuse every boundary shape before target selection. This
# gives AArch64 evidence even when qemu-aarch64 is unavailable.
for print_bound_case in \
    index_print_above_bound \
    index_print_negative \
    index_print_single_digit \
    index_print_zero
do
    for print_bound_target in x86_64-linux aarch64-linux
    do
        print_bound_stem="$print_bound_case-$print_bound_target"
        set +e
        "$KOFUN" build "$LIST_CORPUS/$print_bound_case.kofun" \
            --target "$print_bound_target" \
            -o "$WORK/$print_bound_stem.elf" \
            >"$WORK/$print_bound_stem.stdout" \
            2>"$WORK/$print_bound_stem.stderr"
        print_bound_status=$?
        set -e
        assert_num "$print_bound_stem status" "$print_bound_status" -eq 1
        assert_absent "$print_bound_stem.elf" "$WORK/$print_bound_stem.elf"
        assert_file_empty "$print_bound_stem.stdout" \
            "$WORK/$print_bound_stem.stdout"
        assert_grep "$print_bound_stem.stderr" \
            -F 'unsupported Core' "$WORK/$print_bound_stem.stderr"
    done
done

run_native_list_differential() {
    source=$1
    stem=$2
    mode=$3
    "$KOFUN" build "$source" \
        --target x86_64-linux \
        -o "$WORK/$stem-x86_64.elf" >/dev/null
    "$KOFUN" build "$source" \
        --target aarch64-linux \
        -o "$WORK/$stem-aarch64.elf" >/dev/null
    "$KOFUN" build "$source" \
        --target aarch64-linux \
        -o "$WORK/$stem-aarch64.second.elf" >/dev/null
    cmp \
        "$WORK/$stem-aarch64.elf" \
        "$WORK/$stem-aarch64.second.elf"
    readelf -h "$WORK/$stem-aarch64.elf" \
        >"$WORK/$stem-aarch64.header"
    assert_grep "$stem-aarch64.header" \
        -Eq 'Machine:[[:space:]]+AArch64' "$WORK/$stem-aarch64.header"
    "$WORK/core-list-reference" "$mode" \
        >"$WORK/$stem-reference.stdout"
    "$WORK/$stem-x86_64.elf" \
        >"$WORK/$stem.stdout" \
        2>"$WORK/$stem.stderr"
    cmp "$WORK/$stem-reference.stdout" "$WORK/$stem.stdout"
    assert_file_empty "$stem.stderr" "$WORK/$stem.stderr"

    if test -n "$AARCH64_RUNNER"; then
        "$AARCH64_RUNNER" "$WORK/$stem-aarch64.elf" \
            >"$WORK/$stem-aarch64.stdout" \
            2>"$WORK/$stem-aarch64.stderr"
        cmp \
            "$WORK/$stem-reference.stdout" \
            "$WORK/$stem-aarch64.stdout"
        assert_file_empty "$stem-aarch64.stderr" "$WORK/$stem-aarch64.stderr"
    fi
}

run_native_list_differential \
    "$LIST_CORPUS/negative_index.kofun" \
    core-list-index \
    index-negative
run_native_list_differential \
    "$LIST_CORPUS/binding_index.kofun" \
    core-list-positive \
    binding
run_native_list_differential \
    "$LIST_CORPUS/length.kofun" \
    core-list-len \
    length
run_native_list_differential \
    "$LIST_CORPUS/binding_index.kofun" \
    core-list-binding \
    binding
run_native_list_differential \
    "$LIST_CORPUS/map_runtime.kofun" \
    core-list-map \
    map
run_native_list_differential \
    "$LIST_CORPUS/filter_runtime.kofun" \
    core-list-filter \
    filter
run_native_list_differential \
    "$LIST_CORPUS/fold_runtime.kofun" \
    core-list-fold \
    fold
run_native_list_differential \
    "$LIST_CORPUS/pipeline_runtime.kofun" \
    core-list-pipeline \
    pipeline
run_native_list_differential \
    "$LIST_CORPUS/empty_map.kofun" \
    core-list-empty-map \
    empty-map
run_native_list_differential \
    "$LIST_CORPUS/empty_filter.kofun" \
    core-list-empty-filter \
    empty-filter
run_native_list_differential \
    "$LIST_CORPUS/empty_fold.kofun" \
    core-list-empty-fold \
    empty-fold
run_native_list_differential \
    "$LIST_CORPUS/filter_all_false.kofun" \
    core-list-all-false \
    all-false
run_native_list_differential \
    "$LIST_CORPUS/filter_negative_values.kofun" \
    core-list-negative-predicate \
    negative-predicate
"$KOFUN" build "$LIST_CORPUS/index_out_of_range.kofun" \
    --target x86_64-linux \
    -o "$WORK/core-list-variable-oob-x86_64.elf" >/dev/null
"$KOFUN" build "$LIST_CORPUS/index_out_of_range.kofun" \
    --target aarch64-linux \
    -o "$WORK/core-list-variable-oob-aarch64.elf" >/dev/null
"$KOFUN" build "$LIST_CORPUS/index_out_of_range.kofun" \
    --target aarch64-linux \
    -o "$WORK/core-list-variable-oob-aarch64.second.elf" >/dev/null
cmp \
    "$WORK/core-list-variable-oob-aarch64.elf" \
    "$WORK/core-list-variable-oob-aarch64.second.elf"
readelf -h "$WORK/core-list-variable-oob-aarch64.elf" \
    >"$WORK/core-list-variable-oob-aarch64.header"
assert_grep "core-list-variable-oob-aarch64.header" \
    -Eq \
    'Machine:[[:space:]]+AArch64' \
    "$WORK/core-list-variable-oob-aarch64.header"

# At 2560 KiB the source and map output allocations both succeed. The chained
# filter/map/fold case needs a third 1 MiB mmap and must take the exact OOM
# path. This proves the failure is observed during real multi-allocation
# higher-order execution rather than only while materializing a source literal.
(
    ulimit -v 2560
    exec "$WORK/core-list-map-x86_64.elf"
) >"$WORK/core-list-two-allocations.stdout" \
    2>"$WORK/core-list-two-allocations.stderr"
cmp \
    "$WORK/core-list-map-reference.stdout" \
    "$WORK/core-list-two-allocations.stdout"
assert_file_empty "core-list-two-allocations.stderr" \
    "$WORK/core-list-two-allocations.stderr"

set +e
"$WORK/core-list-variable-oob-x86_64.elf" \
    >"$WORK/core-list-oob.stdout" \
    2>"$WORK/core-list-oob.stderr"
list_oob_status=$?
(
    ulimit -v 2560
    exec "$WORK/core-list-pipeline-x86_64.elf"
) >"$WORK/core-list-oom.stdout" 2>"$WORK/core-list-oom.stderr"
list_oom_status=$?
if test -n "$AARCH64_RUNNER"; then
    "$AARCH64_RUNNER" "$WORK/core-list-variable-oob-aarch64.elf" \
        >"$WORK/core-list-oob-aarch64.stdout" \
        2>"$WORK/core-list-oob-aarch64.stderr"
    list_oob_aarch64_status=$?
fi
set -e

assert_num "list oob status" "$list_oob_status" -eq 1
assert_file_empty "core-list-oob.stdout" "$WORK/core-list-oob.stdout"
printf 'kofun: list index out of range\n' \
    >"$WORK/core-list-oob.expected"
cmp "$WORK/core-list-oob.expected" "$WORK/core-list-oob.stderr"
assert_num "list oom status" "$list_oom_status" -eq 70
assert_file_empty "core-list-oom.stdout" "$WORK/core-list-oom.stdout"
printf 'kofun: out of memory\n' >"$WORK/core-list-oom.expected"
cmp "$WORK/core-list-oom.expected" "$WORK/core-list-oom.stderr"
if test -n "$AARCH64_RUNNER"; then
    assert_num "list oob aarch64 status" "$list_oob_aarch64_status" -eq 1
    assert_file_empty "core-list-oob-aarch64.stdout" \
        "$WORK/core-list-oob-aarch64.stdout"
    cmp \
        "$WORK/core-list-oob.expected" \
        "$WORK/core-list-oob-aarch64.stderr"
    printf '%s\n' \
        "PASS: AArch64 List differential under $AARCH64_RUNNER"
else
    printf '%s\n' \
        "SKIP: AArch64 List execution (qemu-aarch64 unavailable)"
fi

# Text uses `[byte length: i64][UTF-8 bytes]` on both native targets. Each
# generated static ELF is compared with an independent C11 codepoint scanner,
# including multi-byte Japanese, accented Latin, and emoji input. AArch64
# images are always built twice and audited; qemu adds exact execution parity.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$NATIVE/fixtures/text_reference.c" \
    -o "$WORK/core-text-reference"

run_native_text_differential() {
    source=$1
    stem=$2
    mode=$3
    "$KOFUN" build "$source" \
        --target x86_64-linux \
        -o "$WORK/$stem.elf" >/dev/null
    "$KOFUN" build "$source" \
        --target aarch64-linux \
        -o "$WORK/$stem-aarch64.elf" >/dev/null
    "$KOFUN" build "$source" \
        --target aarch64-linux \
        -o "$WORK/$stem-aarch64.second.elf" >/dev/null
    cmp \
        "$WORK/$stem-aarch64.elf" \
        "$WORK/$stem-aarch64.second.elf"
    readelf -h "$WORK/$stem-aarch64.elf" \
        >"$WORK/$stem-aarch64.header"
    assert_grep "$stem-aarch64.header" \
        -Eq 'Machine:[[:space:]]+AArch64' "$WORK/$stem-aarch64.header"
    "$WORK/core-text-reference" "$mode" \
        >"$WORK/$stem.reference"
    "$WORK/$stem.elf" \
        >"$WORK/$stem.stdout" \
        2>"$WORK/$stem.stderr"
    cmp "$WORK/$stem.reference" "$WORK/$stem.stdout"
    assert_file_empty "$stem.stderr" "$WORK/$stem.stderr"
    if test -n "$AARCH64_RUNNER"; then
        "$AARCH64_RUNNER" "$WORK/$stem-aarch64.elf" \
            >"$WORK/$stem-aarch64.stdout" \
            2>"$WORK/$stem-aarch64.stderr"
        cmp "$WORK/$stem.reference" "$WORK/$stem-aarch64.stdout"
        assert_file_empty "$stem-aarch64.stderr" "$WORK/$stem-aarch64.stderr"
    fi
}

run_native_text_differential \
    "$NATIVE/fixtures/core_text_concat.kofun" \
    core-text-concat \
    concat
run_native_text_differential \
    "$NATIVE/fixtures/core_text_equal.kofun" \
    core-text-equal \
    equal
run_native_text_differential \
    "$NATIVE/fixtures/core_text_not_equal.kofun" \
    core-text-not-equal \
    not-equal
run_native_text_differential \
    "$NATIVE/fixtures/core_text_len_42.kofun" \
    core-text-len-42 \
    len
run_native_text_differential \
    "$NATIVE/fixtures/core_text_index.kofun" \
    core-text-index \
    index
run_native_text_differential \
    "$NATIVE/fixtures/core_text_negative_index.kofun" \
    core-text-negative-index \
    negative-index
run_native_text_differential \
    "$NATIVE/fixtures/core_text_chars_index.kofun" \
    core-text-chars-index \
    chars-index
run_native_text_differential \
    "$NATIVE/fixtures/core_text_empty_chars_len_42.kofun" \
    core-text-empty-chars-len-42 \
    empty-chars-len

"$KOFUN" build "$NATIVE/fixtures/core_text_oob.kofun" \
    --target x86_64-linux \
    -o "$WORK/core-text-oob.elf" >/dev/null
"$KOFUN" build "$NATIVE/fixtures/core_text_oob.kofun" \
    --target aarch64-linux \
    -o "$WORK/core-text-oob-aarch64.elf" >/dev/null
"$KOFUN" build "$NATIVE/fixtures/core_text_oob.kofun" \
    --target aarch64-linux \
    -o "$WORK/core-text-oob-aarch64.second.elf" >/dev/null
cmp \
    "$WORK/core-text-oob-aarch64.elf" \
    "$WORK/core-text-oob-aarch64.second.elf"
readelf -h "$WORK/core-text-oob-aarch64.elf" \
    >"$WORK/core-text-oob-aarch64.header"
assert_grep "core-text-oob-aarch64.header" \
    -Eq 'Machine:[[:space:]]+AArch64' "$WORK/core-text-oob-aarch64.header"
{
    printf 'fn main() {\n    print("'
    printf '\300\257'
    printf '")\n}\n'
} >"$WORK/core-text-invalid-utf8.kofun"
set +e
"$WORK/core-text-oob.elf" \
    >"$WORK/core-text-oob.stdout" \
    2>"$WORK/core-text-oob.stderr"
text_oob_status=$?
"$KOFUN" build "$WORK/core-text-invalid-utf8.kofun" \
    --target x86_64-linux \
    -o "$WORK/core-text-invalid-utf8.elf" \
    >"$WORK/core-text-invalid-utf8.stdout" \
    2>"$WORK/core-text-invalid-utf8.stderr"
text_invalid_utf8_status=$?
(
    ulimit -v 512
    exec "$WORK/core-text-concat.elf"
) >"$WORK/core-text-oom.stdout" 2>"$WORK/core-text-oom.stderr"
text_oom_status=$?
if test -n "$AARCH64_RUNNER"; then
    "$AARCH64_RUNNER" "$WORK/core-text-oob-aarch64.elf" \
        >"$WORK/core-text-oob-aarch64.stdout" \
        2>"$WORK/core-text-oob-aarch64.stderr"
    text_oob_aarch64_status=$?
fi
set -e

assert_num "text oob status" "$text_oob_status" -eq 1
assert_file_empty "core-text-oob.stdout" "$WORK/core-text-oob.stdout"
printf 'kofun: text index out of range\n' \
    >"$WORK/core-text-oob.expected"
cmp "$WORK/core-text-oob.expected" "$WORK/core-text-oob.stderr"
assert_num "text invalid utf8 status" "$text_invalid_utf8_status" -eq 1
assert_absent "core-text-invalid-utf8.elf" "$WORK/core-text-invalid-utf8.elf"
assert_grep "core-text-invalid-utf8.stderr" \
    'error\[EUNICODE001\]' "$WORK/core-text-invalid-utf8.stderr"
assert_num "text oom status" "$text_oom_status" -eq 70
assert_file_empty "core-text-oom.stdout" "$WORK/core-text-oom.stdout"
printf 'kofun: out of memory\n' >"$WORK/core-text-oom.expected"
cmp "$WORK/core-text-oom.expected" "$WORK/core-text-oom.stderr"
if test -n "$AARCH64_RUNNER"; then
    assert_num "text oob aarch64 status" "$text_oob_aarch64_status" -eq 1
    assert_file_empty "core-text-oob-aarch64.stdout" \
        "$WORK/core-text-oob-aarch64.stdout"
    cmp \
        "$WORK/core-text-oob.expected" \
        "$WORK/core-text-oob-aarch64.stderr"
    printf '%s\n' \
        "PASS: AArch64 Text differential under $AARCH64_RUNNER"
else
    printf '%s\n' \
        "SKIP: AArch64 Text execution (qemu-aarch64 unavailable)"
fi

if cmp -s \
    "$WORK/core_return_42-aarch64.elf" \
    "$WORK/core_precedence_42-aarch64.elf"
then
    printf '%s\n' \
        "native-check: distinct Core programs emitted identical code" >&2
    exit 1
fi

# e_machine is little-endian 183 and the first five instructions prove that
# the AArch64 image computes (6 + 1) * 6 instead of embedding output bytes.
machine_bytes=$(od -An -tu1 -j 18 -N 2 \
    "$WORK/core_return_42-aarch64.elf" | awk '{$1=$1; print}')
core_bytes=$(od -An -tu1 -j 176 -N 20 \
    "$WORK/core_return_42-aarch64.elf" |
    awk '{$1=$1; printf "%s%s", separator, $0; separator=" "} END{print ""}')
assert_eq "machine bytes" "$machine_bytes" "183 0"
assert_eq "core bytes" \
    "$core_bytes" \
    "192 0 128 210 33 0 128 210 0 0 1 139 193 0 128 210 0 124 1 155"

if command -v llvm-objdump >/dev/null 2>&1; then
    llvm-objdump -d --triple=aarch64 \
        "$WORK/core_return_42-aarch64.elf" \
        >"$WORK/core_return_42-aarch64.disassembly"
    assert_grep "core_return_42-aarch64.disassembly" \
        -Eq \
        'mov[[:space:]]+x0, #0x6' \
        "$WORK/core_return_42-aarch64.disassembly"
    assert_grep "core_return_42-aarch64.disassembly" \
        -Eq \
        'add[[:space:]]+x0, x0, x1' \
        "$WORK/core_return_42-aarch64.disassembly"
    assert_grep "core_return_42-aarch64.disassembly" \
        -Eq \
        'mul[[:space:]]+x0, x0, x1' \
        "$WORK/core_return_42-aarch64.disassembly"
    assert_grep "core_return_42-aarch64.disassembly" \
        -Eq \
        'udiv[[:space:]]+x4, x0, x3' \
        "$WORK/core_return_42-aarch64.disassembly"
    assert_grep "core_return_42-aarch64.disassembly" \
        -Eq 'svc[[:space:]]+#0' "$WORK/core_return_42-aarch64.disassembly"
fi

unsupported="$WORK/unsupported-native-core.elf"
set +e
"$KOFUN" build "$NATIVE/fixtures/unsupported_native_core.kofun" \
    --target aarch64-linux -o "$unsupported" \
    >"$WORK/unsupported-native-core.stdout" \
    2>"$WORK/unsupported-native-core.stderr"
unsupported_status=$?
set -e
assert_num "unsupported status" "$unsupported_status" -eq 1
assert_absent "unsupported" "$unsupported"
assert_grep "unsupported-native-core.stderr" \
    'unsupported Core' "$WORK/unsupported-native-core.stderr"

# The Linux syscall intrinsics.
#
# `stdlib/linux_x86_64/abi.kofun` declares `__linux_syscall0` through
# `__linux_syscall6` and builds its entire `raw_*` layer on them. Until this
# lowering existed no compiler implemented the intrinsic, so none of that layer
# executed — and the three gates that appeared to cover it check that the
# declarations are present with `grep`, which a declaration satisfies whether or
# not anything can run it. This section is the difference: the fixtures below
# are that layer's own bodies, and what follows observes the kernel's answers.
SYSCALL_PROBE_SOURCE="$NATIVE/fixtures/function_syscall_probe.kofun"
"$WORK/kofun-native-function-text" \
    "$SYSCALL_PROBE_SOURCE" x86_64-linux \
    "$WORK/function-syscall-probe.elf"
"$KOFUN" build "$SYSCALL_PROBE_SOURCE" \
    --target x86_64-linux \
    -o "$WORK/function-syscall-probe-cli.elf" >/dev/null
cmp \
    "$WORK/function-syscall-probe.elf" \
    "$WORK/function-syscall-probe-cli.elf"
chmod +x "$WORK/function-syscall-probe.elf"

# The probe returns 0 only when all seven arities executed and every argument
# reached the register the kernel ABI names for it; any other status is the
# step that disagreed, and the fixture says which. Its standard output is the
# head of a fresh anonymous mapping — memory the kernel guarantees is zeroed —
# placed there by `raw_write(1, address, 32)`, so the bytes prove that call
# carried the address and the length rather than merely returning a plausible
# number. Both observations are required: a boundary register swapped with
# `rax` still exits 0, and is caught by the byte count.
set +e
"$WORK/function-syscall-probe.elf" \
    >"$WORK/function-syscall-probe.stdout" \
    2>"$WORK/function-syscall-probe.stderr"
syscall_probe_status=$?
set -e
assert_num "syscall probe status" "$syscall_probe_status" -eq 0
assert_file_empty "function-syscall-probe.stderr" \
    "$WORK/function-syscall-probe.stderr"
: >"$WORK/function-syscall-zeros"
syscall_zero_count=0
while test "$syscall_zero_count" -lt 32; do
    printf '\000' >>"$WORK/function-syscall-zeros"
    syscall_zero_count=$((syscall_zero_count + 1))
done
cmp \
    "$WORK/function-syscall-zeros" \
    "$WORK/function-syscall-probe.stdout"

# `raw_exit(97)` leaves with exactly that status, observed rather than inferred.
# Empty standard output is the second half of the observation: the `print` that
# follows the call never ran, so the process left through the syscall and not
# through the profile's own epilogue.
"$WORK/kofun-native-function-text" \
    "$NATIVE/fixtures/function_syscall_exit_status.kofun" x86_64-linux \
    "$WORK/function-syscall-exit.elf"
chmod +x "$WORK/function-syscall-exit.elf"
set +e
"$WORK/function-syscall-exit.elf" \
    >"$WORK/function-syscall-exit.stdout" \
    2>"$WORK/function-syscall-exit.stderr"
syscall_exit_status=$?
set -e
assert_num "syscall exit status" "$syscall_exit_status" -eq 97
assert_file_empty "function-syscall-exit.stdout" \
    "$WORK/function-syscall-exit.stdout"
assert_file_empty "function-syscall-exit.stderr" \
    "$WORK/function-syscall-exit.stderr"

# `syscall` destroys rcx and r11, and r11 is one of the two caller-saved
# registers this backend hands to evaluation depths. The fixture keeps two
# products live across the instruction and prints an exact answer, so a lost
# value is a wrong number rather than a crash.
"$WORK/kofun-native-function-text" \
    "$NATIVE/fixtures/function_syscall_live_values.kofun" x86_64-linux \
    "$WORK/function-syscall-live.elf"
chmod +x "$WORK/function-syscall-live.elf"
"$WORK/function-syscall-live.elf" \
    >"$WORK/function-syscall-live.stdout" \
    2>"$WORK/function-syscall-live.stderr"
cmp \
    "$NATIVE/fixtures/function_syscall_live_values.stdout" \
    "$WORK/function-syscall-live.stdout"
assert_file_empty "function-syscall-live.stderr" \
    "$WORK/function-syscall-live.stderr"

expect_function_text_rejection \
    function_syscall_redefined \
    'native Core cannot define the intrinsic `__linux_syscall1`'
expect_function_text_rejection \
    function_syscall_wrong_arity \
    'native Core intrinsic `__linux_syscall1` expects 2 arguments, got 1'
expect_function_text_rejection \
    function_syscall_text_argument \
    'native Core intrinsic `__linux_syscall3` argument 3 requires Int'

# AArch64 enters the kernel through a different boundary and is a separate
# checkpoint, so the same source is diagnosed there instead of producing an
# image whose intrinsics mean nothing.
syscall_aarch64="$WORK/function-syscall-probe-aarch64.elf"
set +e
"$KOFUN" build "$SYSCALL_PROBE_SOURCE" \
    --target aarch64-linux -o "$syscall_aarch64" \
    >"$WORK/function-syscall-aarch64.stdout" \
    2>"$WORK/function-syscall-aarch64.stderr"
syscall_aarch64_status=$?
set -e
assert_num "syscall aarch64 status" "$syscall_aarch64_status" -eq 1
assert_absent "syscall aarch64 image" "$syscall_aarch64"
assert_grep "function-syscall-aarch64.stderr" \
    'lower on x86_64-linux only' "$WORK/function-syscall-aarch64.stderr"

if test -n "$AARCH64_RUNNER"; then
    text_summary="PASS: x86-64/AArch64 Text matched C11 UTF-8 semantics"
else
    text_summary="PASS: AArch64 Text built/audited; execution explicitly skipped"
fi

printf '%s\n' \
    "PASS: Kofun emitted deterministic 188-, 231-, and 4099-byte ELF64 images" \
    "PASS: native image exited through Linux x86-64 syscall with status 42" \
    "PASS: native code computed 40 + 2, wrote 42 to stdout, and exited 0" \
    "PASS: rel32 Core call/message fixups printed and exited with 42" \
    "PASS: opt-in debug image has ELF sections, DWARF lines, and a main DIE" \
    "PASS: release Core image remains byte-identical and 231 bytes" \
    "PASS: build --target x86_64-linux -g emitted source-specific DWARF" \
    "PASS: build --target aarch64-linux -g emitted the same DWARF contract" \
    "PASS: general Native Core release stayed byte-identical and 4099 bytes" \
    "PASS: --target aarch64-linux emitted deterministic static EM_AARCH64 ELF" \
    "PASS: x86-64 and AArch64 consume one target-independent parsed Core" \
    "PASS: x86-64 Text-returning functions match the audited C reference" \
    "PASS: function Text determinism, OOM, provenance, and rejection gates pass" \
    "PASS: x86-64 function values stay in registers with no operand push/pop" \
    "$regalloc_summary" \
    "$tail_summary" \
    "$divide_summary" \
    "$int64_summary" \
    "$trap_pressure_summary" \
    "PASS: the self-host success corpus reaches a deterministic native image" \
    "PASS: x86-64/AArch64 List/Text Cores use shared ABIs and diagnostics" \
    "PASS: x86-64 List execution matched C11 with OOB/OOM contracts" \
    "PASS: all seven __linux_syscall arities executed with the kernel ABI registers" \
    "PASS: raw_exit left with status 97 and raw_write put 32 mapped bytes on stdout" \
    "$text_summary"

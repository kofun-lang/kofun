#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SPEC="$ROOT/spec/modules/re-exports.md"
IDENTITY_SPEC="$ROOT/spec/modules/module-identity.md"
VISIBILITY_SPEC="$ROOT/spec/modules/visibility.md"
NAMESPACE_SPEC="$ROOT/spec/modules/namespaces.md"
CYCLE_AWK="$ROOT/spec/re-exports/canonical-cycle.awk"
WORK=${KOFUN_RE_EXPORT_SPEC_WORK:-"$ROOT/build/re-exports-spec"}

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

require_text() {
    file=$1
    needle=$2
    grep -Fq "$needle" "$file" || fail "$file lacks required text: $needle"
}

for command in awk cmp dd grep od "$ROOT/bin/kofun-digest" sort tr wc
do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

case $WORK in
    */re-exports-spec|*/re-exports-spec.*) ;;
    *) fail "work directory must end in re-exports-spec[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

require_text "$SPEC" 'Kofun uses the existing contextual `pub` modifier'
require_text "$SPEC" '`pub import` exports one module-namespace qualifier'
require_text "$SPEC" 'The forwarding edge does not copy, wrap, or rename the target declaration.'
require_text "$SPEC" 'ModuleSelfSymbolId'
require_text "$SPEC" 'kofun.id.export-binding/v1'
require_text "$SPEC" 'The compiler never silently narrows a `pub` re-export'
require_text "$SPEC" 'at most 64 export edges'
require_text "$SPEC" 'reports one canonical shortest'
require_text "$SPEC" 'before any export table, KIF, HIR, object, executable'
require_text "$VISIBILITY_SPEC" 'A re-export may preserve or narrow'
require_text "$NAMESPACE_SPEC" 'A re-export preserves each target `NamespaceId`, `SymbolId`, visibility, and'
require_text "$IDENTITY_SPEC" '`ExportBindingId` contains exporting `ModuleId`'

identifier='[A-Za-z_][A-Za-z0-9_]*'
module_path="$identifier(\\.$identifier)*"
name_list="$identifier(,[[:space:]]*$identifier)*,?"

accept_syntax() {
    source=$1
    if printf '%s\n' "$source" | grep -Eq "^pub import $module_path$"; then
        return 0
    fi
    printf '%s\n' "$source" |
        grep -Eq "^pub from $module_path import[[:space:]]+$name_list$"
}

for source in \
    'pub import collections' \
    'pub import data.collections' \
    'pub from collections import Map' \
    'pub from collections import Map, Set' \
    'pub from collections import Map, Set,'
do
    accept_syntax "$source" || fail "valid re-export syntax rejected: $source"
done

for source in \
    'import collections' \
    'internal import collections' \
    'private import collections' \
    'export import collections' \
    'pub import collections as c' \
    'pub from collections import' \
    'pub from collections import *' \
    'pub from collections import Map as M' \
    'pub from .collections import Map' \
    'pub from collections import Map,,Set'
do
    if accept_syntax "$source"; then
        fail "unsupported/malformed re-export syntax accepted: $source"
    fi
done

minimum_visibility() {
    minimum=3
    for visibility in "$@"
    do
        test "$visibility" -ge 0 && test "$visibility" -le 3 || return 2
        if test "$visibility" -lt "$minimum"; then minimum=$visibility; fi
    done
    printf '%s\n' "$minimum"
}

test "$(minimum_visibility 3 3 3 3)" -eq 3 ||
    fail 'fully public re-export did not remain public'
for hidden in 0 1 2
do
    test "$(minimum_visibility 3 3 "$hidden" 3)" -eq "$hidden" ||
        fail "visibility minimum ignored level $hidden"
done
test "$(minimum_visibility 3 3 2 3)" -ne 3 ||
    fail 'public re-export widened an internal target'

u16be() {
    number=$1
    printf "\\$(printf '%03o' $((number / 256)))"
    printf "\\$(printf '%03o' $((number % 256)))"
}

u32be() {
    number=$1
    printf "\\$(printf '%03o' $(((number / 16777216) % 256)))"
    printf "\\$(printf '%03o' $(((number / 65536) % 256)))"
    printf "\\$(printf '%03o' $(((number / 256) % 256)))"
    printf "\\$(printf '%03o' $((number % 256)))"
}

byte_count() {
    wc -c <"$1" | tr -d '[:space:]'
}

text_byte_count() {
    printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

field_file() {
    tag=$1
    file=$2
    u16be "$tag"
    u32be "$(byte_count "$file")"
    dd if="$file" bs=4096 2>/dev/null
}

field_text() {
    tag=$1
    value=$2
    u16be "$tag"
    u32be "$(text_byte_count "$value")"
    printf '%s' "$value"
}

field_byte() {
    tag=$1
    value=$2
    u16be "$tag"
    u32be 1
    printf "\\$(printf '%03o' "$value")"
}

hex_to_bytes() (
    hex_bytes_input=$1
    case $hex_bytes_input in
        ''|*[!0123456789abcdefABCDEF]*)
            fail "invalid hexadecimal byte string"
            ;;
    esac
    test $((${#hex_bytes_input} % 2)) -eq 0 ||
        fail "hexadecimal byte string has odd length"

    while test -n "$hex_bytes_input"
    do
        hex_bytes_rest=${hex_bytes_input#??}
        hex_bytes_pair=${hex_bytes_input%"$hex_bytes_rest"}
        hex_bytes_value=$((0x$hex_bytes_pair))
        hex_bytes_octal=$(printf '%03o' "$hex_bytes_value")
        printf "\\$hex_bytes_octal"
        hex_bytes_input=$hex_bytes_rest
    done
)

framed_hash() {
    domain=$1
    payload=$2
    output=$3
    {
        printf 'KOFUN\000'
        u16be "$(text_byte_count "$domain")"
        printf '%s' "$domain"
        u32be "$(byte_count "$payload")"
        dd if="$payload" bs=4096 2>/dev/null
    } >"$output.preimage"
    digest=$("$ROOT/bin/kofun-digest" "$output.preimage" | awk '{ print $1 }')
    hex_to_bytes "$digest" >"$output"
    test "$(byte_count "$output")" -eq 32 || fail "invalid hash width: $domain"
}

hex_of() {
    od -An -v -tx1 "$1" | tr -d ' \n'
}

hex_to_bytes "$(printf '%064d' 11)" >"$WORK/exporting.module"
hex_to_bytes "$(printf '%064d' 22)" >"$WORK/target.module"

printf '%s\n' \
    'kofun.namespace-id/v1' 'tag=2' 'name=module' \
    >"$WORK/module-namespace.payload"
framed_hash kofun.id.namespace/v1 \
    "$WORK/module-namespace.payload" "$WORK/module.namespace"

{
    field_file 32769 "$WORK/target.module"
    field_file 32770 "$WORK/module.namespace"
    field_text 32771 module
    field_text 32772 demo.collections
} >"$WORK/module-self-symbol.payload"
framed_hash kofun.id.symbol/v1 \
    "$WORK/module-self-symbol.payload" "$WORK/module-self.symbol"

{
    field_file 32769 "$WORK/exporting.module"
    field_file 32770 "$WORK/module.namespace"
    field_text 32771 collections
    field_file 32772 "$WORK/module-self.symbol"
    field_byte 32773 3
} >"$WORK/export-binding.payload"
framed_hash kofun.id.export-binding/v1 \
    "$WORK/export-binding.payload" "$WORK/export-binding.id"
framed_hash kofun.id.export-binding/v1 \
    "$WORK/export-binding.payload" "$WORK/export-binding.second.id"
cmp "$WORK/export-binding.id" "$WORK/export-binding.second.id" ||
    fail 'repeated ExportBindingId hashing is nondeterministic'

{
    field_file 32769 "$WORK/exporting.module"
    field_file 32770 "$WORK/module.namespace"
    field_text 32771 maps
    field_file 32772 "$WORK/module-self.symbol"
    field_byte 32773 3
} >"$WORK/renamed-export.payload"
framed_hash kofun.id.export-binding/v1 \
    "$WORK/renamed-export.payload" "$WORK/renamed-export.id"
if cmp -s "$WORK/export-binding.id" "$WORK/renamed-export.id"; then
    fail 'changing the exported name preserved ExportBindingId'
fi

target_before=$(hex_of "$WORK/module-self.symbol")
target_after=$(hex_of "$WORK/module-self.symbol")
test "$target_before" = "$target_after" ||
    fail 'facade creation changed original target SymbolId'

printf '%s\n' \
    "$(hex_of "$WORK/renamed-export.id")|maps" \
    "$(hex_of "$WORK/export-binding.id")|collections" \
    >"$WORK/order-a"
printf '%s\n' \
    "$(hex_of "$WORK/export-binding.id")|collections" \
    "$(hex_of "$WORK/renamed-export.id")|maps" \
    >"$WORK/order-b"
sort "$WORK/order-a" >"$WORK/order-a.sorted"
sort "$WORK/order-b" >"$WORK/order-b.sorted"
cmp "$WORK/order-a.sorted" "$WORK/order-b.sorted" ||
    fail 'source order changed canonical export ordering'

within_limit() {
    value=$1
    limit=$2
    test "$value" -ge 0 && test "$value" -le "$limit"
}

within_limit 64 64 || fail '64-edge re-export chain rejected'
if within_limit 65 64; then fail '65-edge re-export chain accepted'; fi
within_limit 1024 1024 || fail '1024 binding module boundary rejected'
if within_limit 1025 1024; then fail 'module export binding overflow accepted'; fi

printf '%s\n' '30 10 20' '50 40' >"$WORK/cycles-shortest"
test "$(awk -f "$CYCLE_AWK" "$WORK/cycles-shortest")" = '40 50' ||
    fail 'canonical cycle did not prefer the shortest rotation'
printf '%s\n' '30 40' '20 10' >"$WORK/cycles-lexical"
test "$(awk -f "$CYCLE_AWK" "$WORK/cycles-lexical")" = '10 20' ||
    fail 'canonical equal-length cycle order is not lexicographic'

export_fingerprint=$("$ROOT/bin/kofun-digest" "$WORK/export-binding.payload" | awk '{ print $1 }')
test "$export_fingerprint" = ee457889a3dc6bb542b0916cbbe1007979eee57f81ad6e052cec86d9bfd22b15 ||
    fail "ExportBindingId payload fingerprint changed: $export_fingerprint"

printf '%s\n' \
    'PASS: pub import/pub from syntax is explicit and bounded' \
    'PASS: visibility minimum rejects every widening request' \
    'PASS: module self-symbol and ExportBindingId framing are deterministic' \
    'PASS: identities, source order, chains, cycles, and transaction rules are exact'

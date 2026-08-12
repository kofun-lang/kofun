#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/modules/top-level-declarations"
CC=${CC:-cc}
WORK=${KOFUN_MODULE_SYMBOLS_WORK:-"$ROOT/build/module-symbols"}
PACKAGE_ID=1111111111111111111111111111111111111111111111111111111111111111
ALPHA_MODULE=2222222222222222222222222222222222222222222222222222222222222222
BETA_MODULE=3333333333333333333333333333333333333333333333333333333333333333
ALPHA_FILE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BETA_FILE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
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

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
case $WORK in
    */module-symbols|*/module-symbols.*) ;;
    *) fail "work directory must end in module-symbols[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/tmp"
export TMPDIR="$WORK/tmp"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    "$ROOT/bootstrap/stage2/module_symbols.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    -o "$WORK/kofun-module-symbols"

sed -n 's/.*"\(E2S[0-9][0-9]*\)".*/\1/p' \
    "$ROOT/bootstrap/stage2/module_symbols.c" | sort -u \
    >"$WORK/observed.codes"
cmp "$CASES/codes.txt" "$WORK/observed.codes" ||
    fail 'focused diagnostic code inventory differs from the collector'

id_for() {
    printf '%s' "$1" | "$ROOT/bin/kofun-digest" | awk '{ print $1 }'
}

write_one_inventory() {
    stem=$1
    source=$2
    logical=${3:-"$stem.kofun"}
    module_id=$(id_for "module:$stem")
    file_id=$(id_for "file:$stem")
    printf '%s|%s|%s|%s|%s\n' \
        "$PACKAGE_ID" "$module_id" "$file_id" "$logical" "$source" \
        >"$WORK/$stem.inventory"
}

printf '%s|%s|%s|%s|%s\n' \
    "$PACKAGE_ID" "$ALPHA_MODULE" "$ALPHA_FILE" \
    'src/alpha.kofun' "$CASES/alpha.kofun" \
    >"$WORK/positive.inventory"
printf '%s|%s|%s|%s|%s\n' \
    "$PACKAGE_ID" "$BETA_MODULE" "$BETA_FILE" \
    'src/beta.kofun' "$CASES/beta.kofun" \
    >>"$WORK/positive.inventory"

"$WORK/kofun-module-symbols" "$WORK/positive.inventory" "$WORK/positive.out"
"$WORK/kofun-module-symbols" "$WORK/positive.inventory" "$WORK/positive.second.out"
cmp "$WORK/positive.out" "$WORK/positive.second.out" ||
    fail 'repeated declaration-table output differs'
cmp "$CASES/positive.out" "$WORK/positive.out" ||
    fail 'declaration-table golden differs'

tail -r "$WORK/positive.inventory" >"$WORK/reverse.inventory" 2>/dev/null ||
    sed '1!G;h;$!d' "$WORK/positive.inventory" >"$WORK/reverse.inventory"
"$WORK/kofun-module-symbols" "$WORK/reverse.inventory" "$WORK/reverse.out"
cmp "$WORK/positive.out" "$WORK/reverse.out" ||
    fail 'inventory argument order changed canonical output'

printf '%s|%s|%s|%s|%s\n' \
    "$PACKAGE_ID" "$ALPHA_MODULE" "$ALPHA_FILE" \
    'src/alpha.kofun' "$CASES/alpha_reordered.kofun" \
    >"$WORK/reordered.inventory"
"$WORK/kofun-module-symbols" "$WORK/reordered.inventory" "$WORK/reordered.out"
grep '^decl|' "$WORK/positive.out" | sed 's/|visibility=.*//' | grep 'module=0' \
    >"$WORK/positive.ids"
grep '^decl|' "$WORK/reordered.out" | sed 's/|visibility=.*//' \
    >"$WORK/reordered.ids"
cmp "$WORK/positive.ids" "$WORK/reordered.ids" ||
    fail 'declaration order changed NamespaceId/SymbolId sets'

printf '%s|%s|%s|%s|%s\n' \
    "$PACKAGE_ID" "$ALPHA_MODULE" "$ALPHA_FILE" \
    'generated/remapped-alpha.kofun' "$CASES/alpha.kofun" \
    >"$WORK/remapped.inventory"
"$WORK/kofun-module-symbols" "$WORK/remapped.inventory" "$WORK/remapped.out"
grep '^decl|' "$WORK/remapped.out" | sed 's/|visibility=.*//' >"$WORK/remapped.ids"
cmp "$WORK/positive.ids" "$WORK/remapped.ids" ||
    fail 'logical/host path remap changed semantic identities'

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

framed_hash() {
    domain=$1
    payload=$2
    output=$3
    {
        printf 'KOFUN\000'
        u16be "$(printf '%s' "$domain" | wc -c | tr -d '[:space:]')"
        printf '%s' "$domain"
        u32be "$(wc -c <"$payload" | tr -d '[:space:]')"
        dd if="$payload" bs=4096 2>/dev/null
    } >"$output.preimage"
    "$ROOT/bin/kofun-digest" "$output.preimage" | awk '{ print $1 }'
}

printf '%s\n' \
    'kofun.namespace-id/v1' 'tag=0' 'name=value' \
    >"$WORK/value.namespace.payload"
value_namespace=$(framed_hash kofun.id.namespace/v1 \
    "$WORK/value.namespace.payload" "$WORK/value.namespace")
{
    u16be 32769
    u32be 32
    hex_to_bytes "$ALPHA_MODULE"
    u16be 32770
    u32be 32
    hex_to_bytes "$value_namespace"
    u16be 32771
    u32be 8
    printf '%s' function
    u16be 32772
    u32be 5
    printf '%s' start
} >"$WORK/start.symbol.payload"
expected_start=$(framed_hash kofun.id.symbol/v1 \
    "$WORK/start.symbol.payload" "$WORK/start.symbol")
grep -F "kind=function|name=start|symbol=$expected_start" "$WORK/positive.out" \
    >/dev/null || fail 'C11 SymbolId does not match the normative shell framing'

expect_failure() {
    stem=$1
    code=$2
    set +e
    "$WORK/kofun-module-symbols" "$WORK/$stem.inventory" "$WORK/$stem.out" \
        >"$WORK/$stem.actual" 2>"$WORK/$stem.internal.stderr"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$stem exited $status instead of 1"
    test ! -s "$WORK/$stem.internal.stderr" || fail "$stem wrote internal stderr"
    test ! -e "$WORK/$stem.out" || fail "$stem committed a rejected table"
    cmp "$CASES/$stem.stderr" "$WORK/$stem.actual" ||
        fail "$stem diagnostic differs"
    grep -F "error[$code]:" "$WORK/$stem.actual" >/dev/null ||
        fail "$stem expected $code"
    printf '%s\n' "PASS module-symbol diagnostic: $stem"
}

duplicate_module=$(id_for 'module:duplicate-module')
printf '%s|%s|%s|%s|%s\n' \
    'INVALID' "$duplicate_module" "$(id_for 'file:invalid-inventory')" \
    'src/invalid.kofun' "$CASES/alpha.kofun" \
    >"$WORK/invalid_inventory.inventory"
printf '%s|%s|%s|%s|%s\n' \
    "$PACKAGE_ID" "$duplicate_module" "$(id_for 'file:duplicate-a')" \
    'src/a.kofun' "$CASES/alpha.kofun" \
    >"$WORK/duplicate_module.inventory"
printf '%s|%s|%s|%s|%s\n' \
    "$PACKAGE_ID" "$duplicate_module" "$(id_for 'file:duplicate-b')" \
    'src/b.kofun' "$CASES/beta.kofun" \
    >>"$WORK/duplicate_module.inventory"

for stem in duplicate_function function_constructor_collision duplicate_adt \
    duplicate_constructor malformed_function malformed_adt body_local_function \
    unknown_call import_deferred \
    trust_duplicate trust_detached trust_unattached trust_unknown_class \
    trust_spaced_class trust_trailing_text trust_anonymous \
    trust_ordinary_identifier
do
    write_one_inventory "$stem" "$CASES/$stem.kofun"
done

printf '%s|%s|%s|%s|%s\n' \
    "$PACKAGE_ID" "$(id_for 'module:cross-alpha')" "$(id_for 'file:cross-alpha')" \
    'src/cross-alpha.kofun' "$CASES/cross_module_alpha.kofun" \
    >"$WORK/cross_module.inventory"
printf '%s|%s|%s|%s|%s\n' \
    "$PACKAGE_ID" "$(id_for 'module:cross-beta')" "$(id_for 'file:cross-beta')" \
    'src/cross-beta.kofun' "$CASES/cross_module_beta.kofun" \
    >>"$WORK/cross_module.inventory"

printf '%s|%s|%s|%s|%s\n' \
    "$PACKAGE_ID" "$(id_for 'module:good-before-bad')" "$(id_for 'file:good-before-bad')" \
    'src/good.kofun' "$CASES/alpha.kofun" \
    >"$WORK/transaction_failure.inventory"
printf '%s|%s|%s|%s|%s\n' \
    "$PACKAGE_ID" "$(id_for 'module:bad-after-good')" "$(id_for 'file:bad-after-good')" \
    'src/bad.kofun' "$CASES/malformed_function.kofun" \
    >>"$WORK/transaction_failure.inventory"

expect_failure invalid_inventory E2S48
expect_failure duplicate_module E2S49
expect_failure duplicate_function E2S51
expect_failure function_constructor_collision E2S51
expect_failure duplicate_adt E2S51
expect_failure duplicate_constructor E2S51
expect_failure malformed_function E2S52
expect_failure malformed_adt E2S50
expect_failure body_local_function E2S50
expect_failure unknown_call E2S53
expect_failure import_deferred E2S54
expect_failure cross_module E2S54
expect_failure transaction_failure E2S52

# RFC-0012 step 1. `trust` joins the module header's own authority, under the
# same refusals: none of these is repaired from the filesystem path, and each
# fails at its own span.
#
# `trust_spaced_class` is the one that looks like pedantry and is not. Admitting
# `raw - foreign` would give one trust class two spellings, and a class two
# readers can spell differently is a class they can disagree about — which is
# the whole failure this header exists to close.
#
# `trust_unknown_class` is refused rather than ignored for the same reason in
# the other direction: treating a class this compiler does not understand as
# absent is the permissive reading, and absent is exactly the downgrade
# RFC-0012 exists to prevent.
expect_failure trust_duplicate E2S57
expect_failure trust_detached E2S57
expect_failure trust_unattached E2S57
expect_failure trust_unknown_class E2S57
expect_failure trust_spaced_class E2S57
expect_failure trust_trailing_text E2S57
expect_failure trust_anonymous E2S57

# And the half that must keep working: `trust` is a keyword on one line and an
# ordinary identifier everywhere else. A gate that only proved the refusals
# would be green with `trust` reserved globally, which would break every
# existing source that happens to use the name.
"$WORK/kofun-module-symbols" "$WORK/trust_ordinary_identifier.inventory" \
    "$WORK/trust_ordinary_identifier.out" \
    >"$WORK/trust_ordinary_identifier.actual" 2>&1 ||
    fail '`trust` stopped being usable as an ordinary declaration name'
grep -q '|trust=ordinary$' "$WORK/trust_ordinary_identifier.out" ||
    fail 'a module without a trust line is not recorded as ordinary'
grep -q '|kind=function|name=trust|' "$WORK/trust_ordinary_identifier.out" ||
    fail '`trust` was not collected as an ordinary function declaration'

# The fact reaches the module table, and reaches it on every module. A field
# that appeared only when set could not tell "ordinary" from "written by a
# producer that did not know about trust".
write_one_inventory trust_positive "$CASES/trust_positive.kofun"
"$WORK/kofun-module-symbols" "$WORK/trust_positive.inventory" \
    "$WORK/trust_positive.out" >"$WORK/trust_positive.actual" 2>&1 ||
    fail 'a module carrying `trust raw-foreign` was refused'
grep -q '|trust=raw-foreign$' "$WORK/trust_positive.out" ||
    fail '`trust raw-foreign` did not reach the module table'

set +e
"$WORK/kofun-module-symbols" "$WORK/positive.inventory" \
    "$WORK/missing-output/declarations.out" \
    >"$WORK/output_failure.actual" 2>"$WORK/output_failure.internal.stderr"
output_failure_status=$?
set -e
test "$output_failure_status" -eq 1 ||
    fail "output failure exited $output_failure_status instead of 1"
test ! -s "$WORK/output_failure.internal.stderr" ||
    fail 'output failure wrote internal stderr'
test ! -e "$WORK/missing-output/declarations.out" ||
    fail 'output failure committed a declaration table'
printf '%s\n' 'error[E2S56]: cannot create output artifact' \
    >"$WORK/output_failure.expected"
cmp "$WORK/output_failure.expected" "$WORK/output_failure.actual" ||
    fail 'E2S56 output failure diagnostic differs'
printf '%s\n' 'PASS module-symbol diagnostic: output_failure'

dd if=/dev/zero bs=1048576 count=1 2>/dev/null | tr '\000' '#' \
    >"$WORK/source_limit.kofun"
write_one_inventory source_limit "$WORK/source_limit.kofun"
"$WORK/kofun-module-symbols" "$WORK/source_limit.inventory" "$WORK/source_limit.out"
printf '#' >>"$WORK/source_limit.kofun"
set +e
"$WORK/kofun-module-symbols" "$WORK/source_limit.inventory" "$WORK/source_over.out" \
    >"$WORK/source_over.actual"
source_status=$?
set -e
test "$source_status" -eq 1 || fail 'one-over source limit was accepted'
grep -F 'error[E2S55]:' "$WORK/source_over.actual" >/dev/null ||
    fail 'one-over source limit did not report E2S55'
test ! -e "$WORK/source_over.out" || fail 'one-over source committed output'

: >"$WORK/empty.kofun"
: >"$WORK/module_limit.inventory"
index=0
while test "$index" -lt 256
do
    printf '%s|%s|%s|generated/m%s.kofun|%s\n' \
        "$PACKAGE_ID" "$(id_for "module-limit:$index")" \
        "$(id_for "file-limit:$index")" "$index" "$WORK/empty.kofun" \
        >>"$WORK/module_limit.inventory"
    index=$((index + 1))
done
"$WORK/kofun-module-symbols" "$WORK/module_limit.inventory" "$WORK/module_limit.out"
printf '%s|%s|%s|generated/overflow.kofun|%s\n' \
    "$PACKAGE_ID" "$(id_for 'module-limit:overflow')" \
    "$(id_for 'file-limit:overflow')" "$WORK/empty.kofun" \
    >>"$WORK/module_limit.inventory"
set +e
"$WORK/kofun-module-symbols" "$WORK/module_limit.inventory" "$WORK/module_over.out" \
    >"$WORK/module_over.actual"
module_status=$?
set -e
test "$module_status" -eq 1 || fail '257 modules were accepted'
grep -F 'error[E2S55]:' "$WORK/module_over.actual" >/dev/null ||
    fail 'module overflow did not report E2S55'

awk 'BEGIN {
    print "module limits.identifier"
    printf "fn "
    for (i = 0; i < 256; i++) printf "a"
    print "() -> Int { return 0 }"
}' >"$WORK/identifier_limit.kofun"
write_one_inventory identifier_limit "$WORK/identifier_limit.kofun"
"$WORK/kofun-module-symbols" "$WORK/identifier_limit.inventory" "$WORK/identifier_limit.out"
sed 's/fn a/fn aa/' "$WORK/identifier_limit.kofun" >"$WORK/identifier_over.kofun"
write_one_inventory identifier_over "$WORK/identifier_over.kofun"
set +e
"$WORK/kofun-module-symbols" "$WORK/identifier_over.inventory" "$WORK/identifier_over.out" \
    >"$WORK/identifier_over.actual"
identifier_status=$?
set -e
test "$identifier_status" -eq 1 || fail '257-byte identifier was accepted'
grep -F 'error[E2S55]:' "$WORK/identifier_over.actual" >/dev/null ||
    fail 'identifier overflow did not report E2S55'

awk 'BEGIN {
    print "module limits.declarations"
    for (i = 0; i < 4096; i++) printf "fn f%d() -> Int { return 0 }\n", i
}' >"$WORK/declaration_limit.kofun"
write_one_inventory declaration_limit "$WORK/declaration_limit.kofun"
"$WORK/kofun-module-symbols" "$WORK/declaration_limit.inventory" "$WORK/declaration_limit.out"
printf '%s\n' 'fn overflow() -> Int { return 0 }' >>"$WORK/declaration_limit.kofun"
set +e
"$WORK/kofun-module-symbols" "$WORK/declaration_limit.inventory" "$WORK/declaration_over.out" \
    >"$WORK/declaration_over.actual"
declaration_status=$?
set -e
test "$declaration_status" -eq 1 || fail '4097 top-level declarations were accepted'
grep -F 'error[E2S55]:' "$WORK/declaration_over.actual" >/dev/null ||
    fail 'declaration overflow did not report E2S55'

awk 'BEGIN {
    print "module limits.constructors"
    print "type Many ="
    for (i = 0; i < 8192; i++) printf "| C%d\n", i
}' >"$WORK/constructor_limit.kofun"
write_one_inventory constructor_limit "$WORK/constructor_limit.kofun"
"$WORK/kofun-module-symbols" "$WORK/constructor_limit.inventory" "$WORK/constructor_limit.out"
printf '%s\n' '| Overflow' >>"$WORK/constructor_limit.kofun"
set +e
"$WORK/kofun-module-symbols" "$WORK/constructor_limit.inventory" "$WORK/constructor_over.out" \
    >"$WORK/constructor_over.actual"
constructor_status=$?
set -e
test "$constructor_status" -eq 1 || fail '8193 constructors were accepted'
grep -F 'error[E2S55]:' "$WORK/constructor_over.actual" >/dev/null ||
    fail 'constructor overflow did not report E2S55'

: >"$WORK/declaration_total.inventory"
index=0
while test "$index" -lt 8
do
    awk -v module_index="$index" 'BEGIN {
        printf "module limits.total%d\n", module_index
        print "type Many ="
        for (i = 0; i < 8191; i++) printf "| C%d\n", i
    }' >"$WORK/declaration_total_$index.kofun"
    printf '%s|%s|%s|generated/total%s.kofun|%s\n' \
        "$PACKAGE_ID" "$(id_for "module-total:$index")" \
        "$(id_for "file-total:$index")" "$index" \
        "$WORK/declaration_total_$index.kofun" \
        >>"$WORK/declaration_total.inventory"
    index=$((index + 1))
done
"$WORK/kofun-module-symbols" "$WORK/declaration_total.inventory" \
    "$WORK/declaration_total.out"
printf '%s\n' 'module limits.total_overflow' \
    'fn overflow() -> Int { return 0 }' >"$WORK/declaration_total_over.kofun"
printf '%s|%s|%s|generated/total-overflow.kofun|%s\n' \
    "$PACKAGE_ID" "$(id_for 'module-total:overflow')" \
    "$(id_for 'file-total:overflow')" "$WORK/declaration_total_over.kofun" \
    >>"$WORK/declaration_total.inventory"
set +e
"$WORK/kofun-module-symbols" "$WORK/declaration_total.inventory" \
    "$WORK/declaration_total_over.out" >"$WORK/declaration_total_over.actual"
total_status=$?
set -e
test "$total_status" -eq 1 || fail '65537 inventory declarations were accepted'
grep -F 'error[E2S55]:' "$WORK/declaration_total_over.actual" >/dev/null ||
    fail 'inventory declaration overflow did not report E2S55'

awk 'BEGIN {
    print "module limits.parameters"
    printf "fn many("
    for (i = 0; i < 256; i++) {
        if (i) printf ", "
        printf "p%d: Int", i
    }
    print ") -> Int { return 0 }"
}' >"$WORK/parameter_limit.kofun"
write_one_inventory parameter_limit "$WORK/parameter_limit.kofun"
"$WORK/kofun-module-symbols" "$WORK/parameter_limit.inventory" "$WORK/parameter_limit.out"
sed 's/) -> Int/, overflow: Int) -> Int/' "$WORK/parameter_limit.kofun" \
    >"$WORK/parameter_over.kofun"
write_one_inventory parameter_over "$WORK/parameter_over.kofun"
set +e
"$WORK/kofun-module-symbols" "$WORK/parameter_over.inventory" "$WORK/parameter_over.out" \
    >"$WORK/parameter_over.actual"
parameter_status=$?
set -e
test "$parameter_status" -eq 1 || fail '257 parameters were accepted'
grep -F 'error[E2S55]:' "$WORK/parameter_over.actual" >/dev/null ||
    fail 'parameter overflow did not report E2S55'

awk 'BEGIN {
    print "module limits.depth"
    printf "fn deep() -> Int { "
    for (i = 0; i < 255; i++) printf "{ "
    printf "0 "
    for (i = 0; i < 255; i++) printf "} "
    print "}"
}' >"$WORK/depth_limit.kofun"
write_one_inventory depth_limit "$WORK/depth_limit.kofun"
"$WORK/kofun-module-symbols" "$WORK/depth_limit.inventory" "$WORK/depth_limit.out"
sed 's/{ 0/{ { 0/' "$WORK/depth_limit.kofun" | sed 's/} }$/} } }/' \
    >"$WORK/depth_over.kofun"
write_one_inventory depth_over "$WORK/depth_over.kofun"
set +e
"$WORK/kofun-module-symbols" "$WORK/depth_over.inventory" "$WORK/depth_over.out" \
    >"$WORK/depth_over.actual"
depth_status=$?
set -e
test "$depth_status" -eq 1 || fail 'delimiter depth 257 was accepted'
grep -F 'error[E2S55]:' "$WORK/depth_over.actual" >/dev/null ||
    fail 'delimiter overflow did not report E2S55'

"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    "$ROOT/bootstrap/stage2/module_symbols.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    -o "$WORK/kofun-module-symbols-sanitized"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/kofun-module-symbols-sanitized" \
    "$WORK/positive.inventory" "$WORK/sanitized.out"
cmp "$WORK/positive.out" "$WORK/sanitized.out" ||
    fail 'sanitized build changed canonical output'

if "$CC" -std=c11 -O0 -Wall -Wextra -Werror -pedantic -fanalyzer \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    "$ROOT/bootstrap/stage2/module_symbols.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    -o "$WORK/kofun-module-symbols-analyzed" >/dev/null 2>&1
then
    printf '%s\n' 'PASS: GCC analyzer accepts the declaration collector'
fi

printf '%s\n' \
    'PASS: all supported headers are collected before body resolution' \
    'PASS: production NamespaceId/SymbolId framing matches the reference' \
    'PASS: inventory order, declaration order, and path remaps preserve semantic IDs' \
    'PASS: duplicates, unsupported imports, transaction failure, and limits are bounded'

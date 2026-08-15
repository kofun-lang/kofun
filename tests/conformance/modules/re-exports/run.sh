#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/modules/re-exports"
CC=${CC:-cc}
WORK=${KOFUN_RE_EXPORTS_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}re-exports"}
TOOL="$WORK/re-exports"
KIF_TOOL="$WORK/kofun-kif-v1"
PACKAGE_ID=1111111111111111111111111111111111111111111111111111111111111111
COLLECTIONS_MODULE=2222222222222222222222222222222222222222222222222222222222222222
COLLECTIONS_FILE=2323232323232323232323232323232323232323232323232323232323232323
FACADE_MODULE=3333333333333333333333333333333333333333333333333333333333333333
FACADE_FILE=3434343434343434343434343434343434343434343434343434343434343434
SECOND_MODULE=4444444444444444444444444444444444444444444444444444444444444444
SECOND_FILE=4545454545454545454545454545454545454545454545454545454545454545
ALTERNATE_MODULE=5555555555555555555555555555555555555555555555555555555555555555
ALTERNATE_FILE=5656565656565656565656565656565656565656565656565656565656565656
ASSERT_CONTEXT='re-exports'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

run_re_export_analyzer() {
    re_exports_analyzer_output=$1
    re_exports_analyzer_stdout="$re_exports_analyzer_output.stdout"
    re_exports_analyzer_stderr="$re_exports_analyzer_output.stderr"
    rm -f -- "$re_exports_analyzer_output" \
        "$re_exports_analyzer_stdout" "$re_exports_analyzer_stderr"
    if KOFUN_STAGE2_COMMON_LINK_ID=re-exports/analyzed \
        "$CC" -std=c11 -O0 -Wall -Wextra -Werror -pedantic -fanalyzer \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/re_exports.c" \
        "$KOFUN_STAGE2_ANALYZER_KIF_V1_INPUT" \
        "$KOFUN_STAGE2_ANALYZER_VISIBILITY_INPUT" \
        "$KOFUN_STAGE2_ANALYZER_UNICODE_INPUT" \
        "$KOFUN_STAGE2_ANALYZER_SHA256_INPUT" \
        -o "$re_exports_analyzer_output" \
        >"$re_exports_analyzer_stdout" 2>"$re_exports_analyzer_stderr"
    then
        printf '%s\n' \
            'PASS: GCC analyzer accepts the re-export resolver and KIF projection'
        return 0
    else
        re_exports_analyzer_status=$?
    fi
    rm -f -- "$re_exports_analyzer_output"
    printf '%s\n' \
        "FAIL: re-exports: GCC analyzer compile failed with status $re_exports_analyzer_status; stdout=$re_exports_analyzer_stdout; stderr=$re_exports_analyzer_stderr" \
        >&2
    if test -s "$re_exports_analyzer_stdout"; then
        cat "$re_exports_analyzer_stdout" >&2
    fi
    if test -s "$re_exports_analyzer_stderr"; then
        cat "$re_exports_analyzer_stderr" >&2
    fi
    return "$re_exports_analyzer_status"
}

case $WORK in
    */re-exports|*/re-exports.*) ;;
    *) fail "work directory must end in re-exports[.suffix]: $WORK" ;;
esac

rm -rf "$WORK"
mkdir -p "$WORK"
kofun_stage2_semantic_common_inputs "$ROOT"
# #1449. The four common sources this gate's analyzer arm links are
# analysed once per verify run and reused; unset the bundle and they are
# compiled from source here, which keeps this gate standalone.
kofun_stage2_analyzer_common_inputs "$ROOT"

KOFUN_STAGE2_COMMON_LINK_ID=re-exports/resolver \
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_TEST_DIAGNOSTIC_FAULTS \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/re_exports.c" \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
    "$KOFUN_STAGE2_COMMON_VISIBILITY_INPUT" \
    "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    -o "$TOOL"

KOFUN_STAGE2_COMMON_LINK_ID=re-exports/reader \
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/kif_v1_tool.c" \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
    "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    -o "$KIF_TOOL"
KOFUN_STAGE2_COMMON_LINK_ID=re-exports/export-binding-reference \
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$CASES/export_binding_reference.c" \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    -o "$WORK/export-binding-reference"

write_inventory() {
    facade_source=$1
    output=$2
    {
        printf '%s|%s|%s|lib.collections|lib/collections.kofun|%s\n' \
            "$PACKAGE_ID" "$COLLECTIONS_MODULE" "$COLLECTIONS_FILE" \
            "$CASES/fixtures/collections.kofun"
        printf '%s|%s|%s|api.collections|api/collections.kofun|%s\n' \
            "$PACKAGE_ID" "$FACADE_MODULE" "$FACADE_FILE" "$facade_source"
    } >"$output"
}

expect_failure() {
    code=$1
    name=$2
    facade=$3
    inventory=$4
    hir="$WORK/$name.hir"
    kif="$WORK/$name.kif"
    tooling="$WORK/$name.tooling"
    log="$WORK/$name.log"
    printf '%s\n' stale >"$hir"
    printf '%s\n' stale >"$kif"
    printf '%s\n' stale >"$tooling"
    set +e
    "$TOOL" "$inventory" "$facade" "$hir" "$kif" "$tooling" \
        >"$log" 2>&1
    result=$?
    set -e
    test "$result" -eq 1 || fail "$name exited $result instead of 1"
    grep -F "error[$code]:" "$log" >/dev/null ||
        fail "$name did not emit $code"
    test ! -e "$hir" || fail "$name left HIR"
    test ! -e "$kif" || fail "$name left KIF"
    test ! -e "$tooling" || fail "$name left tooling projection"
}

# Both accepted forms, same-spelled namespaces, and KIF/tooling publication.
write_inventory "$CASES/fixtures/facade.kofun" "$WORK/positive.inventory"
"$TOOL" "$WORK/positive.inventory" api.collections \
    "$WORK/positive.hir" "$WORK/positive.kif" "$WORK/positive.tooling"
assert_grep "positive.hir" -Fx 'kofun-re-exports/v1' "$WORK/positive.hir"
assert_num "^export| lines in positive.hir" \
    "$(grep -c '^export|' "$WORK/positive.hir")" -eq 5
grep -F '|ns=2:module:' "$WORK/positive.hir" | grep -F '|name=collections|' >/dev/null ||
    assert_fail "the collections module is not re-exported in positive.hir"
grep -F '|ns=2:module:' "$WORK/positive.hir" |
    grep -F '|name=collections|' |
    grep -E '\|access-proof=[1-9][0-9]*\|' >/dev/null ||
    assert_fail "the re-exported collections module carries no access proof in positive.hir"
assert_num "Map rows in positive.hir" \
    "$(grep -F '|name=Map|' "$WORK/positive.hir" | wc -l | tr -d ' ')" -eq 2
grep -F '|ns=0:value:' "$WORK/positive.hir" | grep -F '|name=Map|' >/dev/null ||
    assert_fail "Map is missing from the value namespace in positive.hir"
grep -F '|ns=1:type:' "$WORK/positive.hir" | grep -F '|name=Map|' >/dev/null ||
    assert_fail "Map is missing from the type namespace in positive.hir"
assert_grep "positive.hir" -F '|name=Set|' "$WORK/positive.hir"
assert_grep "positive.hir" -F '|name=Present|' "$WORK/positive.hir"
assert_grep "positive.hir" \
    -F '|proof=non-widening-public-v1' "$WORK/positive.hir"
assert_grep "positive.tooling" \
    -F \
    'doc|facade=api.collections.Map|canonical=lib.collections.Map|' \
    "$WORK/positive.tooling"
assert_grep "positive.tooling" \
    -F \
    '|linker-forwarding=false|runtime-forwarding=false' \
    "$WORK/positive.tooling"
value_map_export=$(
    grep -F '|ns=0:value:' "$WORK/positive.hir" |
        grep -F '|name=Map|' |
        head -n 1
)
value_map_namespace=$(
    printf '%s\n' "$value_map_export" |
        sed -n 's/.*|ns=0:value:\([0-9a-f]*\)|.*/\1/p'
)
value_map_binding=$(
    printf '%s\n' "$value_map_export" |
        sed -n 's/.*|binding=\([0-9a-f]*\)|.*/\1/p'
)
value_map_target=$(
    printf '%s\n' "$value_map_export" |
        sed -n 's/.*|target-symbol=\([0-9a-f]*\)|.*/\1/p'
)
value_map_chain=$(
    printf '%s\n' "$value_map_export" |
        sed -n 's/.*|chain=\([^|]*\)|.*/\1/p'
)
assert_eq "value map chain" "$value_map_chain" "$value_map_binding"
expected_value_map_binding=$(
    "$WORK/export-binding-reference" \
        "$FACADE_MODULE" "$value_map_namespace" Map "$value_map_target"
)
assert_eq "value map binding" \
    "$value_map_binding" "$expected_value_map_binding"

# A facade's product path checks its final exported spelling together with
# local bindings before HIR, KIF, or tooling publication.
{
    printf '%s|%s|%s|lib.collections|lib/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$COLLECTIONS_MODULE" "$COLLECTIONS_FILE" \
        "$CASES/fixtures/confusable_collections.kofun"
    printf '%s|%s|%s|api.collections|api/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$FACADE_MODULE" "$FACADE_FILE" \
        "$CASES/fixtures/confusable_facade.kofun"
} >"$WORK/eunicode008-facade.inventory"
expect_failure EUNICODE008 eunicode008-facade api.collections \
    "$WORK/eunicode008-facade.inventory"
assert_grep "eunicode008-facade.log" -F '`paypal`' \
    "$WORK/eunicode008-facade.log"
assert_grep "eunicode008-facade.log" -F '`pаypal`' \
    "$WORK/eunicode008-facade.log"

"$KIF_TOOL" read "$WORK/positive.kif" "$WORK/positive.json"
assert_num "\"kind\": \"export\" lines in positive.json" \
    "$(grep -c '"kind": "export"' "$WORK/positive.json")" -eq 5
assert_grep "positive.json" \
    -F '"target_kind": "function", "chain_count": 1' "$WORK/positive.json"
"$TOOL" --resolve-kif "$WORK/positive.kif" Map value \
    "$WORK/consumer-value.hir"
"$TOOL" --resolve-kif "$WORK/positive.kif" Map type \
    "$WORK/consumer-type.hir"
"$TOOL" --resolve-kif "$WORK/positive.kif" collections module \
    "$WORK/consumer-module.hir"
"$TOOL" --resolve-kif "$WORK/positive.kif" Present value \
    "$WORK/consumer-constructor.hir"
assert_grep "consumer-value.hir" \
    -F '|namespace=value|' "$WORK/consumer-value.hir"
assert_grep "consumer-type.hir" -F '|namespace=type|' "$WORK/consumer-type.hir"
assert_grep "consumer-module.hir" \
    -F '|namespace=module|' "$WORK/consumer-module.hir"
assert_grep "consumer-constructor.hir" \
    -F '|namespace=value|' "$WORK/consumer-constructor.hir"

# The ordinary compiled-interface consumer, not only the focused projection,
# resolves a facade import to the original callable target and full edge chain.
printf '%s\n' 'module consumer.app' \
    'import api.collections' \
    '' \
    'fn main() -> Int {' \
    '    return collections.Map(42)' \
    '}' >"$WORK/ordinary-facade-consumer.kofun"
"$KIF_TOOL" resolve "$WORK/positive.kif" "$PACKAGE_ID" api.collections \
    "$WORK/ordinary-facade-consumer.kofun" \
    "$WORK/ordinary-facade-same.hir"
"$KIF_TOOL" resolve "$WORK/positive.kif" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    api.collections "$WORK/ordinary-facade-consumer.kofun" \
    "$WORK/ordinary-facade-external.hir"
for resolved in "$WORK/ordinary-facade-same.hir" \
    "$WORK/ordinary-facade-external.hir"
do
    grep -F "|binding-module=$FACADE_MODULE|" "$resolved" |
        grep -F "|export-binding=$value_map_binding|" |
        grep -F "|target-module=$COLLECTIONS_MODULE|" |
        grep -F "|target-symbol=$value_map_target|" |
        grep -F "|chain=1|chain-ids=$value_map_chain" >/dev/null ||
        assert_fail "the resolved value Map row does not carry the expected one-hop chain"
done
assert_grep "ordinary-facade-same.hir" \
    -F '|view=package-internal|' "$WORK/ordinary-facade-same.hir"
assert_grep "ordinary-facade-external.hir" \
    -F '|view=public|' "$WORK/ordinary-facade-external.hir"

# The same decoded facade KIF contributes its effective export spelling to a
# selective consumer's visible set. The original facade/target identities are
# validated above; the collision must stop the consumer HIR transaction.
set +e
"$KIF_TOOL" resolve-visible "$WORK/positive.kif" \
    "$PACKAGE_ID" "$SECOND_MODULE" api.collections \
    "$CASES/fixtures/confusable_consumer.kofun" \
    "$WORK/confusable-consumer.hir" \
    >"$WORK/confusable-consumer.log" 2>"$WORK/confusable-consumer.stderr"
confusable_consumer_status=$?
set -e
assert_num "facade consumer EUNICODE008 status" \
    "$confusable_consumer_status" -eq 1
assert_file_empty "confusable-consumer.stderr" \
    "$WORK/confusable-consumer.stderr"
assert_grep "confusable-consumer.log" -F 'error[EUNICODE008]:' \
    "$WORK/confusable-consumer.log"
assert_grep "confusable-consumer.log" -F '`Map`' \
    "$WORK/confusable-consumer.log"
assert_grep "confusable-consumer.log" -F '`Mаp`' \
    "$WORK/confusable-consumer.log"
assert_absent "confusable-consumer.hir" "$WORK/confusable-consumer.hir"

# Source/inventory/path remapping cannot change authoritative interface bytes.
write_inventory "$CASES/fixtures/facade_reordered.kofun" \
    "$WORK/reordered.inventory"
"$TOOL" "$WORK/reordered.inventory" api.collections \
    "$WORK/reordered.hir" "$WORK/reordered.kif" "$WORK/reordered.tooling"
cmp "$WORK/positive.kif" "$WORK/reordered.kif"
mkdir -p "$WORK/remapped/a" "$WORK/remapped/b"
cp "$CASES/fixtures/collections.kofun" "$WORK/remapped/a/collections.kofun"
cp "$CASES/fixtures/facade.kofun" "$WORK/remapped/b/facade.kofun"
{
    printf '%s|%s|%s|api.collections|moved/facade.kofun|%s\n' \
        "$PACKAGE_ID" "$FACADE_MODULE" "$FACADE_FILE" \
        "$WORK/remapped/b/facade.kofun"
    printf '%s|%s|%s|lib.collections|moved/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$COLLECTIONS_MODULE" "$COLLECTIONS_FILE" \
        "$WORK/remapped/a/collections.kofun"
} >"$WORK/remapped.inventory"
"$TOOL" "$WORK/remapped.inventory" api.collections \
    "$WORK/remapped.hir" "$WORK/remapped.kif" "$WORK/remapped.tooling"
cmp "$WORK/positive.kif" "$WORK/remapped.kif"

# A private target body edit does not perturb the facade digest; adding an
# edge does.
sed '/private fn hidden/,/^}/s/return value/return 42/' \
    "$CASES/fixtures/collections.kofun" \
    >"$WORK/collections-body-edit.kofun"
{
    printf '%s|%s|%s|lib.collections|lib/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$COLLECTIONS_MODULE" "$COLLECTIONS_FILE" \
        "$WORK/collections-body-edit.kofun"
    printf '%s|%s|%s|api.collections|api/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$FACADE_MODULE" "$FACADE_FILE" \
        "$CASES/fixtures/facade.kofun"
} >"$WORK/body-edit.inventory"
"$TOOL" "$WORK/body-edit.inventory" api.collections \
    "$WORK/body-edit.hir" "$WORK/body-edit.kif" "$WORK/body-edit.tooling"
cmp "$WORK/positive.kif" "$WORK/body-edit.kif"

write_inventory "$CASES/fixtures/facade_map_only.kofun" \
    "$WORK/map-only.inventory"
"$TOOL" "$WORK/map-only.inventory" api.collections \
    "$WORK/map-only.hir" "$WORK/map-only.kif" "$WORK/map-only.tooling"
if cmp -s "$WORK/positive.kif" "$WORK/map-only.kif"; then
    fail 'adding the Set edge did not change facade KIF'
fi
positive_digest=$(sed -n \
    's/.*"public_semantic_digest": "\([0-9a-f]*\)".*/\1/p' \
    "$WORK/positive.json")
"$KIF_TOOL" read "$WORK/map-only.kif" "$WORK/map-only.json"
map_only_digest=$(sed -n \
    's/.*"public_semantic_digest": "\([0-9a-f]*\)".*/\1/p' \
    "$WORK/map-only.json")
assert_ne "positive digest" "$positive_digest" "$map_only_digest"

# A two-level chain keeps original target identities. Two different facades
# consumed from source-free KIF resolve to one declaration SymbolId.
{
    printf '%s|%s|%s|lib.collections|lib/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$COLLECTIONS_MODULE" "$COLLECTIONS_FILE" \
        "$CASES/fixtures/collections.kofun"
    printf '%s|%s|%s|api.collections|api/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$FACADE_MODULE" "$FACADE_FILE" \
        "$CASES/fixtures/facade.kofun"
    printf '%s|%s|%s|api.v2|api/v2.kofun|%s\n' \
        "$PACKAGE_ID" "$SECOND_MODULE" "$SECOND_FILE" \
        "$CASES/fixtures/facade_second.kofun"
} >"$WORK/two-level.inventory"
"$TOOL" "$WORK/two-level.inventory" api.v2 \
    "$WORK/two-level.hir" "$WORK/two-level.kif" "$WORK/two-level.tooling"
assert_num "chained Map exports from api.v2 in two-level.hir" \
    "$(grep -F 'export|module=api.v2|' "$WORK/two-level.hir" | grep -F '|name=Map|' | grep -c '|chain=')" \
    -eq 2
grep -F 'doc|facade=api.v2.Map|canonical=lib.collections.Map|' \
    "$WORK/two-level.tooling" | grep -F '|chain=2|' >/dev/null ||
    assert_fail "the api.v2.Map doc row does not record a two-hop chain"
"$TOOL" --resolve-kif "$WORK/two-level.kif" Map value \
    "$WORK/v2-consumer.hir"
v2_chain=$(
    grep -F 'export|module=api.v2|' "$WORK/two-level.hir" |
        grep -F '|ns=0:value:' | grep -F '|name=Map|' |
        sed -n 's/.*|chain=\([^|]*\)|.*/\1/p'
)
assert_num "hops in the api.v2 Map re-export chain" \
    "$(printf '%s\n' "$v2_chain" | tr ',' '\n' | wc -l | tr -d ' ')" -eq 2
assert_grep "two-level.tooling" \
    -F "|chain=2|chain-ids=$v2_chain|" "$WORK/two-level.tooling"
assert_grep "v2-consumer.hir" \
    -F "|chain=2|chain-ids=$v2_chain" "$WORK/v2-consumer.hir"

# One selective spelling expands across a direct value and a forwarded type.
# Resolution reaches a fixed point per namespace instead of stopping at the
# first direct match.
printf '%s\n' 'module mixed.base' \
    'pub type Mix =' \
    '    | Empty' \
    '    | Full(value: Int)' >"$WORK/mixed-base.kofun"
printf '%s\n' 'module mixed.middle' \
    'pub from mixed.base import Mix' \
    'pub fn Mix(value: Int) -> Int {' \
    '    return value' \
    '}' >"$WORK/mixed-middle.kofun"
printf '%s\n' 'module mixed.outer' \
    'pub from mixed.middle import Mix' >"$WORK/mixed-outer.kofun"
{
    printf '%s|%064d|%064d|mixed.base|mixed/base.kofun|%s\n' \
        "$PACKAGE_ID" 5601 5701 "$WORK/mixed-base.kofun"
    printf '%s|%064d|%064d|mixed.middle|mixed/middle.kofun|%s\n' \
        "$PACKAGE_ID" 5602 5702 "$WORK/mixed-middle.kofun"
    printf '%s|%064d|%064d|mixed.outer|mixed/outer.kofun|%s\n' \
        "$PACKAGE_ID" 5603 5703 "$WORK/mixed-outer.kofun"
} >"$WORK/mixed.inventory"
"$TOOL" "$WORK/mixed.inventory" mixed.outer \
    "$WORK/mixed.hir" "$WORK/mixed.kif" "$WORK/mixed.tooling"
assert_num "Mix rows exported by mixed.outer in mixed.hir" \
    "$(grep -F 'export|module=mixed.outer|' "$WORK/mixed.hir" | grep -F '|name=Mix|' | wc -l | tr -d ' ')" \
    -eq 2
grep -F 'export|module=mixed.outer|' "$WORK/mixed.hir" |
    grep -F '|ns=0:value:' | grep -F '|name=Mix|' >/dev/null ||
    assert_fail "Mix is not exported from mixed.outer in the value namespace"
grep -F 'export|module=mixed.outer|' "$WORK/mixed.hir" |
    grep -F '|ns=1:type:' | grep -F '|name=Mix|' >/dev/null ||
    assert_fail "Mix is not exported from mixed.outer in the type namespace"

{
    printf '%s|%s|%s|lib.collections|lib/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$COLLECTIONS_MODULE" "$COLLECTIONS_FILE" \
        "$CASES/fixtures/collections.kofun"
    printf '%s|%s|%s|api.alternate|api/alternate.kofun|%s\n' \
        "$PACKAGE_ID" "$ALTERNATE_MODULE" "$ALTERNATE_FILE" \
        "$CASES/fixtures/facade_alternate.kofun"
} >"$WORK/alternate.inventory"
"$TOOL" "$WORK/alternate.inventory" api.alternate \
    "$WORK/alternate.hir" "$WORK/alternate.kif" "$WORK/alternate.tooling"
"$TOOL" --resolve-kif "$WORK/alternate.kif" Map value \
    "$WORK/alternate-consumer.hir"
v2_target=$(sed -n 's/.*|target-symbol=\([0-9a-f]*\)|.*/\1/p' \
    "$WORK/v2-consumer.hir")
alternate_target=$(sed -n 's/.*|target-symbol=\([0-9a-f]*\)|.*/\1/p' \
    "$WORK/alternate-consumer.hir")
assert_num "${#v2_target}" "${#v2_target}" -eq 64
assert_eq "v2 target" "$v2_target" "$alternate_target"

# Every rejected source spelling is explicit and transactional.
sed 's/pub import lib.collections/pub import lib.collections as c/' \
    "$CASES/fixtures/facade.kofun" >"$WORK/qualified-alias.kofun"
write_inventory "$WORK/qualified-alias.kofun" "$WORK/qualified-alias.inventory"
expect_failure E2S85 qualified-alias api.collections \
    "$WORK/qualified-alias.inventory"

sed 's/pub from lib.collections import Map, Set/pub from lib.collections import */' \
    "$CASES/fixtures/facade.kofun" >"$WORK/wildcard.kofun"
write_inventory "$WORK/wildcard.kofun" "$WORK/wildcard.inventory"
expect_failure E2S85 wildcard api.collections "$WORK/wildcard.inventory"

sed 's/pub from lib.collections import Map, Set/pub from lib.collections import Map as M/' \
    "$CASES/fixtures/facade.kofun" >"$WORK/per-name-alias.kofun"
write_inventory "$WORK/per-name-alias.kofun" "$WORK/per-name-alias.inventory"
expect_failure E2S85 per-name-alias api.collections \
    "$WORK/per-name-alias.inventory"

sed 's/Map, Set, Present/Map,,Set/' \
    "$CASES/fixtures/facade.kofun" >"$WORK/malformed-list.kofun"
write_inventory "$WORK/malformed-list.kofun" \
    "$WORK/malformed-list.inventory"
expect_failure E2S85 malformed-list api.collections \
    "$WORK/malformed-list.inventory"

sed 's/pub from lib.collections import Map, Set/pub from lib.collections import/' \
    "$CASES/fixtures/facade.kofun" >"$WORK/empty.kofun"
write_inventory "$WORK/empty.kofun" "$WORK/empty.inventory"
expect_failure E2S85 empty api.collections "$WORK/empty.inventory"

sed 's/pub from lib.collections import Map, Set/pub from ext:collections import Map/' \
    "$CASES/fixtures/facade.kofun" >"$WORK/external.kofun"
write_inventory "$WORK/external.kofun" "$WORK/external.inventory"
expect_failure E2S85 external api.collections "$WORK/external.inventory"

sed 's/pub import lib.collections/internal import lib.collections/' \
    "$CASES/fixtures/facade.kofun" >"$WORK/internal-form.kofun"
write_inventory "$WORK/internal-form.kofun" "$WORK/internal-form.inventory"
expect_failure E2S85 internal-form api.collections \
    "$WORK/internal-form.inventory"

sed 's/pub import lib.collections/private import lib.collections/' \
    "$CASES/fixtures/facade.kofun" >"$WORK/private-form.kofun"
write_inventory "$WORK/private-form.kofun" "$WORK/private-form.inventory"
expect_failure E2S85 private-form api.collections \
    "$WORK/private-form.inventory"

sed 's/pub import lib.collections/export import lib.collections/' \
    "$CASES/fixtures/facade.kofun" >"$WORK/export-form.kofun"
write_inventory "$WORK/export-form.kofun" "$WORK/export-form.inventory"
expect_failure E2S85 export-form api.collections \
    "$WORK/export-form.inventory"

{
    printf '%s\n' 'module api.collections'
    printf '%s\n' 'fn local() -> Int {' '    return 0' '}'
    printf '%s\n' 'pub from lib.collections import Map'
} >"$WORK/after-declaration.kofun"
write_inventory "$WORK/after-declaration.kofun" \
    "$WORK/after-declaration.inventory"
expect_failure E2S85 after-declaration api.collections \
    "$WORK/after-declaration.inventory"

sed 's/lib.collections import Map, Set/missing.collections import Map/' \
    "$CASES/fixtures/facade.kofun" >"$WORK/missing.kofun"
write_inventory "$WORK/missing.kofun" "$WORK/missing.inventory"
expect_failure E2S86 missing api.collections "$WORK/missing.inventory"

sed 's/Map, Set/hidden/' "$CASES/fixtures/facade.kofun" \
    >"$WORK/private-target.kofun"
write_inventory "$WORK/private-target.kofun" "$WORK/private-target.inventory"
expect_failure E2S87 private-target api.collections \
    "$WORK/private-target.inventory"
assert_grep "private-target.log" \
    -F 'requested=pub effective=private' "$WORK/private-target.log"
assert_num "spans in private-target.log" \
    "$(grep -Eo '[0-9]+\.\.[0-9]+' "$WORK/private-target.log" | wc -l | tr -d ' ')" \
    -ge 2

sed 's/Map, Set/Concealed/' "$CASES/fixtures/facade.kofun" \
    >"$WORK/private-enclosing-type.kofun"
write_inventory "$WORK/private-enclosing-type.kofun" \
    "$WORK/private-enclosing-type.inventory"
expect_failure E2S87 private-enclosing-type api.collections \
    "$WORK/private-enclosing-type.inventory"

sed 's/Map, Set/Leaky/' "$CASES/fixtures/facade.kofun" \
    >"$WORK/hidden-signature.kofun"
write_inventory "$WORK/hidden-signature.kofun" \
    "$WORK/hidden-signature.inventory"
expect_failure E2S87 hidden-signature api.collections \
    "$WORK/hidden-signature.inventory"
assert_num "spans in hidden-signature.log" \
    "$(grep -Eo '[0-9]+\.\.[0-9]+' "$WORK/hidden-signature.log" | wc -l | tr -d ' ')" \
    -ge 2

{
    printf '%s\n' 'module api.collections'
    printf '%s\n' 'pub from lib.collections import Map'
    printf '%s\n' 'pub from lib.collections import Map'
} >"$WORK/duplicate.kofun"
write_inventory "$WORK/duplicate.kofun" "$WORK/duplicate.inventory"
expect_failure E2S88 duplicate api.collections "$WORK/duplicate.inventory"
assert_grep "duplicate.log" -F 'binding spans=' "$WORK/duplicate.log"

{
    printf '%s\n' 'module api.collections'
    printf '%s\n' 'pub from lib.collections import Map'
    printf '%s\n' 'pub fn Map(value: Int) -> Int {' '    return value' '}'
} >"$WORK/local-collision.kofun"
write_inventory "$WORK/local-collision.kofun" \
    "$WORK/local-collision.inventory"
expect_failure E2S88 local-collision api.collections \
    "$WORK/local-collision.inventory"

printf '%s\n' 'module other.collections' \
    'pub fn Other(value: Int) -> Int {' '    return value' '}' \
    >"$WORK/other-collections.kofun"
printf '%s\n' 'module api.collections' \
    'import other.collections' \
    'pub import lib.collections' >"$WORK/import-collision.kofun"
{
    printf '%s|%s|%s|lib.collections|lib/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$COLLECTIONS_MODULE" "$COLLECTIONS_FILE" \
        "$CASES/fixtures/collections.kofun"
    printf '%s|%s|%s|other.collections|other/collections.kofun|%s\n' \
        "$PACKAGE_ID" 5757575757575757575757575757575757575757575757575757575757575757 \
        5858585858585858585858585858585858585858585858585858585858585858 \
        "$WORK/other-collections.kofun"
    printf '%s|%s|%s|api.collections|api/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$FACADE_MODULE" "$FACADE_FILE" \
        "$WORK/import-collision.kofun"
} >"$WORK/import-collision.inventory"
expect_failure E2S88 import-collision api.collections \
    "$WORK/import-collision.inventory"

# The composed adapter preserves the ordinary qualified-import cycle gate even
# when an unrelated public facade is present.
printf '%s\n' 'module ordinary.a' \
    'import ordinary.b' >"$WORK/ordinary-a.kofun"
printf '%s\n' 'module ordinary.b' \
    'import ordinary.a' >"$WORK/ordinary-b.kofun"
{
    printf '%s|%s|%s|lib.collections|lib/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$COLLECTIONS_MODULE" "$COLLECTIONS_FILE" \
        "$CASES/fixtures/collections.kofun"
    printf '%s|%s|%s|api.collections|api/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$FACADE_MODULE" "$FACADE_FILE" \
        "$CASES/fixtures/facade.kofun"
    printf '%s|%064d|%064d|ordinary.a|ordinary/a.kofun|%s\n' \
        "$PACKAGE_ID" 5901 5902 "$WORK/ordinary-a.kofun"
    printf '%s|%064d|%064d|ordinary.b|ordinary/b.kofun|%s\n' \
        "$PACKAGE_ID" 5903 5904 "$WORK/ordinary-b.kofun"
} >"$WORK/ordinary-cycle.inventory"
expect_failure E2S64 ordinary-cycle api.collections \
    "$WORK/ordinary-cycle.inventory"

# Qualified public module forwarding participates in the export graph even
# though each module-self target is otherwise independently resolvable.
printf '%s\n' 'module qualified.a' \
    'pub import qualified.b' >"$WORK/qualified-cycle-a.kofun"
printf '%s\n' 'module qualified.b' \
    'pub import qualified.a' >"$WORK/qualified-cycle-b.kofun"
{
    printf '%s|%064d|%064d|qualified.a|qualified/a.kofun|%s\n' \
        "$PACKAGE_ID" 6001 6002 "$WORK/qualified-cycle-a.kofun"
    printf '%s|%064d|%064d|qualified.b|qualified/b.kofun|%s\n' \
        "$PACKAGE_ID" 6003 6004 "$WORK/qualified-cycle-b.kofun"
} >"$WORK/qualified-cycle.inventory"
expect_failure E2S89 qualified-cycle qualified.a \
    "$WORK/qualified-cycle.inventory"

# Concrete dependency cycles can mix qualified module forwarding with a
# selective forwarding edge that resolves through that module export.
printf '%s\n' 'module mixedcycle.a' \
    'pub import mixedcycle.b' >"$WORK/mixedcycle-a.kofun"
printf '%s\n' 'module mixedcycle.b' \
    'pub from mixedcycle.a import b' >"$WORK/mixedcycle-b.kofun"
{
    printf '%s|%064d|%064d|mixedcycle.a|mixedcycle/a.kofun|%s\n' \
        "$PACKAGE_ID" 6011 6012 "$WORK/mixedcycle-a.kofun"
    printf '%s|%064d|%064d|mixedcycle.b|mixedcycle/b.kofun|%s\n' \
        "$PACKAGE_ID" 6013 6014 "$WORK/mixedcycle-b.kofun"
} >"$WORK/mixedcycle.inventory"
expect_failure E2S89 mixed-form-cycle mixedcycle.a \
    "$WORK/mixedcycle.inventory"

# Self, two-node, three-node, and competing cycles are rejected. Reversing the
# inventory preserves the canonical shortest diagnostic.
printf '%s\n' 'module cycle.self' \
    'pub from cycle.self import Loop' >"$WORK/self.kofun"
printf '%s|%s|%s|cycle.self|cycle/self.kofun|%s\n' \
    "$PACKAGE_ID" 6161616161616161616161616161616161616161616161616161616161616161 \
    6262626262626262626262626262626262626262626262626262626262626262 \
    "$WORK/self.kofun" >"$WORK/self.inventory"
expect_failure E2S89 self-cycle cycle.self "$WORK/self.inventory"
assert_num "spans in self-cycle.log" \
    "$(grep -Eo '[0-9]+\.\.[0-9]+' "$WORK/self-cycle.log" | wc -l | tr -d ' ')" \
    -ge 2

printf '%s\n' 'module cycle.a' \
    'pub from cycle.b import Loop' >"$WORK/cycle-a.kofun"
printf '%s\n' 'module cycle.b' \
    'pub from cycle.a import Loop' >"$WORK/cycle-b.kofun"
{
    printf '%s|%s|%s|cycle.a|cycle/a.kofun|%s\n' \
        "$PACKAGE_ID" 6363636363636363636363636363636363636363636363636363636363636363 \
        6464646464646464646464646464646464646464646464646464646464646464 \
        "$WORK/cycle-a.kofun"
    printf '%s|%s|%s|cycle.b|cycle/b.kofun|%s\n' \
        "$PACKAGE_ID" 6565656565656565656565656565656565656565656565656565656565656565 \
        6666666666666666666666666666666666666666666666666666666666666666 \
        "$WORK/cycle-b.kofun"
} >"$WORK/two-cycle.inventory"
expect_failure E2S89 two-cycle cycle.a "$WORK/two-cycle.inventory"
assert_grep "two-cycle.log" \
    -F 'canonical re-export cycle:' "$WORK/two-cycle.log"
sed '1!G;h;$!d' "$WORK/two-cycle.inventory" \
    >"$WORK/two-cycle-reversed.inventory"
expect_failure E2S89 two-cycle-reversed cycle.a \
    "$WORK/two-cycle-reversed.inventory"
cmp "$WORK/two-cycle.log" "$WORK/two-cycle-reversed.log"

# Mutually dependent modules with different requested spellings are missing
# targets, not a re-export cycle.
printf '%s\n' 'module mismatch.a' \
    'pub from mismatch.b import X' >"$WORK/mismatch-a.kofun"
printf '%s\n' 'module mismatch.b' \
    'pub from mismatch.a import Y' >"$WORK/mismatch-b.kofun"
{
    printf '%s|%064d|%064d|mismatch.a|mismatch/a.kofun|%s\n' \
        "$PACKAGE_ID" 6601 6701 "$WORK/mismatch-a.kofun"
    printf '%s|%064d|%064d|mismatch.b|mismatch/b.kofun|%s\n' \
        "$PACKAGE_ID" 6602 6702 "$WORK/mismatch-b.kofun"
} >"$WORK/mismatch.inventory"
expect_failure E2S86 mismatch-names mismatch.a "$WORK/mismatch.inventory"
if grep -F 'error[E2S89]:' "$WORK/mismatch-names.log" >/dev/null; then
    fail 'different selective spellings were diagnosed as a cycle'
fi

# Equal-length cycles use the independently specified CycleEdgeKey framing.
# These fixed IDs/names distinguish the correct 18-byte TLV overhead from the
# historical 12-byte length: the canonical cycle is tie.a -> tie.c -> tie.a.
printf '%s\n' 'module tie.a' \
    'pub from tie.b import X' \
    'pub from tie.c import Y' >"$WORK/tie-a.kofun"
printf '%s\n' 'module tie.b' \
    'pub from tie.a import X' >"$WORK/tie-b.kofun"
printf '%s\n' 'module tie.c' \
    'pub from tie.a import Y' >"$WORK/tie-c.kofun"
{
    printf '%s|%s|%064d|tie.a|tie/a.kofun|%s\n' \
        "$PACKAGE_ID" \
        0101010101010101010101010101010101010101010101010101010101010101 \
        11 "$WORK/tie-a.kofun"
    printf '%s|%s|%064d|tie.b|tie/b.kofun|%s\n' \
        "$PACKAGE_ID" \
        0202020202020202020202020202020202020202020202020202020202020202 \
        12 "$WORK/tie-b.kofun"
    printf '%s|%s|%064d|tie.c|tie/c.kofun|%s\n' \
        "$PACKAGE_ID" \
        0303030303030303030303030303030303030303030303030303030303030303 \
        13 "$WORK/tie-c.kofun"
} >"$WORK/tie.inventory"
expect_failure E2S89 tie-cycle tie.a "$WORK/tie.inventory"
assert_grep "tie-cycle.log" -F 'tie.a --tie/a.kofun:' "$WORK/tie-cycle.log"
assert_grep "tie-cycle.log" -F 'tie.c --tie/c.kofun:' "$WORK/tie-cycle.log"
if grep -F 'tie.b --tie/b.kofun:' "$WORK/tie-cycle.log" >/dev/null; then
    fail 'CycleEdgeKey chose the wrong equal-length cycle'
fi
sed '1!G;h;$!d' "$WORK/tie.inventory" >"$WORK/tie-reversed.inventory"
expect_failure E2S89 tie-cycle-reversed tie.a "$WORK/tie-reversed.inventory"
cmp "$WORK/tie-cycle.log" "$WORK/tie-cycle-reversed.log"

printf '%s\n' 'module cycle.c' \
    'pub from cycle.a import Loop' >"$WORK/cycle-c.kofun"
sed 's/from cycle.a/from cycle.c/' "$WORK/cycle-b.kofun" \
    >"$WORK/cycle-b-three.kofun"
{
    sed -n '1p' "$WORK/two-cycle.inventory"
    printf '%s|%s|%s|cycle.b|cycle/b.kofun|%s\n' \
        "$PACKAGE_ID" 6565656565656565656565656565656565656565656565656565656565656565 \
        6666666666666666666666666666666666666666666666666666666666666666 \
        "$WORK/cycle-b-three.kofun"
    printf '%s|%s|%s|cycle.c|cycle/c.kofun|%s\n' \
        "$PACKAGE_ID" 6767676767676767676767676767676767676767676767676767676767676767 \
        6868686868686868686868686868686868686868686868686868686868686868 \
        "$WORK/cycle-c.kofun"
} >"$WORK/three-cycle.inventory"
expect_failure E2S89 three-cycle cycle.a "$WORK/three-cycle.inventory"

printf '%s\n' 'module cycle.x' \
    'pub from cycle.y import Loop' >"$WORK/cycle-x.kofun"
printf '%s\n' 'module cycle.y' \
    'pub from cycle.z import Loop' >"$WORK/cycle-y.kofun"
printf '%s\n' 'module cycle.z' \
    'pub from cycle.x import Loop' >"$WORK/cycle-z.kofun"
{
    cat "$WORK/two-cycle.inventory"
    printf '%s|%s|%s|cycle.x|cycle/x.kofun|%s\n' \
        "$PACKAGE_ID" 7171717171717171717171717171717171717171717171717171717171717171 \
        7272727272727272727272727272727272727272727272727272727272727272 \
        "$WORK/cycle-x.kofun"
    printf '%s|%s|%s|cycle.y|cycle/y.kofun|%s\n' \
        "$PACKAGE_ID" 7373737373737373737373737373737373737373737373737373737373737373 \
        7474747474747474747474747474747474747474747474747474747474747474 \
        "$WORK/cycle-y.kofun"
    printf '%s|%s|%s|cycle.z|cycle/z.kofun|%s\n' \
        "$PACKAGE_ID" 7575757575757575757575757575757575757575757575757575757575757575 \
        7676767676767676767676767676767676767676767676767676767676767676 \
        "$WORK/cycle-z.kofun"
} >"$WORK/competing-cycle.inventory"
expect_failure E2S89 competing-cycle cycle.a \
    "$WORK/competing-cycle.inventory"
cmp "$WORK/two-cycle.log" "$WORK/competing-cycle.log"

# Exact 64-edge forwarding succeeds; one more edge fails transactionally.
: >"$WORK/chain.inventory"
printf '%s\n' 'module chain.base' \
    'pub fn Item(value: Int) -> Int {' '    return value' '}' \
    >"$WORK/chain-base.kofun"
printf '%s|%064d|%064d|chain.base|chain/base.kofun|%s\n' \
    "$PACKAGE_ID" 7001 8001 "$WORK/chain-base.kofun" \
    >>"$WORK/chain.inventory"
chain_index=0
while test "$chain_index" -lt 65; do
    current=$(printf 'chain.e%02d' "$chain_index")
    current_path=$(printf 'chain/e%02d.kofun' "$chain_index")
    current_source=$(printf '%s/chain-e%02d.kofun' "$WORK" "$chain_index")
    if test "$chain_index" -eq 0; then
        previous=chain.base
    else
        previous=$(printf 'chain.e%02d' $((chain_index - 1)))
    fi
    printf '%s\n' "module $current" \
        "pub from $previous import Item" >"$current_source"
    module_id=$(printf '%064d' $((7100 + chain_index)))
    file_id=$(printf '%064d' $((8100 + chain_index)))
    printf '%s|%s|%s|%s|%s|%s\n' \
        "$PACKAGE_ID" "$module_id" "$file_id" "$current" \
        "$current_path" "$current_source" >>"$WORK/chain.inventory"
    chain_index=$((chain_index + 1))
done
head -n 65 "$WORK/chain.inventory" >"$WORK/chain64.inventory"
"$TOOL" "$WORK/chain64.inventory" chain.e63 \
    "$WORK/chain64.hir" "$WORK/chain64.kif" "$WORK/chain64.tooling"
grep -F 'doc|facade=chain.e63.Item|canonical=chain.base.Item|' \
    "$WORK/chain64.tooling" | grep -F '|chain=64|' >/dev/null ||
    assert_fail "the chain.e63.Item doc row does not record a 64-hop chain"
"$TOOL" --resolve-kif "$WORK/chain64.kif" Item value \
    "$WORK/chain64-consumer.hir"
chain64_ids=$(
    grep -F 'export|module=chain.e63|' "$WORK/chain64.hir" |
        grep -F '|name=Item|' |
        sed -n 's/.*|chain=\([^|]*\)|.*/\1/p'
)
assert_num "hops in the chain.e63 Item re-export chain" \
    "$(printf '%s\n' "$chain64_ids" | tr ',' '\n' | wc -l | tr -d ' ')" -eq 64
assert_grep "chain64.tooling" \
    -F "|chain=64|chain-ids=$chain64_ids|" "$WORK/chain64.tooling"
assert_grep "chain64-consumer.hir" \
    -F "|chain=64|chain-ids=$chain64_ids" "$WORK/chain64-consumer.hir"
expect_failure E2S90 chain65 chain.e64 "$WORK/chain.inventory"
assert_grep "chain65.log" -E 'bytes [0-9]+\.\.[0-9]+' "$WORK/chain65.log"

# The expanded-binding exact boundary succeeds; one-over is rejected.
printf '%s\n' 'module big.target' >"$WORK/big-target.kofun"
big_index=0
while test "$big_index" -lt 513; do
    big_name=$(printf 'N%03d' "$big_index")
    printf '%s\n' \
        "pub fn $big_name(value: Int) -> Int {" \
        '    return value' \
        '}' \
        "pub type $big_name =" \
        "    | ${big_name}None" \
        "    | ${big_name}Some(value: Int)" \
        >>"$WORK/big-target.kofun"
    big_index=$((big_index + 1))
done
printf '%s\n' 'module big.facade' >"$WORK/big-facade.kofun"
for group in 0 1; do
    printf '%s' 'pub from big.target import ' >>"$WORK/big-facade.kofun"
    item=0
    while test "$item" -lt 256; do
        value=$((group * 256 + item))
        name=$(printf 'N%03d' "$value")
        if test "$item" -ne 0; then printf '%s' ', ' >>"$WORK/big-facade.kofun"; fi
        printf '%s' "$name" >>"$WORK/big-facade.kofun"
        item=$((item + 1))
    done
    printf '\n' >>"$WORK/big-facade.kofun"
done
{
    printf '%s|%064d|%064d|big.target|big/target.kofun|%s\n' \
        "$PACKAGE_ID" 9101 9201 "$WORK/big-target.kofun"
    printf '%s|%064d|%064d|big.facade|big/facade.kofun|%s\n' \
        "$PACKAGE_ID" 9102 9202 "$WORK/big-facade.kofun"
} >"$WORK/big.inventory"
"$TOOL" "$WORK/big.inventory" big.facade \
    "$WORK/big.hir" "$WORK/big.kif" "$WORK/big.tooling"
assert_num "^export| lines in big.hir" \
    "$(grep -c '^export|' "$WORK/big.hir")" -eq 1024
printf '%s\n' 'pub from big.target import N512' \
    >>"$WORK/big-facade.kofun"
expect_failure E2S90 expanded-over big.facade "$WORK/big.inventory"
assert_grep "expanded-over.log" \
    -E 'bytes [0-9]+\.\.[0-9]+' "$WORK/expanded-over.log"

# Exactly 256 source re-export declarations succeed; the 257th is rejected.
printf '%s\n' 'module declarations.facade' \
    >"$WORK/declarations-facade.kofun"
declaration_index=0
while test "$declaration_index" -lt 256; do
    declaration_name=$(printf 'N%03d' "$declaration_index")
    printf '%s\n' "pub from big.target import $declaration_name" \
        >>"$WORK/declarations-facade.kofun"
    declaration_index=$((declaration_index + 1))
done
{
    printf '%s|%064d|%064d|big.target|big/target.kofun|%s\n' \
        "$PACKAGE_ID" 9101 9201 "$WORK/big-target.kofun"
    printf '%s|%064d|%064d|declarations.facade|declarations/facade.kofun|%s\n' \
        "$PACKAGE_ID" 9301 9302 "$WORK/declarations-facade.kofun"
} >"$WORK/declarations.inventory"
"$TOOL" "$WORK/declarations.inventory" declarations.facade \
    "$WORK/declarations.hir" "$WORK/declarations.kif" \
    "$WORK/declarations.tooling"
assert_num "^export| lines in declarations.hir" \
    "$(grep -c '^export|' "$WORK/declarations.hir")" -eq 512
printf '%s\n' 'pub from big.target import N256' \
    >>"$WORK/declarations-facade.kofun"
expect_failure E2S90 declarations-over declarations.facade \
    "$WORK/declarations.inventory"
assert_grep "declarations-over.log" \
    -E 'bytes [0-9]+\.\.[0-9]+' "$WORK/declarations-over.log"

# The package-wide expanded-edge boundary is executable: 64 facades with
# 1,024 value/type bindings each succeed, and the 65,537th edge is rejected.
: >"$WORK/package-edges.inventory"
sed 's/^module big\.target$/module package.target/' \
    "$WORK/big-target.kofun" >"$WORK/package-target.kofun"
printf '%s|%064d|%064d|package.target|package/target.kofun|%s\n' \
    "$PACKAGE_ID" 9400 9500 "$WORK/package-target.kofun" \
    >>"$WORK/package-edges.inventory"
package_facade=0
while test "$package_facade" -lt 65; do
    package_module=$(printf 'package.f%02d' "$package_facade")
    package_path=$(printf 'package/f%02d.kofun' "$package_facade")
    package_source=$(printf '%s/package-f%02d.kofun' \
        "$WORK" "$package_facade")
    printf '%s\n' "module $package_module" >"$package_source"
    for group in 0 1; do
        printf '%s' 'pub from package.target import ' >>"$package_source"
        item=0
        while test "$item" -lt 256; do
            value=$((group * 256 + item))
            name=$(printf 'N%03d' "$value")
            if test "$item" -ne 0; then
                printf '%s' ', ' >>"$package_source"
            fi
            printf '%s' "$name" >>"$package_source"
            item=$((item + 1))
        done
        printf '\n' >>"$package_source"
    done
    printf '%s|%064d|%064d|%s|%s|%s\n' \
        "$PACKAGE_ID" $((9401 + package_facade)) \
        $((9501 + package_facade)) "$package_module" "$package_path" \
        "$package_source" >>"$WORK/package-edges.inventory"
    package_facade=$((package_facade + 1))
done
head -n 65 "$WORK/package-edges.inventory" \
    >"$WORK/package-edges-exact.inventory"
"$TOOL" "$WORK/package-edges-exact.inventory" package.f63 \
    "$WORK/package-edges.hir" "$WORK/package-edges.kif" \
    "$WORK/package-edges.tooling"
assert_num "^export| lines in package-edges.hir" \
    "$(grep -c '^export|' "$WORK/package-edges.hir")" -eq 65536
expect_failure E2S90 package-edges-over package.f64 \
    "$WORK/package-edges.inventory"
assert_grep "package-edges-over.log" \
    -E 'bytes [0-9]+\.\.[0-9]+' "$WORK/package-edges-over.log"

# A test-only lower operation budget exercises the production budget failure
# path without changing the release limit.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -DRE_EXPORT_GRAPH_WORK_LIMIT=1 \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/re_exports.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/re-exports-low-work"
set +e
"$WORK/re-exports-low-work" "$WORK/two-level.inventory" api.v2 \
    "$WORK/low-work.hir" "$WORK/low-work.kif" "$WORK/low-work.tooling" \
    >"$WORK/low-work.log" 2>&1
low_work_status=$?
set -e
assert_num "low work status" "$low_work_status" -eq 1
assert_grep "low-work.log" -F 'error[E2S90]:' "$WORK/low-work.log"
assert_grep "low-work.log" -E 'bytes [0-9]+\.\.[0-9]+' "$WORK/low-work.log"
assert_absent "low-work.hir" "$WORK/low-work.hir"
assert_absent "low-work.kif" "$WORK/low-work.kif"
assert_absent "low-work.tooling" "$WORK/low-work.tooling"

# Input and output identities are preflighted before any requested output is
# removed. Exact paths and hardlinks preserve inventory, source, and KIF bytes.
cp "$WORK/positive.inventory" "$WORK/alias-inventory"
cp "$WORK/alias-inventory" "$WORK/alias-inventory.snapshot"
set +e
"$TOOL" "$WORK/alias-inventory" api.collections \
    "$WORK/alias-inventory" "$WORK/alias-inventory.kif" \
    "$WORK/alias-inventory.tooling" >"$WORK/alias-inventory.log" 2>&1
alias_status=$?
set -e
assert_num "rejection status for an inventory aliased to the HIR output" \
    "$alias_status" -eq 1
assert_grep "alias-inventory.log" \
    -F 'error[E2S92]:' "$WORK/alias-inventory.log"
cmp "$WORK/alias-inventory.snapshot" "$WORK/alias-inventory"
assert_absent "alias-inventory.kif" "$WORK/alias-inventory.kif"
assert_absent "alias-inventory.tooling" "$WORK/alias-inventory.tooling"

cp "$WORK/positive.inventory" "$WORK/alias-inventory-hard"
cp "$WORK/alias-inventory-hard" "$WORK/alias-inventory-hard.snapshot"
ln "$WORK/alias-inventory-hard" "$WORK/alias-inventory-hard.hir"
set +e
"$TOOL" "$WORK/alias-inventory-hard" api.collections \
    "$WORK/alias-inventory-hard.hir" "$WORK/alias-inventory-hard.kif" \
    "$WORK/alias-inventory-hard.tooling" \
    >"$WORK/alias-inventory-hard.log" 2>&1
alias_status=$?
set -e
assert_num "rejection status for an inventory hardlinked to the HIR output" \
    "$alias_status" -eq 1
assert_grep "alias-inventory-hard.log" \
    -F 'error[E2S92]:' "$WORK/alias-inventory-hard.log"
cmp "$WORK/alias-inventory-hard.snapshot" "$WORK/alias-inventory-hard"
cmp "$WORK/alias-inventory-hard.snapshot" "$WORK/alias-inventory-hard.hir"

cp "$CASES/fixtures/collections.kofun" "$WORK/alias-source.kofun"
cp "$WORK/alias-source.kofun" "$WORK/alias-source.snapshot"
{
    printf '%s|%s|%s|lib.collections|lib/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$COLLECTIONS_MODULE" "$COLLECTIONS_FILE" \
        "$WORK/alias-source.kofun"
    printf '%s|%s|%s|api.collections|api/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$FACADE_MODULE" "$FACADE_FILE" \
        "$CASES/fixtures/facade.kofun"
} >"$WORK/alias-source.inventory"
set +e
"$TOOL" "$WORK/alias-source.inventory" api.collections \
    "$WORK/alias-source.kofun" "$WORK/alias-source.kif" \
    "$WORK/alias-source.tooling" >"$WORK/alias-source.log" 2>&1
alias_status=$?
set -e
assert_num "rejection status for a source aliased to the HIR output" \
    "$alias_status" -eq 1
assert_grep "alias-source.log" -F 'error[E2S92]:' "$WORK/alias-source.log"
cmp "$WORK/alias-source.snapshot" "$WORK/alias-source.kofun"

cp "$WORK/alias-source.snapshot" "$WORK/alias-source-hard.kofun"
ln "$WORK/alias-source-hard.kofun" "$WORK/alias-source-hard.hir"
sed "s|$WORK/alias-source.kofun|$WORK/alias-source-hard.kofun|" \
    "$WORK/alias-source.inventory" >"$WORK/alias-source-hard.inventory"
set +e
"$TOOL" "$WORK/alias-source-hard.inventory" api.collections \
    "$WORK/alias-source-hard.hir" "$WORK/alias-source-hard.kif" \
    "$WORK/alias-source-hard.tooling" \
    >"$WORK/alias-source-hard.log" 2>&1
alias_status=$?
set -e
assert_num "rejection status for a source hardlinked to the HIR output" \
    "$alias_status" -eq 1
assert_grep "alias-source-hard.log" \
    -F 'error[E2S92]:' "$WORK/alias-source-hard.log"
cmp "$WORK/alias-source.snapshot" "$WORK/alias-source-hard.kofun"
cmp "$WORK/alias-source.snapshot" "$WORK/alias-source-hard.hir"

set +e
"$TOOL" "$WORK/positive.inventory" api.collections \
    "$WORK/alias-outputs" "$WORK/alias-outputs" \
    "$WORK/alias-outputs.tooling" >"$WORK/alias-outputs.log" 2>&1
alias_status=$?
set -e
assert_num "rejection status for two outputs at one path" "$alias_status" -eq 1
assert_grep "alias-outputs.log" -F 'error[E2S92]:' "$WORK/alias-outputs.log"

printf '%s\n' preserved >"$WORK/alias-output-hard-a"
ln "$WORK/alias-output-hard-a" "$WORK/alias-output-hard-b"
set +e
"$TOOL" "$WORK/positive.inventory" api.collections \
    "$WORK/alias-output-hard-a" "$WORK/alias-output-hard-b" \
    "$WORK/alias-output-hard-tooling" \
    >"$WORK/alias-output-hard.log" 2>&1
alias_status=$?
set -e
assert_num "rejection status for hardlinked outputs" "$alias_status" -eq 1
assert_grep "alias-output-hard.log" \
    -F 'error[E2S92]:' "$WORK/alias-output-hard.log"
assert_grep "alias-output-hard-a" -Fx preserved "$WORK/alias-output-hard-a"
assert_grep "alias-output-hard-b" -Fx preserved "$WORK/alias-output-hard-b"

cp "$WORK/positive.kif" "$WORK/resolve-alias.kif"
cp "$WORK/resolve-alias.kif" "$WORK/resolve-alias.snapshot"
set +e
"$TOOL" --resolve-kif "$WORK/resolve-alias.kif" Map value \
    "$WORK/resolve-alias.kif" >"$WORK/resolve-alias.log" 2>&1
alias_status=$?
set -e
assert_num "rejection status for --resolve-kif writing over its input" \
    "$alias_status" -eq 1
assert_grep "resolve-alias.log" -F 'error[E2S92]:' "$WORK/resolve-alias.log"
cmp "$WORK/resolve-alias.snapshot" "$WORK/resolve-alias.kif"

cp "$WORK/positive.kif" "$WORK/resolve-alias-hard.kif"
ln "$WORK/resolve-alias-hard.kif" "$WORK/resolve-alias-hard.hir"
set +e
"$TOOL" --resolve-kif "$WORK/resolve-alias-hard.kif" Map value \
    "$WORK/resolve-alias-hard.hir" >"$WORK/resolve-alias-hard.log" 2>&1
alias_status=$?
set -e
assert_num "rejection status for a --resolve-kif output hardlinked to its input" \
    "$alias_status" -eq 1
assert_grep "resolve-alias-hard.log" \
    -F 'error[E2S92]:' "$WORK/resolve-alias-hard.log"
cmp "$WORK/positive.kif" "$WORK/resolve-alias-hard.kif"
cmp "$WORK/positive.kif" "$WORK/resolve-alias-hard.hir"

# Defensive KIF consumption and output/internal failures have stable focused
# categories and never publish a partial success artifact.
cp "$WORK/positive.kif" "$WORK/corrupt.kif"
printf '\001' | dd of="$WORK/corrupt.kif" bs=1 seek=0 \
    conv=notrunc status=none
set +e
"$TOOL" --resolve-kif "$WORK/corrupt.kif" Map value \
    "$WORK/corrupt-consumer.hir" >"$WORK/corrupt-kif.log" 2>&1
corrupt_status=$?
set -e
assert_num "corrupt status" "$corrupt_status" -eq 1
assert_grep "corrupt-kif.log" -F 'error[E2S91]:' "$WORK/corrupt-kif.log"
assert_absent "corrupt-consumer.hir" "$WORK/corrupt-consumer.hir"

set +e
"$TOOL" --resolve-kif "$WORK/positive.kif" Missing value \
    "$WORK/missing-export.hir" >"$WORK/missing-export.log" 2>&1
missing_export_status=$?
set -e
assert_num "missing export status" "$missing_export_status" -eq 1
assert_grep "missing-export.log" -F 'error[E2S93]:' "$WORK/missing-export.log"
assert_absent "missing-export.hir" "$WORK/missing-export.hir"

set +e
"$TOOL" "$WORK/positive.inventory" api.collections \
    "$WORK/absent/out.hir" "$WORK/io.kif" "$WORK/io.tooling" \
    >"$WORK/io.log" 2>&1
io_status=$?
set -e
assert_num "io status" "$io_status" -eq 1
assert_grep "io.log" -F 'error[E2S92]:' "$WORK/io.log"
assert_absent "absent/out.hir" "$WORK/absent/out.hir"
assert_absent "io.kif" "$WORK/io.kif"
assert_absent "io.tooling" "$WORK/io.tooling"

printf '%s\n' stale >"$WORK/internal.hir"
printf '%s\n' stale >"$WORK/internal.kif"
printf '%s\n' stale >"$WORK/internal.tooling"
set +e
KOFUN_DIAGNOSTIC_FAULT=re-export-chain \
    "$TOOL" "$WORK/positive.inventory" api.collections \
    "$WORK/internal.hir" "$WORK/internal.kif" "$WORK/internal.tooling" \
    >"$WORK/internal.log" 2>&1
internal_status=$?
set -e
assert_num "internal status" "$internal_status" -eq 1
assert_grep "internal.log" -F 'error[E2S94]:' "$WORK/internal.log"
assert_absent "internal.hir" "$WORK/internal.hir"
assert_absent "internal.kif" "$WORK/internal.kif"
assert_absent "internal.tooling" "$WORK/internal.tooling"

# Existing prerequisite gates stay independently executable.
# Each nested helper builds under this gate's own namespace, so running them
# here cannot race the same scripts running as their own `task verify` targets
# (#713).
KOFUN_GATE_WORK_NAMESPACE="${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}nested-re-exports" \
    sh "$ROOT/tests/conformance/modules/imports-qualified/run.sh"
KOFUN_GATE_WORK_NAMESPACE="${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}nested-re-exports" \
    sh "$ROOT/tests/conformance/modules/imports-selective/run.sh"
KOFUN_GATE_WORK_NAMESPACE="${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}nested-re-exports" \
    sh "$ROOT/tests/conformance/modules/kif-v1/run.sh"
sh "$ROOT/spec/re-exports/check.sh"

if command -v clang >/dev/null 2>&1; then
    clang -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/re_exports.c" \
        "$ROOT/bootstrap/stage2/kif_v1.c" \
        "$ROOT/bootstrap/stage2/visibility_access.c" \
        "$ROOT/unicode/kofun_unicode.c" \
        "$ROOT/bootstrap/stage2/sha256.c" \
        -o "$WORK/re-exports-clang"
    "$WORK/re-exports-clang" "$WORK/positive.inventory" api.collections \
        "$WORK/clang.hir" "$WORK/clang.kif" "$WORK/clang.tooling"
    cmp "$WORK/positive.kif" "$WORK/clang.kif"
fi

"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/re_exports.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/re-exports-sanitized"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/re-exports-sanitized" "$WORK/positive.inventory" api.collections \
    "$WORK/sanitized.hir" "$WORK/sanitized.kif" "$WORK/sanitized.tooling"
cmp "$WORK/positive.kif" "$WORK/sanitized.kif"

re_exports_analyzer_evidence="$WORK/re-exports-analyzer.evidence"
run_re_export_analyzer "$WORK/re-exports-analyzed" \
    >"$re_exports_analyzer_evidence"
assert_num "named re-export analyzer PASS count" \
    "$(grep -Fxc \
        'PASS: GCC analyzer accepts the re-export resolver and KIF projection' \
        "$re_exports_analyzer_evidence")" -eq 1
assert_executable "successful re-export analyzer output" \
    "$WORK/re-exports-analyzed"
assert_file_empty "successful re-export analyzer stdout" \
    "$WORK/re-exports-analyzed.stdout"
assert_file_empty "successful re-export analyzer stderr" \
    "$WORK/re-exports-analyzed.stderr"
cat "$re_exports_analyzer_evidence"

# The same fail-closed arm used above must preserve a compiler's stderr, name
# the failed profile, publish no PASS, and leave no partial executable.  A
# synthetic compiler keeps this mutation cheap enough to run under both the
# direct task and the diagnostics adapter, which owns a second full execution.
re_exports_analyzer_fake_cc="$WORK/re-exports-analyzer-failure-cc"
re_exports_analyzer_fake_argv="$WORK/re-exports-analyzer-failure.argv"
re_exports_analyzer_fake_partial="$WORK/re-exports-analyzer-failure.partial"
re_exports_analyzer_expected_argv="$WORK/re-exports-analyzer-failure.expected"
re_exports_analyzer_mutation_output="$WORK/re-exports-analyzer-failure-output"
re_exports_analyzer_mutation_stdout="$WORK/re-exports-analyzer-failure-observer.stdout"
re_exports_analyzer_mutation_stderr="$WORK/re-exports-analyzer-failure-observer.stderr"
cat >"$re_exports_analyzer_fake_cc" <<'EOF'
#!/usr/bin/env sh
set -eu
: "${KOFUN_RE_EXPORT_ANALYZER_FAKE_ARGV:?}"
: "${KOFUN_RE_EXPORT_ANALYZER_FAKE_PARTIAL:?}"
printf '%s\n' "$@" >"$KOFUN_RE_EXPORT_ANALYZER_FAKE_ARGV"
re_exports_fake_output=
re_exports_fake_output_count=0
while test "$#" -gt 0
do
    if test "$1" = -o; then
        re_exports_fake_output_count=$((re_exports_fake_output_count + 1))
        shift
        if test "$#" -eq 0; then
            printf '%s\n' 'fake analyzer compiler: -o has no target' >&2
            exit 97
        fi
        re_exports_fake_output=$1
    fi
    shift
done
if test "$re_exports_fake_output_count" -ne 1 ||
    test -z "$re_exports_fake_output"
then
    printf '%s\n' 'fake analyzer compiler: expected exactly one -o target' >&2
    exit 97
fi
if test -e "$re_exports_fake_output"; then
    printf '%s\n' 'fake analyzer compiler: output was not clean before launch' >&2
    exit 97
fi
printf '%s\n' 'partial analyzer executable' >"$re_exports_fake_output"
if ! test -f "$re_exports_fake_output"; then
    printf '%s\n' 'fake analyzer compiler: partial output is not regular' >&2
    exit 97
fi
printf '%s\n' "$re_exports_fake_output" \
    >"$KOFUN_RE_EXPORT_ANALYZER_FAKE_PARTIAL"
printf '%s\n' 'forced re-export analyzer failure after partial output' >&2
exit 73
EOF
chmod 0755 "$re_exports_analyzer_fake_cc"
rm -f -- "$re_exports_analyzer_fake_argv" \
    "$re_exports_analyzer_fake_partial"
set +e
(
    CC="$re_exports_analyzer_fake_cc"
    KOFUN_RE_EXPORT_ANALYZER_FAKE_ARGV="$re_exports_analyzer_fake_argv"
    KOFUN_RE_EXPORT_ANALYZER_FAKE_PARTIAL="$re_exports_analyzer_fake_partial"
    export CC KOFUN_RE_EXPORT_ANALYZER_FAKE_ARGV
    export KOFUN_RE_EXPORT_ANALYZER_FAKE_PARTIAL
    run_re_export_analyzer "$re_exports_analyzer_mutation_output"
) >"$re_exports_analyzer_mutation_stdout" \
    2>"$re_exports_analyzer_mutation_stderr"
re_exports_analyzer_mutation_status=$?
set -e
assert_num "forced re-export analyzer failure status" \
    "$re_exports_analyzer_mutation_status" -eq 73
assert_file_empty "forced re-export analyzer observer stdout" \
    "$re_exports_analyzer_mutation_stdout"
assert_grep "forced re-export analyzer named failure" \
    -F "FAIL: re-exports: GCC analyzer compile failed with status 73;" \
    "$re_exports_analyzer_mutation_stderr"
assert_grep "forced re-export analyzer captured stderr" \
    -Fx 'forced re-export analyzer failure after partial output' \
    "$re_exports_analyzer_mutation_output.stderr"
assert_grep "forced re-export analyzer replayed stderr" \
    -Fx 'forced re-export analyzer failure after partial output' \
    "$re_exports_analyzer_mutation_stderr"
assert_not_grep "forced re-export analyzer emitted no PASS" \
    -F 'PASS: GCC analyzer accepts the re-export resolver and KIF projection' \
    "$re_exports_analyzer_mutation_stderr"
assert_absent "forced re-export analyzer output" \
    "$re_exports_analyzer_mutation_output"
assert_grep "forced re-export analyzer created a partial regular output" \
    -Fx "$re_exports_analyzer_mutation_output" \
    "$re_exports_analyzer_fake_partial"
# Keep the runtime strings below exact while splitting directory and filename
# tokens so this golden fixture is not counted as a static compile site.
#
# The four common inputs are named through the #1449 accessor rather than
# written out, because this fixture's whole claim is that the forced path
# receives *the production argv*. Spelling the sources here would pin one mode
# and pass by accident in the other: with the object bundle published these are
# prebuilt `.o` members, and without it they are the `.c` sources.
{
    printf '%s\n' \
        -std=c11 \
        -O0 \
        -Wall \
        -Wextra \
        -Werror \
        -pedantic \
        -fanalyzer \
        "-I$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/re_exports.c" \
        "$KOFUN_STAGE2_ANALYZER_KIF_V1_INPUT" \
        "$KOFUN_STAGE2_ANALYZER_VISIBILITY_INPUT" \
        "$KOFUN_STAGE2_ANALYZER_UNICODE_INPUT" \
        "$KOFUN_STAGE2_ANALYZER_SHA256_INPUT" \
        -o \
        "$re_exports_analyzer_mutation_output"
} >"$re_exports_analyzer_expected_argv"
cmp "$re_exports_analyzer_expected_argv" \
    "$re_exports_analyzer_fake_argv" ||
    fail 'forced re-export analyzer did not receive the exact production argv'

printf '%s\n' \
    'PASS: explicit public re-exports preserve target identities and non-widening visibility' \
    'PASS: canonical chains/cycles and 64/65 boundaries are executable' \
    'PASS: public export KIF facts and source-free facade consumption are transactional' \
    'PASS: facade/canonical tooling paths do not claim linker, FFI, or runtime forwarding'

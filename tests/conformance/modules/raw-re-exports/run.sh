#!/bin/sh
set -eu

# #1216. RFC-0012 step 4: no re-export may launder a raw-foreign origin.
#
# #1215 decided who may *import* a raw module. This decides who may pass one on.
# The two are different questions and the difference is the whole point: an
# admitted `trusted import` is a crossing the importer reviewed, and a
# re-export hands that crossing to someone who reviewed nothing.
#
# The facade is not thereby useless. It may export its own ordinary
# declarations even when their bodies call into an admitted raw import — that
# is the reviewed wrapper the rule exists to require, and it is checked here as
# an *accepted* case, because a rule that refused it would be refusing the only
# correct way to use a raw module.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/modules/raw-re-exports/fixtures"
CC=${CC:-cc}
ASSERT_CONTEXT='raw re-exports'
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-raw-re-exports.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

command -v "$CC" >/dev/null 2>&1 || assert_fail 'a C11 compiler is required'

build_tool() {
    source_override=$1
    output=$2
    # A mutant is written outside the source tree, so the include path has to be
    # explicit: `re_exports.c` includes its siblings beside it.
    "$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
        -I "$ROOT/bootstrap/stage2" \
        "$source_override" \
        "$ROOT/bootstrap/stage2/kif_v1.c" \
        "$ROOT/bootstrap/stage2/visibility_access.c" \
        "$ROOT/unicode/kofun_unicode.c" \
        "$ROOT/bootstrap/stage2/sha256.c" \
        -o "$output"
}

build_tool "$ROOT/bootstrap/stage2/re_exports.c" "$WORK/tool"

id_for() {
    printf '%s' "$1" | "$ROOT/bin/kofun-digest" | awk '{ print $1 }'
}

PACKAGE_ID=$(id_for 'raw-re-exports')

# One inventory writer for every case, so the only thing that varies between an
# accepted and a refused run is the facade's source text and whether the
# library carries `trust raw-foreign`.
write_inventory() {
    library_source=$1
    facade_source=$2
    output=$3
    {
        printf '%s|%s|%s|lib.collections|lib/collections.kofun|%s\n' \
            "$PACKAGE_ID" "$(id_for 'lib.collections')" \
            "$(id_for 'lib/collections.kofun')" "$library_source"
        printf '%s|%s|%s|api.collections|api/collections.kofun|%s\n' \
            "$PACKAGE_ID" "$(id_for 'api.collections')" \
            "$(id_for 'api/collections.kofun')" "$facade_source"
    } >"$output"
}

accepts() {
    label=$1
    library_source=$2
    facade_source=$3
    rm -f "$WORK/$label.hir" "$WORK/$label.kif" "$WORK/$label.tooling"
    write_inventory "$library_source" "$facade_source" "$WORK/$label.inventory"
    "$WORK/tool" "$WORK/$label.inventory" api.collections \
        "$WORK/$label.hir" "$WORK/$label.kif" "$WORK/$label.tooling" \
        >"$WORK/$label.log" 2>&1 ||
        assert_fail "$label was refused: $(cat "$WORK/$label.log")"
    test -s "$WORK/$label.hir" || assert_fail "$label produced no HIR"
    test -s "$WORK/$label.kif" || assert_fail "$label produced no KIF"
}

refuses() {
    label=$1
    code=$2
    library_source=$3
    facade_source=$4
    rm -f "$WORK/$label.hir" "$WORK/$label.kif" "$WORK/$label.tooling"
    write_inventory "$library_source" "$facade_source" "$WORK/$label.inventory"
    if "$WORK/tool" "$WORK/$label.inventory" api.collections \
        "$WORK/$label.hir" "$WORK/$label.kif" "$WORK/$label.tooling" \
        >"$WORK/$label.log" 2>&1
    then
        assert_fail "$label was accepted"
    fi
    assert_grep "$label is refused as $code" \
        -F "error[$code]:" "$WORK/$label.log"
    # Transactional publication: a refusal publishes nothing, including the
    # scratch artifact the trust round-trip writes beside the HIR.
    assert_absent "$label HIR" "$WORK/$label.hir"
    assert_absent "$label KIF" "$WORK/$label.kif"
    assert_absent "$label tooling" "$WORK/$label.tooling"
    assert_absent "$label trust scratch" "$WORK/$label.hir.trust.kif"
}

# ------------------------------------------------------------------- refusals

refuses pub_import_raw E2S173 \
    "$CASES/raw_collections.kofun" "$CASES/pub_import_raw.kofun"
refuses pub_from_raw E2S173 \
    "$CASES/raw_collections.kofun" "$CASES/pub_from_raw.kofun"

# The refusal names the raw module and its ModuleId, because a reader who is
# only told "this is raw" cannot tell which module to go and look at.
assert_grep 'the refusal names the raw origin module path' \
    -F 'raw-foreign module `lib.collections`' "$WORK/pub_from_raw.log"
assert_grep 'the refusal carries the origin ModuleId' \
    -Eq -- 'ModuleId [0-9a-f]{64}' "$WORK/pub_from_raw.log"

# ------------------------------------------------------------------- accepted

# The reviewed wrapper. This is the case the rule exists to leave available,
# and a version of the rule that refused it would be worse than no rule: it
# would make an admitted raw import unusable.
accepts wraps_raw "$CASES/raw_collections.kofun" "$CASES/wraps_raw.kofun"

# The same facade over an *ordinary* library is unchanged. Without this, a
# resolver that refused every `pub from` would pass both refusals above.
accepts ordinary_forward \
    "$ROOT/tests/conformance/modules/re-exports/fixtures/collections.kofun" \
    "$CASES/pub_from_raw.kofun"

# ------------------------------------------------------------------- mutation

mutation() {
    name=$1
    expression=$2
    label=$3
    code=$4
    library_source=$5
    facade_source=$6
    sed "$expression" "$ROOT/bootstrap/stage2/re_exports.c" \
        >"$WORK/mutant-$name.c"
    cmp -s "$ROOT/bootstrap/stage2/re_exports.c" "$WORK/mutant-$name.c" &&
        assert_fail "mutation $name changed nothing; its pattern no longer matches"
    build_tool "$WORK/mutant-$name.c" "$WORK/mutant-$name" \
        >"$WORK/mutant-$name.build.stdout" 2>"$WORK/mutant-$name.build.stderr" ||
        assert_fail "mutation $name does not build; it is testing the compiler rather than the resolver: $(head -1 "$WORK/mutant-$name.build.stderr")"
    write_inventory "$library_source" "$facade_source" \
        "$WORK/mutant-$name.inventory"
    rm -f "$WORK/mutant-$name.hir" "$WORK/mutant-$name.kif" \
        "$WORK/mutant-$name.tooling"
    "$WORK/mutant-$name" "$WORK/mutant-$name.inventory" api.collections \
        "$WORK/mutant-$name.hir" "$WORK/mutant-$name.kif" \
        "$WORK/mutant-$name.tooling" >"$WORK/mutant-$name.log" 2>&1 || true
    # The claim is "without this, the refusal does not happen" -- so the
    # assertion is that the code disappears, not that the exit is non-zero. A
    # mutant may exit non-zero for an unrelated reason and prove nothing.
    if grep -Fq "error[$code]:" "$WORK/mutant-$name.log"; then
        assert_fail "mutation $name still refused $label with $code; it did not disable what it names"
    fi
}

# The decision reads the serialized class, exactly as #1215's admission does.
# Reading the parsed source fact agrees in every fixture here, so this mutation
# is what separates the two.
mutation serialized-origin-class \
    's|.serialized_trust == KOFUN_KIF_TRUST_RAW_FOREIGN) {|.serialized_trust == KOFUN_KIF_TRUST_ORDINARY) {|' \
    pub_from_raw E2S173 \
    "$CASES/raw_collections.kofun" "$CASES/pub_from_raw.kofun"

# ------------------------------------------------- transitivity by induction
#
# A chain that ends in raw cannot be built. The middle module is refused where
# it forwards, before anything outer resolves, so no legal link can ever carry
# a raw origin onward. This is checked rather than argued: the three-module
# inventory is resolved for the outermost facade and the refusal names the
# *middle* module's line.
{
    printf '%s|%s|%s|lib.collections|lib/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$(id_for 'lib.collections')" \
        "$(id_for 'lib/collections.kofun')" "$CASES/raw_collections.kofun"
    printf '%s|%s|%s|mid.collections|mid/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$(id_for 'mid.collections')" \
        "$(id_for 'mid/collections.kofun')" "$CASES/mid_forwards.kofun"
    printf '%s|%s|%s|api.collections|api/collections.kofun|%s\n' \
        "$PACKAGE_ID" "$(id_for 'api.collections')" \
        "$(id_for 'api/collections.kofun')" "$CASES/chained_facade.kofun"
} >"$WORK/chain.inventory"
rm -f "$WORK/chain.hir" "$WORK/chain.kif" "$WORK/chain.tooling"
if "$WORK/tool" "$WORK/chain.inventory" api.collections \
    "$WORK/chain.hir" "$WORK/chain.kif" "$WORK/chain.tooling" \
    >"$WORK/chain.log" 2>&1
then
    assert_fail 'a three-module chain ending in a raw module was accepted'
fi
assert_grep 'the chain is refused at the middle module, not the outer facade' \
    -F 'in `mid/collections.kofun`' "$WORK/chain.log"
assert_absent 'chain HIR' "$WORK/chain.hir"

printf '%s\n' \
    'PASS: no re-export passes on a raw-foreign origin, the refusal names the origin module and its ModuleId, a chain ending in raw is refused at its first link, a facade may still export its own declarations over an admitted raw import, and ordinary forwarding is unchanged'

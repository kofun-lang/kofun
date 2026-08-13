#!/bin/sh
set -eu

# #1215. Import admission across a trust boundary.
#
# The rule has two halves and each is useless without the other: an ordinary
# import of a `raw-foreign` module must fail, and a `trusted import` of an
# ordinary module must fail too. Only the first is about safety; the second is
# what stops the marker from becoming decorative, which is the state a marker
# reaches when writing it is always harmless.
#
# The assertion that matters most is not either refusal. It is that the
# decision is taken from the **serialized** trust class rather than from the
# parse: those two agree in every fixture anyone has written, so a resolver
# that read `module->trust_raw_foreign` at the decision point would pass every
# case below while proving nothing about serialization. That is checked by
# mutation at the end rather than by reading the source.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/modules/raw-imports/fixtures"
CC=${CC:-cc}
ASSERT_CONTEXT='raw imports'
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-raw-imports.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

command -v "$CC" >/dev/null 2>&1 || assert_fail 'a C11 compiler is required'

build_tool() {
    source_override=$1
    output=$2
    # A mutant is written outside the source tree, so the include path has to
    # be explicit: `imports_qualified.c` includes `module_symbols.c` beside it.
    "$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
        -I "$ROOT/bootstrap/stage2" \
        "$source_override" \
        "$ROOT/bootstrap/stage2/kif_v1.c" \
        "$ROOT/bootstrap/stage2/visibility_access.c" \
        "$ROOT/unicode/kofun_unicode.c" \
        "$ROOT/bootstrap/stage2/sha256.c" \
        -o "$output"
}

build_tool "$ROOT/bootstrap/stage2/imports_qualified.c" "$WORK/tool"

id_for() {
    printf '%s' "$1" | "$ROOT/bin/kofun-digest" | awk '{ print $1 }'
}

PACKAGE_ID=$(id_for 'raw-imports')

# The inventory binds a declared module path to a ModuleId and a host path.
# Every case below reuses one inventory writer, so the *only* thing that varies
# between an accepted and a refused case is the source text.
write_inventory() {
    main_source=$1
    library_path=$2
    library_source=$3
    output=$4
    {
        printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
            "$PACKAGE_ID" "$(id_for 'app.main')" "$(id_for 'app/main.kofun')" \
            "$main_source"
        printf '%s|%s|%s|%s|lib/library.kofun|%s\n' \
            "$PACKAGE_ID" "$(id_for "$library_path")" \
            "$(id_for 'lib/library.kofun')" "$library_path" "$library_source"
    } >"$output"
}

accepts() {
    label=$1
    main_source=$2
    library_path=$3
    library_source=$4
    rm -f "$WORK/$label.hir" "$WORK/$label.c"
    write_inventory "$main_source" "$library_path" "$library_source" \
        "$WORK/$label.inventory"
    "$WORK/tool" "$WORK/$label.inventory" "$WORK/$label.hir" "$WORK/$label.c" \
        >"$WORK/$label.log" 2>&1 ||
        assert_fail "$label was refused: $(cat "$WORK/$label.log")"
    test -s "$WORK/$label.hir" ||
        assert_fail "$label produced no HIR"
}

refuses() {
    label=$1
    code=$2
    main_source=$3
    library_path=$4
    library_source=$5
    rm -f "$WORK/$label.hir" "$WORK/$label.c"
    write_inventory "$main_source" "$library_path" "$library_source" \
        "$WORK/$label.inventory"
    if "$WORK/tool" "$WORK/$label.inventory" "$WORK/$label.hir" \
        "$WORK/$label.c" >"$WORK/$label.log" 2>&1
    then
        assert_fail "$label was accepted"
    fi
    assert_grep "$label is refused as $code" \
        -F "error[$code]:" "$WORK/$label.log"
    # "Fail before any artifact is published" is a property of the refusal, not
    # a hope about it. A resolver that decided late would leave these behind.
    assert_absent "$label HIR" "$WORK/$label.hir"
    assert_absent "$label reference C" "$WORK/$label.c"
    # No scratch artifact outlives the run either; the trust round-trip writes
    # one beside the HIR and removes it as soon as it has been read.
    assert_absent "$label trust scratch" "$WORK/$label.hir.trust.kif"
}

# ------------------------------------------------------------------ admission

accepts crossing "$CASES/crossing.kofun" lib.raw "$CASES/raw.kofun"
refuses ordinary_of_raw E2S171 \
    "$CASES/ordinary_of_raw.kofun" lib.raw "$CASES/raw.kofun"
refuses alias_of_raw E2S171 \
    "$CASES/alias_of_raw.kofun" lib.raw "$CASES/raw.kofun"
refuses decorative E2S172 \
    "$CASES/decorative.kofun" lib.plain "$CASES/plain.kofun"

# `trusted` is contextual in exactly one position. A function named `trusted`
# in a module that imports ordinarily is an ordinary program, and a resolver
# that lexed the word unconditionally would refuse it.
accepts trusted_is_an_identifier \
    "$CASES/trusted_is_an_identifier.kofun" lib.plain "$CASES/plain.kofun"

# ------------------------------------------------- identity, not the filename

# The same raw module under a different declared path and a different host
# filename is refused identically. If the decision were repaired from a path or
# a filename, renaming the file would change the answer -- and a class a rename
# can change is not a class.
cp "$CASES/raw.kofun" "$WORK/renamed-source.kofun"
sed 's/^module lib\.raw$/module other.name/' "$CASES/raw.kofun" \
    >"$WORK/renamed.kofun"
sed 's/lib\.raw/other.name/' "$CASES/ordinary_of_raw.kofun" \
    >"$WORK/renamed-main.kofun"
refuses renamed E2S171 \
    "$WORK/renamed-main.kofun" other.name "$WORK/renamed.kofun"

# ------------------------------------------------------------------- mutation
#
# Each mutation reintroduces a defect the implementation is the fix for, and
# the gate must refuse it. A gate that only passes is not evidence that it
# bites. The mutant is built as a required step: a mutation that fails to
# compile exits non-zero, and a harness reading "non-zero" as "caught" reports
# the compiler's opinion rather than the resolver's behaviour.

mutation() {
    name=$1
    expression=$2
    label=$3
    code=$4
    main_source=$5
    library_path=$6
    library_source=$7
    sed "$expression" "$ROOT/bootstrap/stage2/imports_qualified.c" \
        >"$WORK/mutant-$name.c"
    cmp -s "$ROOT/bootstrap/stage2/imports_qualified.c" "$WORK/mutant-$name.c" &&
        assert_fail "mutation $name changed nothing; its pattern no longer matches"
    build_tool "$WORK/mutant-$name.c" "$WORK/mutant-$name" \
        >"$WORK/mutant-$name.build.stdout" 2>"$WORK/mutant-$name.build.stderr" ||
        assert_fail "mutation $name does not build; it is testing the compiler rather than the resolver: $(head -1 "$WORK/mutant-$name.build.stderr")"
    write_inventory "$main_source" "$library_path" "$library_source" \
        "$WORK/mutant-$name.inventory"
    rm -f "$WORK/mutant-$name.hir" "$WORK/mutant-$name.c.out"
    "$WORK/mutant-$name" "$WORK/mutant-$name.inventory" \
        "$WORK/mutant-$name.hir" "$WORK/mutant-$name.c.out" \
        >"$WORK/mutant-$name.log" 2>&1 || true
    # The claim is "without this, the refusal does not happen". A mutant that
    # still reports the code has not disabled what it names -- which is the
    # failure a mutation most often has, and the one that leaves a gate looking
    # rigorous while testing nothing.
    if grep -Fq "error[$code]:" "$WORK/mutant-$name.log"; then
        assert_fail "mutation $name still refused $label with $code; it did not disable what it names"
    fi
}

# The decision reads the serialized class. Reading the parsed source fact
# instead agrees in every fixture here, so this mutation must be caught by
# something other than the four cases above -- it is caught because the
# serialized class is what the mutant stops consulting, and the case it breaks
# is the one where the codec is the only witness.
mutation serialized-class \
    's|resolver->modules\[index\].serialized_trust = read_result.interface->module_trust;|resolver->modules[index].serialized_trust = KOFUN_KIF_TRUST_ORDINARY;|' \
    ordinary_of_raw E2S171 \
    "$CASES/ordinary_of_raw.kofun" lib.raw "$CASES/raw.kofun"

# The marker is checked in both directions. Dropping the decorative refusal
# leaves a `trusted` that can be written anywhere without consequence.
mutation decorative-refusal \
    's|binding->trusted) {|false) {|' \
    decorative E2S172 \
    "$CASES/decorative.kofun" lib.plain "$CASES/plain.kofun"

printf '%s\n' \
    'PASS: a raw-foreign module is reachable only through `trusted import`, the marker is refused on an ordinary module, the decision is taken from the serialized trust class and the resolved ModuleId, and no refusal publishes an artifact'

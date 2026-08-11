#!/usr/bin/env sh

set -eu

# Deterministic bounded fuzz over the visibility artifacts: the re-export
# resolver's inventory input, and the KIF sidecar every source-free consumer
# reads.
#
# The focused gates — tests/conformance/modules/re-exports, tests/interfaces,
# tests/typed-sidecar, tests/security — check selected hand-written examples.
# None of them generates input, and none of them stands a case *at* a declared
# budget next to the same case one past it. That gap is what this gate closes:
# every family below has an accepted boundary case and a refused
# over-boundary case, so a budget that silently grew, shrank, or stopped being
# enforced fails here rather than in production.
#
# The budgets are read out of the implementation rather than copied into this
# script. A gate that hard-codes 64 keeps passing after the limit becomes 32 —
# it just stops testing the boundary. Reading `#define` means a changed limit
# regenerates the fixtures, and a *deleted* limit fails immediately.
#
# What every refusal must do, checked for every generated case:
#
#   * exit 1 — not a signal, not a timeout, not 0;
#   * name its diagnostic code on stdout, with stderr empty, because an
#     internal error on stderr is a different failure than a refusal;
#   * leave no HIR, KIF, tooling projection, or JSON dump behind;
#   * disclose no absolute checkout path and no private declaration name;
#   * print the same bytes when run again.
#
# This is a bounded CI smoke budget, in the sense tests/fuzz/README.md gives
# the phrase — not a replacement for coverage-guided fuzzing.

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_VISIBILITY_FUZZ_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}visibility-artifacts"}
CC=${CC:-cc}
# Each case is a single tool invocation over an input this script just wrote.
# The ceiling is a hang detector, not a performance budget: the slowest case
# is the 257-declaration one and it finishes well inside a second.
CASE_TIMEOUT=${KOFUN_VISIBILITY_FUZZ_TIMEOUT:-30}
SIDECAR_MUTANTS=${KOFUN_VISIBILITY_FUZZ_MUTANTS:-24}

ASSERT_CONTEXT='visibility fuzz'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: visibility fuzz: $*" >&2
    exit 1
}

case $WORK in
    */visibility-artifacts|*/visibility-artifacts.*) ;;
    *) fail "work directory must end in visibility-artifacts[.suffix]: $WORK" ;;
esac
command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v timeout >/dev/null 2>&1 || fail 'timeout is required to bound each case'

rm -rf "$WORK"
mkdir -p "$WORK/cases"
kofun_stage2_semantic_common_inputs "$ROOT"

RESOLVER="$WORK/re-exports"
KIF_TOOL="$WORK/kofun-kif-v1"

KOFUN_STAGE2_COMMON_LINK_ID=fuzz-visibility-artifacts/resolver \
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/re_exports.c" \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
    "$KOFUN_STAGE2_COMMON_VISIBILITY_INPUT" \
    "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    -o "$RESOLVER"

KOFUN_STAGE2_COMMON_LINK_ID=fuzz-visibility-artifacts/reader \
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/kif_v1_tool.c" \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
    "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    -o "$KIF_TOOL"

# ------------------------------------------------------------ the budgets
#
# Read from the implementation, so this gate cannot drift away from what it
# claims to bound. `u` suffix optional: the spelling is the implementation's
# to choose, the value is not.
budget() {
    budget_macro=$1
    budget_file=$2
    budget_value=$(
        sed -n "s/^#define $budget_macro  *\([0-9][0-9]*\)u\{0,1\}[[:space:]]*\$/\1/p" \
            "$ROOT/$budget_file"
    )
    if test -z "$budget_value"; then
        fail "$budget_macro is no longer defined in $budget_file; this gate can no longer stand a case at its boundary"
    fi
    printf '%s\n' "$budget_value"
}

CHAIN_LIMIT=$(budget RE_EXPORT_CHAIN_LIMIT bootstrap/stage2/re_exports.c)
DECLARATION_LIMIT=$(budget RE_EXPORT_DECLARATIONS_PER_MODULE_LIMIT \
    bootstrap/stage2/re_exports.c)

assert_num "RE_EXPORT_CHAIN_LIMIT" "$CHAIN_LIMIT" -gt 1
assert_num "RE_EXPORT_DECLARATIONS_PER_MODULE_LIMIT" "$DECLARATION_LIMIT" -gt 1

# The package identity is shared by every generated module: these families are
# about visibility artifacts, not about cross-package access, which
# tests/interfaces/visibility-filtering.sh already pins.
PACKAGE_ID=1111111111111111111111111111111111111111111111111111111111111111

# Private spellings that appear in generated sources and must never reach a
# published artifact or a diagnostic.
PRIVATE_SPELLINGS='hidden_detail|SecretPayload|Concealed'

cases_run=0
refusals_checked=0

# identity N — a distinct canonical 32-byte identity per generated module.
identity() {
    printf '%064x\n' "$1"
}

# ------------------------------------------------------------ generators
#
# Every generated module carries a private declaration alongside its public
# one, so the non-disclosure assertions have something real to catch.

write_base() {
    write_base_path=$1
    write_base_module=$2
    {
        printf 'module %s\n\n' "$write_base_module"
        printf 'pub fn Item(value: Int) -> Int {\n    return value\n}\n\n'
        printf 'private fn hidden_detail(value: Int) -> Int {\n    return value\n}\n\n'
        printf 'private type SecretPayload =\n    | Concealed\n    | Revealed(value: Int)\n'
    } >"$write_base_path"
}

# generate_chain DEPTH DIRECTORY [SOURCE-PREFIX] [ORDER]
#
# A base module plus DEPTH forwarding facades, each re-exporting the one below
# it. DEPTH forwarding edges is exactly DEPTH chain edges.
#
# SOURCE-PREFIX and ORDER exist for the path/order-independence claim below:
# they change the file names on disk and the order of the inventory lines
# without changing a single logical path, module identity, or byte of source.
generate_chain() {
    chain_depth=$1
    chain_dir=$2
    chain_prefix=${3:-lvl}
    chain_order=${4:-forward}

    rm -rf "$chain_dir"
    mkdir -p "$chain_dir/src"
    write_base "$chain_dir/src/${chain_prefix}base.kofun" chain.base
    printf '%s|%s|%s|chain.base|chain/base.kofun|%s\n' \
        "$PACKAGE_ID" "$(identity 1)" "$(identity 2)" \
        "$chain_dir/src/${chain_prefix}base.kofun" >"$chain_dir/lines"

    chain_previous=chain.base
    chain_index=1
    while test "$chain_index" -le "$chain_depth"; do
        printf 'module chain.lvl%d\n\npub from %s import Item\n' \
            "$chain_index" "$chain_previous" \
            >"$chain_dir/src/$chain_prefix$chain_index.kofun"
        printf '%s|%s|%s|chain.lvl%d|chain/lvl%d.kofun|%s\n' \
            "$PACKAGE_ID" \
            "$(identity $((100 + chain_index)))" \
            "$(identity $((10000 + chain_index)))" \
            "$chain_index" "$chain_index" \
            "$chain_dir/src/$chain_prefix$chain_index.kofun" \
            >>"$chain_dir/lines"
        chain_previous=chain.lvl$chain_index
        chain_index=$((chain_index + 1))
    done

    case $chain_order in
        forward) cp "$chain_dir/lines" "$chain_dir/inventory" ;;
        # Reversed, so a resolver that depended on seeing a module before its
        # dependents would fail rather than quietly agree.
        reversed) sed '1!G;h;$!d' "$chain_dir/lines" >"$chain_dir/inventory" ;;
        *) fail "unknown inventory order: $chain_order" ;;
    esac
    printf '%s\n' "$chain_previous" >"$chain_dir/target"
}

# generate_wide COUNT DIRECTORY — one facade re-exporting COUNT names, which
# is COUNT re-export declarations in a single module.
generate_wide() {
    wide_count=$1
    wide_dir=$2

    rm -rf "$wide_dir"
    mkdir -p "$wide_dir/src"
    {
        printf 'module wide.base\n\n'
        wide_index=0
        while test "$wide_index" -lt "$wide_count"; do
            printf 'pub fn Item%d(value: Int) -> Int {\n    return value\n}\n\n' \
                "$wide_index"
            wide_index=$((wide_index + 1))
        done
        printf 'private fn hidden_detail(value: Int) -> Int {\n    return value\n}\n'
    } >"$wide_dir/src/base.kofun"
    {
        printf 'module wide.facade\n\n'
        wide_index=0
        while test "$wide_index" -lt "$wide_count"; do
            printf 'pub from wide.base import Item%d\n' "$wide_index"
            wide_index=$((wide_index + 1))
        done
    } >"$wide_dir/src/facade.kofun"
    {
        printf '%s|%s|%s|wide.base|wide/base.kofun|%s\n' \
            "$PACKAGE_ID" "$(identity 3)" "$(identity 4)" \
            "$wide_dir/src/base.kofun"
        printf '%s|%s|%s|wide.facade|wide/facade.kofun|%s\n' \
            "$PACKAGE_ID" "$(identity 5)" "$(identity 6)" \
            "$wide_dir/src/facade.kofun"
    } >"$wide_dir/inventory"
    printf '%s\n' wide.facade >"$wide_dir/target"
}

# generate_cycle LENGTH DIRECTORY — LENGTH modules each publicly forwarding
# the next, the last closing back onto the first.
generate_cycle() {
    cycle_length=$1
    cycle_dir=$2

    rm -rf "$cycle_dir"
    mkdir -p "$cycle_dir/src"
    : >"$cycle_dir/inventory"
    cycle_index=0
    while test "$cycle_index" -lt "$cycle_length"; do
        cycle_next=$(((cycle_index + 1) % cycle_length))
        printf 'module cyc.m%d\n\npub from cyc.m%d import Item\n' \
            "$cycle_index" "$cycle_next" >"$cycle_dir/src/m$cycle_index.kofun"
        printf '%s|%s|%s|cyc.m%d|cyc/m%d.kofun|%s\n' \
            "$PACKAGE_ID" \
            "$(identity $((200 + cycle_index)))" \
            "$(identity $((20000 + cycle_index)))" \
            "$cycle_index" "$cycle_index" \
            "$cycle_dir/src/m$cycle_index.kofun" >>"$cycle_dir/inventory"
        cycle_index=$((cycle_index + 1))
    done
    printf '%s\n' cyc.m0 >"$cycle_dir/target"
}

# ------------------------------------------------------------ case runners

# run_case NAME COMMAND... — bounded, with the artifact paths this gate owns.
# Records stdout, stderr, and status; asserts nothing on its own.
run_case() {
    run_name=$1
    shift
    set +e
    timeout "$CASE_TIMEOUT" "$@" \
        >"$WORK/cases/$run_name.stdout" 2>"$WORK/cases/$run_name.stderr"
    run_status=$?
    set -e
    cases_run=$((cases_run + 1))
    case $run_status in
        124|137)
            fail "case $run_name did not finish inside ${CASE_TIMEOUT}s"
            ;;
        0|1) ;;
        *)
            fail "case $run_name exited $run_status, which is neither acceptance nor refusal: $(head -c 512 "$WORK/cases/$run_name.stderr")"
            ;;
    esac
}

# assert_refused NAME CODE ARTIFACT... — the shared contract every generated
# refusal is held to.
assert_refused() {
    refused_name=$1
    refused_code=$2
    shift 2

    assert_num "$refused_name exit status" "$run_status" -eq 1
    assert_grep "$refused_name names $refused_code on stdout" \
        -F "error[$refused_code]" "$WORK/cases/$refused_name.stdout"
    assert_file_empty "$refused_name stderr" "$WORK/cases/$refused_name.stderr"
    for refused_artifact in "$@"; do
        assert_absent "$refused_name left an artifact" "$refused_artifact"
    done
    assert_not_grep "$refused_name disclosed the checkout path" \
        -aF "$ROOT" "$WORK/cases/$refused_name.stdout"
    assert_not_grep "$refused_name disclosed a private spelling" \
        -aE "$PRIVATE_SPELLINGS" "$WORK/cases/$refused_name.stdout"
    refusals_checked=$((refusals_checked + 1))
}

# assert_clean_artifact LABEL PATH — a published artifact discloses neither the
# checkout path nor a private spelling.
assert_clean_artifact() {
    assert_file_nonempty "$1" "$2"
    assert_not_grep "$1 discloses the checkout path" -aF "$ROOT" "$2"
    assert_not_grep "$1 discloses a private spelling" -aE "$PRIVATE_SPELLINGS" "$2"
}

resolve_inventory() {
    resolve_name=$1
    resolve_dir=$2
    run_case "$resolve_name" "$RESOLVER" "$resolve_dir/inventory" \
        "$(cat "$resolve_dir/target")" \
        "$WORK/cases/$resolve_name.hir" \
        "$WORK/cases/$resolve_name.kif" \
        "$WORK/cases/$resolve_name.tooling"
}

refused_inventory() {
    refused_inventory_name=$1
    refused_inventory_dir=$2
    refused_inventory_code=$3
    resolve_inventory "$refused_inventory_name" "$refused_inventory_dir"
    assert_refused "$refused_inventory_name" "$refused_inventory_code" \
        "$WORK/cases/$refused_inventory_name.hir" \
        "$WORK/cases/$refused_inventory_name.kif" \
        "$WORK/cases/$refused_inventory_name.tooling"
    # Determinism: the same refusal, twice, byte for byte. A diagnostic that
    # embedded an address, a timestamp, or an iteration order would differ.
    cp "$WORK/cases/$refused_inventory_name.stdout" \
        "$WORK/cases/$refused_inventory_name.stdout.first"
    resolve_inventory "$refused_inventory_name" "$refused_inventory_dir"
    cmp "$WORK/cases/$refused_inventory_name.stdout.first" \
        "$WORK/cases/$refused_inventory_name.stdout" ||
        assert_fail "$refused_inventory_name is not deterministic across runs"
}

# ------------------------------- family 1: re-export chain depth (a budget)
#
# CHAIN_LIMIT forwarding edges is the deepest accepted facade chain, and one
# more is refused before any artifact is published.
generate_chain "$CHAIN_LIMIT" "$WORK/chain-at"
resolve_inventory chain-at "$WORK/chain-at"
assert_num "chain at $CHAIN_LIMIT edges" "$run_status" -eq 0
assert_clean_artifact "chain-at KIF" "$WORK/cases/chain-at.kif"
assert_clean_artifact "chain-at HIR" "$WORK/cases/chain-at.hir"
assert_grep "chain-at HIR forwards Item" -F '|name=Item|' \
    "$WORK/cases/chain-at.hir"

generate_chain "$((CHAIN_LIMIT + 1))" "$WORK/chain-over"
refused_inventory chain-over "$WORK/chain-over" E2S90
assert_grep "chain-over names the edge budget" \
    -F "$((CHAIN_LIMIT + 1))-edge chain" "$WORK/cases/chain-over.stdout"

# ------------------------- family 2: declarations per module (a budget)
generate_wide "$DECLARATION_LIMIT" "$WORK/wide-at"
resolve_inventory wide-at "$WORK/wide-at"
assert_num "facade at $DECLARATION_LIMIT declarations" "$run_status" -eq 0
assert_clean_artifact "wide-at KIF" "$WORK/cases/wide-at.kif"

generate_wide "$((DECLARATION_LIMIT + 1))" "$WORK/wide-over"
refused_inventory wide-over "$WORK/wide-over" E2S90
assert_grep "wide-over names the declaration budget" \
    -F "exceeds $DECLARATION_LIMIT re-export declarations" \
    "$WORK/cases/wide-over.stdout"

# ------------------------------------------- family 3: malformed identities
#
# The canonical spelling is 64 lowercase hex digits. Every neighbouring
# spelling is malformed, including the ones that look right: an uppercase
# digit still names the same 32 bytes, and accepting it would make one identity
# have two spellings and therefore two digests.
generate_chain 1 "$WORK/identity-ok"
resolve_inventory identity-ok "$WORK/identity-ok"
assert_num "canonical identities accepted" "$run_status" -eq 0

identity_case=0
for malformed in \
    '11111111111111111111111111111111111111111111111111111111111111' \
    '111111111111111111111111111111111111111111111111111111111111111111' \
    'zzzz111111111111111111111111111111111111111111111111111111111111' \
    'AAAA111111111111111111111111111111111111111111111111111111111111' \
    '' \
    ' 111111111111111111111111111111111111111111111111111111111111111'
do
    identity_dir="$WORK/identity-$identity_case"
    generate_chain 1 "$identity_dir"
    # Only the package identity of the first line is rewritten, so every other
    # field stays canonical and the refusal can only be about this one.
    sed "1s|^$PACKAGE_ID|$malformed|" "$identity_dir/inventory" \
        >"$identity_dir/inventory.malformed"
    mv "$identity_dir/inventory.malformed" "$identity_dir/inventory"
    refused_inventory "identity-$identity_case" "$identity_dir" E2S48
    identity_case=$((identity_case + 1))
done

# --------------------------------------------- family 4: cyclic provenance
#
# The acyclic chain above is the accepted side. A cycle of any length is
# refused, and the diagnostic is canonical — rotating which module the
# resolution starts from must not rotate the reported cycle.
for cycle_length in 2 3 5; do
    generate_cycle "$cycle_length" "$WORK/cycle-$cycle_length"
    refused_inventory "cycle-$cycle_length" "$WORK/cycle-$cycle_length" E2S89
    assert_grep "cycle-$cycle_length is reported as a cycle" \
        -F 'canonical re-export cycle' "$WORK/cases/cycle-$cycle_length.stdout"
done

cycle_from_m0=$WORK/cases/cycle-3.stdout
printf '%s\n' cyc.m1 >"$WORK/cycle-3/target"
resolve_inventory cycle-3-rotated "$WORK/cycle-3"
assert_refused cycle-3-rotated E2S89 \
    "$WORK/cases/cycle-3-rotated.hir" \
    "$WORK/cases/cycle-3-rotated.kif" \
    "$WORK/cases/cycle-3-rotated.tooling"
cmp "$cycle_from_m0" "$WORK/cases/cycle-3-rotated.stdout" ||
    assert_fail 'the reported cycle depends on which module resolution started from'

# ------------------------------------- family 5: stale and corrupt sidecars
#
# The accepted chain published a KIF above. Every mutant of it must be refused
# by both readers — the codec tool, which decodes it, and the source-free
# consumer, which resolves against it — with no dump or HIR left behind.
cp "$WORK/cases/chain-at.kif" "$WORK/sidecar.kif"
sidecar_bytes=$(wc -c <"$WORK/sidecar.kif" | tr -d ' ')
assert_num "the published sidecar has bytes to mutate" "$sidecar_bytes" -gt 64

run_case sidecar-ok "$KIF_TOOL" read "$WORK/sidecar.kif" \
    "$WORK/cases/sidecar-ok.json"
assert_num "the unmutated sidecar decodes" "$run_status" -eq 0
assert_clean_artifact "sidecar-ok dump" "$WORK/cases/sidecar-ok.json"

# Stable seed, stable case order: the same mutant set every run, on every
# machine. The generator is the one from tests/fuzz/grammar.sh.
# The default is the seed this corpus was recorded with, so `task verify`
# generates the same programs it always has. It is overridable so a lane
# that runs more than once can explore more than one input set; a fixed
# seed means accumulated machine time buys no coverage.
seed=${KOFUN_VISIBILITY_ARTIFACTS_FUZZ_SEED:-305419896}
case $seed in
    ''|*[!0-9]*)
        printf '%s\n' "visibility-artifacts fuzz: KOFUN_VISIBILITY_ARTIFACTS_FUZZ_SEED must be a non-negative integer" >&2
        exit 2
        ;;
esac
printf '%s\n' "visibility-artifacts fuzz: seed=$seed"
next_random() {
    seed=$(((seed * 1103515245 + 12345) % 2147483648))
}

mutant_index=0
while test "$mutant_index" -lt "$SIDECAR_MUTANTS"; do
    mutant="$WORK/cases/sidecar-$mutant_index.kif"
    next_random
    if test $((mutant_index % 4)) -eq 3; then
        # Truncation: the envelope claims more than the file holds.
        keep=$((seed % (sidecar_bytes - 16) + 8))
        head -c "$keep" "$WORK/sidecar.kif" >"$mutant"
    else
        # Single-byte corruption at a seeded offset.
        offset=$((seed % sidecar_bytes))
        head -c "$offset" "$WORK/sidecar.kif" >"$mutant"
        # `\001` differs from every byte it can replace only if the original
        # was not already `\001`; XOR-ing is not available to `dd`, so the
        # replacement byte is chosen against the original.
        original=$(
            dd if="$WORK/sidecar.kif" bs=1 skip="$offset" count=1 \
                2>/dev/null | od -An -tu1 | tr -d ' \n'
        )
        if test "$original" = "1"; then
            printf '\002' >>"$mutant"
        else
            printf '\001' >>"$mutant"
        fi
        dd if="$WORK/sidecar.kif" bs=1 skip=$((offset + 1)) \
            >>"$mutant" 2>/dev/null
    fi

    if cmp -s "$mutant" "$WORK/sidecar.kif"; then
        fail "sidecar mutant $mutant_index is identical to the original"
    fi

    run_case "sidecar-read-$mutant_index" "$KIF_TOOL" read "$mutant" \
        "$WORK/cases/sidecar-read-$mutant_index.json"
    assert_num "mutant $mutant_index exit status" "$run_status" -eq 1
    assert_absent "mutant $mutant_index left a dump" \
        "$WORK/cases/sidecar-read-$mutant_index.json"
    assert_file_empty "mutant $mutant_index stderr" \
        "$WORK/cases/sidecar-read-$mutant_index.stderr"
    assert_not_grep "mutant $mutant_index disclosed the checkout path" \
        -aF "$ROOT" "$WORK/cases/sidecar-read-$mutant_index.stdout"
    assert_not_grep "mutant $mutant_index disclosed a private spelling" \
        -aE "$PRIVATE_SPELLINGS" "$WORK/cases/sidecar-read-$mutant_index.stdout"
    refusals_checked=$((refusals_checked + 1))

    run_case "sidecar-resolve-$mutant_index" "$RESOLVER" --resolve-kif \
        "$mutant" Item value "$WORK/cases/sidecar-resolve-$mutant_index.hir"
    assert_num "mutant $mutant_index consumer exit status" "$run_status" -eq 1
    assert_absent "mutant $mutant_index left consumer HIR" \
        "$WORK/cases/sidecar-resolve-$mutant_index.hir"
    assert_file_empty "mutant $mutant_index consumer stderr" \
        "$WORK/cases/sidecar-resolve-$mutant_index.stderr"
    assert_not_grep "mutant $mutant_index consumer disclosed a private spelling" \
        -aE "$PRIVATE_SPELLINGS" \
        "$WORK/cases/sidecar-resolve-$mutant_index.stdout"
    refusals_checked=$((refusals_checked + 1))

    mutant_index=$((mutant_index + 1))
done

# Stale, as distinct from corrupt: an intact sidecar that no longer carries
# what the consumer asks for. The bytes decode; the answer is still a refusal,
# and it must not be the corruption one.
run_case sidecar-stale "$RESOLVER" --resolve-kif "$WORK/sidecar.kif" \
    Removed value "$WORK/cases/sidecar-stale.hir"
assert_refused sidecar-stale E2S93 "$WORK/cases/sidecar-stale.hir"
assert_not_grep 'a stale sidecar is not reported as corrupt' \
    -F 'error[E2S91]' "$WORK/cases/sidecar-stale.stdout"

run_case sidecar-stale-namespace "$RESOLVER" --resolve-kif "$WORK/sidecar.kif" \
    Item nosuchnamespace "$WORK/cases/sidecar-stale-namespace.hir"
assert_refused sidecar-stale-namespace E2S93 \
    "$WORK/cases/sidecar-stale-namespace.hir"

# ------------------------- path remap and inventory order do not move bytes
#
# The same logical program, built under a different absolute prefix, from
# differently named source files, with the inventory lines reversed. Every
# published byte must be identical — otherwise the artifacts carry something
# about the machine that produced them.
generate_chain 4 "$WORK/remap-left"
resolve_inventory remap-left "$WORK/remap-left"
assert_num 'the remap baseline resolves' "$run_status" -eq 0

mkdir -p "$WORK/remap-elsewhere/deeper/still-deeper"
generate_chain 4 "$WORK/remap-elsewhere/deeper/still-deeper/right" \
    module_ reversed
resolve_inventory remap-right \
    "$WORK/remap-elsewhere/deeper/still-deeper/right"
assert_num 'the remapped, reordered inventory resolves' "$run_status" -eq 0

cmp "$WORK/cases/remap-left.kif" "$WORK/cases/remap-right.kif" ||
    assert_fail 'the published KIF depends on the checkout path or the inventory order'
cmp "$WORK/cases/remap-left.hir" "$WORK/cases/remap-right.hir" ||
    assert_fail 'the published HIR depends on the checkout path or the inventory order'
cmp "$WORK/cases/remap-left.tooling" "$WORK/cases/remap-right.tooling" ||
    assert_fail 'the tooling projection depends on the checkout path or the inventory order'

# What this gate does not bound, said out loud rather than left to be inferred
# from a green run: KOFUN_KIF_MAX_ENVELOPE (16 MiB) and
# RE_EXPORT_GRAPH_WORK_LIMIT (2e7 steps) are budgets whose boundary case costs
# more to generate than a smoke gate should, so they are checked by neither
# side here.
printf '%s\n' \
    "note: envelope-size and graph-work budgets are out of this gate's runtime budget and remain unbounded here"

assert_num 'generated cases' "$cases_run" -ge 40
assert_num 'refusals held to the shared contract' "$refusals_checked" -ge 40

printf '%s\n' \
    "PASS: chain depth and facade width are accepted at their budget and refused one past it, read from the implementation" \
    "PASS: $identity_case malformed identity spellings, $((SIDECAR_MUTANTS * 2)) sidecar mutants, and 4 provenance cycles are refused" \
    "PASS: $refusals_checked refusals exit 1 on stdout alone, publish nothing, disclose no path or private name, and repeat byte for byte" \
    "PASS: path remapping, source renaming, and inventory reordering leave every published byte unchanged"

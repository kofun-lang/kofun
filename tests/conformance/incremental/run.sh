#!/usr/bin/env sh

# Semantic incremental invalidation gate (#301).
#
# It pins the exact executed/reused semantic module sets and rebuilt/reused
# target artifact sets for all ten edit-matrix rows, the external
# public-interface boundary, and the bounded recovery paths.

set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/incremental"
FIXTURES="$CASES/fixtures"
EDITS="$FIXTURES/edits"
CC=${CC:-cc}
WORK=${KOFUN_INCREMENTAL_WORK:-"$ROOT/build/incremental"}
TOOL="$WORK/kofun-incremental-graph"
KIF_TOOL="$WORK/kofun-kif-v1"

PACKAGE_ID=9999999999999999999999999999999999999999999999999999999999999999
EXTERNAL_PACKAGE=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
# Modules are ordered canonically by raw ModuleId, never by discovery order.
# These identities are chosen so that canonical order reads app, core,
# service, util, which keeps the pinned node sets legible.
APP_MODULE=1111111111111111111111111111111111111111111111111111111111111111
CORE_MODULE=2222222222222222222222222222222222222222222222222222222222222222
SERVICE_MODULE=3333333333333333333333333333333333333333333333333333333333333333
UTIL_MODULE=4444444444444444444444444444444444444444444444444444444444444444
APP_FILE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CORE_FILE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SERVICE_FILE=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
UTIL_FILE=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
# These are upstream-owned target ABI/profile fact digests, not host paths.
TARGET_PROFILE=5555555555555555555555555555555555555555555555555555555555555555
TARGET_PROFILE_CHANGED=6666666666666666666666666666666666666666666666666666666666666666
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

case $WORK in
    */incremental|*/incremental.*) ;;
    *) fail "work directory must end in incremental[.suffix]: $WORK" ;;
esac
command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
rm -rf "$WORK"
mkdir -p "$WORK"
kofun_stage2_semantic_common_inputs "$ROOT"

build_tool() {
    compiler=$1
    output=$2
    input_mode=$3
    shift 3
    case $input_mode in
        common)
            KOFUN_STAGE2_COMMON_LINK_ID=incremental/graph \
                "$compiler" -std=c11 -Wall -Wextra -Werror -pedantic \
                -I"$ROOT/bootstrap/stage2" "$@" \
                "$ROOT/bootstrap/stage2/incremental_graph.c" \
                "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
                "$KOFUN_STAGE2_COMMON_VISIBILITY_INPUT" \
                "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
                "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
                -o "$output"
            ;;
        source)
            "$compiler" -std=c11 -Wall -Wextra -Werror -pedantic \
                -I"$ROOT/bootstrap/stage2" "$@" \
                "$ROOT/bootstrap/stage2/incremental_graph.c" \
                "$ROOT/bootstrap/stage2/kif_v1.c" \
                "$ROOT/bootstrap/stage2/visibility_access.c" \
                "$ROOT/unicode/kofun_unicode.c" \
                "$ROOT/bootstrap/stage2/sha256.c" \
                -o "$output"
            ;;
        *) fail "unknown incremental tool input mode: $input_mode" ;;
    esac
}

build_tool "$CC" "$TOOL" common -O2
KOFUN_STAGE2_COMMON_LINK_ID=incremental/reader \
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/kif_v1_tool.c" \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
    "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    -o "$KIF_TOOL"

# ------------------------------------------------------------------ helpers

# POSIX shell functions share one variable namespace, so every helper here
# prefixes its parameters rather than reusing a caller's names.

run_graph() {
    rg_tool=$1
    rg_inventory=$2
    rg_cache=$3
    rg_report=$4
    rg_profile=${5:-$TARGET_PROFILE}
    rg_cancel=${6:-}
    if [ -n "$rg_cancel" ]; then
        "$rg_tool" "$rg_inventory" "$rg_cache" "$rg_report" "$rg_profile" \
            "$rg_cancel"
    else
        "$rg_tool" "$rg_inventory" "$rg_cache" "$rg_report" "$rg_profile"
    fi
}

# Inventory rows are emitted in a deliberately non-alphabetical order so the
# resolver's canonical ordering, not discovery order, decides the result.
write_inventory() {
    wi_output=$1
    wi_core=$2
    wi_service=$3
    wi_app=$4
    wi_util=$5
    {
        printf '%s|%s|%s|demo.service|demo/service.kofun|%s\n' \
            "$PACKAGE_ID" "$SERVICE_MODULE" "$SERVICE_FILE" "$wi_service"
        printf '%s|%s|%s|demo.app|demo/app.kofun|%s\n' \
            "$PACKAGE_ID" "$APP_MODULE" "$APP_FILE" "$wi_app"
        printf '%s|%s|%s|demo.util|demo/util.kofun|%s\n' \
            "$PACKAGE_ID" "$UTIL_MODULE" "$UTIL_FILE" "$wi_util"
        printf '%s|%s|%s|demo.core|demo/core.kofun|%s\n' \
            "$PACKAGE_ID" "$CORE_MODULE" "$CORE_FILE" "$wi_core"
    } >"$wi_output"
}

write_base_inventory() {
    write_inventory "$1" "$FIXTURES/core.kofun" "$FIXTURES/service.kofun" \
        "$FIXTURES/app.kofun" "$FIXTURES/util.kofun"
}

# The exact executed/reused node set, in canonical module order.
# Report records put their fixed fields first and end with the logical path,
# which may legitimately contain a space. Every extractor therefore rebuilds
# the path from the remainder of the record instead of reading one field.
outcome_set() {
    awk '$1 == "module" {
        path = $4
        for (i = 5; i <= NF; i += 1) path = path " " $i
        printf "%s=%s ", path, $2
    }' "$1"
}

expect_set() {
    es_actual=$(outcome_set "$1")
    [ "$es_actual" = "$2" ] ||
        fail "$3: expected node set [$2], got [$es_actual]"
}

expect_reason() {
    er_actual=$(awk '$1 == "module" {
        path = $4
        for (i = 5; i <= NF; i += 1) path = path " " $i
        if (path == p) print $3
    }' p="$2" "$1")
    [ "$er_actual" = "$3" ] ||
        fail "$4: $2 expected reason $3, got ${er_actual:-none}"
}

expect_summary() {
    esm_actual=$(awk '$1 == "summary" { print $2, $3 }' "$1")
    [ "$esm_actual" = "$2" ] ||
        fail "$3: expected summary [$2], got [$esm_actual]"
}

expect_artifact_summary() {
    eas_actual=$(awk '$1 == "artifact-summary" { print $2, $3 }' "$1")
    [ "$eas_actual" = "$2" ] ||
        fail "$3: expected artifact summary [$2], got [$eas_actual]"
}

artifact_executed_bytes() {
    awk '$1 == "artifact-summary" {
        sub(/^executed-bytes=/, "", $2)
        print $2
    }' "$1"
}

artifact_reused_bytes() {
    awk '$1 == "artifact-summary" {
        sub(/^reused-bytes=/, "", $3)
        print $3
    }' "$1"
}

target_outcome_set() {
    awk '$1 == "target" {
        path = $4
        for (i = 5; i <= NF; i += 1) path = path " " $i
        printf "%s=%s ", path, $2
    }' "$1"
}

expect_target_set() {
    ets_actual=$(target_outcome_set "$1")
    [ "$ets_actual" = "$2" ] ||
        fail "$3: expected target set [$2], got [$ets_actual]"
}

expect_target_reason() {
    etr_actual=$(awk '$1 == "target" {
        path = $4
        for (i = 5; i <= NF; i += 1) path = path " " $i
        if (path == p) print $3
    }' p="$2" "$1")
    [ "$etr_actual" = "$3" ] ||
        fail "$4: $2 expected target reason $3, got ${etr_actual:-none}"
}

expect_target_summary() {
    ets_actual=$(awk '$1 == "target-summary" { print $2, $3 }' "$1")
    [ "$ets_actual" = "$2" ] ||
        fail "$3: expected target summary [$2], got [$ets_actual]"
}

public_digest() {
    awk '$1 == "public" {
        path = $3
        for (i = 4; i <= NF; i += 1) path = path " " $i
        if (path == p) print $2
    }' p="$2" "$1"
}

# Run one edit-matrix row against a warm cache seeded from the base package.
run_row() {
    rr_label=$1
    rr_core=$2
    rr_service=$3
    rr_app=$4
    rm -rf "$WORK/cache-$rr_label"
    write_base_inventory "$WORK/$rr_label-base.inventory"
    run_graph "$TOOL" "$WORK/$rr_label-base.inventory" "$WORK/cache-$rr_label" \
        "$WORK/$rr_label-cold.report" >/dev/null ||
        fail "$rr_label: cold run failed"
    write_inventory "$WORK/$rr_label-edit.inventory" "$rr_core" "$rr_service" \
        "$rr_app" "$FIXTURES/util.kofun"
    run_graph "$TOOL" "$WORK/$rr_label-edit.inventory" "$WORK/cache-$rr_label" \
        "$WORK/$rr_label.report" >/dev/null ||
        fail "$rr_label: edited run failed"
}

ALL_EXECUTED='demo/app.kofun=executed demo/core.kofun=executed demo/service.kofun=executed demo/util.kofun=executed '
ALL_REUSED='demo/app.kofun=reused demo/core.kofun=reused demo/service.kofun=reused demo/util.kofun=reused '
ALL_TARGET_REBUILT='demo/app.kofun=rebuilt demo/core.kofun=rebuilt demo/service.kofun=rebuilt demo/util.kofun=rebuilt '
ALL_TARGET_REUSED='demo/app.kofun=reused demo/core.kofun=reused demo/service.kofun=reused demo/util.kofun=reused '

# ------------------------------------------------- cold and warm base state

write_base_inventory "$WORK/base.inventory"
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache" "$WORK/cold.report" >/dev/null ||
    fail 'cold run failed'
expect_set "$WORK/cold.report" "$ALL_EXECUTED" 'cold cache'
expect_summary "$WORK/cold.report" 'executed=4 reused=0' 'cold cache'
expect_reason "$WORK/cold.report" demo/core.kofun cold-cache 'cold cache'
expect_target_set "$WORK/cold.report" "$ALL_TARGET_REBUILT" 'cold cache'
expect_target_summary "$WORK/cold.report" 'rebuilt=4 reused=0' 'cold cache'
COLD_ARTIFACT_BYTES=$(artifact_executed_bytes "$WORK/cold.report")
case $COLD_ARTIFACT_BYTES in
    ''|*[!0-9]*) fail "cold cache reported invalid artifact bytes: $COLD_ARTIFACT_BYTES" ;;
esac
[ "$COLD_ARTIFACT_BYTES" -gt 0 ] || fail 'cold cache reported zero artifact bytes'
expect_artifact_summary "$WORK/cold.report" \
    "executed-bytes=$COLD_ARTIFACT_BYTES reused-bytes=0" 'cold cache'
grep -q '^cache cold$' "$WORK/cold.report" || fail 'cold run did not report a cold cache'
grep -q '^schema kofun-incremental-report/v3$' "$WORK/cold.report" ||
    fail 'cold run did not report the artifact-byte schema'
test -f "$WORK/cache/manifest" || fail 'cold run committed no manifest'
test -f "$WORK/cache/m-$CORE_MODULE.kif" || fail 'cold run published no core interface'

run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache" "$WORK/warm.report" >/dev/null ||
    fail 'warm run failed'
expect_set "$WORK/warm.report" "$ALL_REUSED" 'warm no-op'
expect_summary "$WORK/warm.report" 'executed=0 reused=4' 'warm no-op'
expect_target_set "$WORK/warm.report" "$ALL_TARGET_REUSED" 'warm no-op'
expect_target_summary "$WORK/warm.report" 'rebuilt=0 reused=4' 'warm no-op'
WARM_ARTIFACT_BYTES=$(artifact_reused_bytes "$WORK/warm.report")
[ "$WARM_ARTIFACT_BYTES" = "$COLD_ARTIFACT_BYTES" ] ||
    fail "warm reused bytes $WARM_ARTIFACT_BYTES differ from cold executed bytes $COLD_ARTIFACT_BYTES"
expect_artifact_summary "$WORK/warm.report" \
    "executed-bytes=0 reused-bytes=$COLD_ARTIFACT_BYTES" 'warm no-op'

# A repeated no-op is byte-identical: the graph is a fixed point, and the
# manifest is not rewritten with different content.
cp "$WORK/cache/manifest" "$WORK/manifest.first"
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache" "$WORK/warm-repeat.report" >/dev/null ||
    fail 'repeated warm run failed'
cmp "$WORK/warm.report" "$WORK/warm-repeat.report" ||
    fail 'repeated warm run produced a different report'
cmp "$WORK/manifest.first" "$WORK/cache/manifest" ||
    fail 'repeated warm run rewrote the manifest'

# Discovery order is not semantic: a reordered inventory reproduces the graph.
{
    printf '%s|%s|%s|demo.core|demo/core.kofun|%s\n' \
        "$PACKAGE_ID" "$CORE_MODULE" "$CORE_FILE" "$FIXTURES/core.kofun"
    printf '%s|%s|%s|demo.util|demo/util.kofun|%s\n' \
        "$PACKAGE_ID" "$UTIL_MODULE" "$UTIL_FILE" "$FIXTURES/util.kofun"
    printf '%s|%s|%s|demo.service|demo/service.kofun|%s\n' \
        "$PACKAGE_ID" "$SERVICE_MODULE" "$SERVICE_FILE" "$FIXTURES/service.kofun"
    printf '%s|%s|%s|demo.app|demo/app.kofun|%s\n' \
        "$PACKAGE_ID" "$APP_MODULE" "$APP_FILE" "$FIXTURES/app.kofun"
} >"$WORK/reordered.inventory"
rm -rf "$WORK/cache-order"
run_graph "$TOOL" "$WORK/reordered.inventory" "$WORK/cache-order" \
    "$WORK/reordered.report" >/dev/null || fail 'reordered inventory run failed'
cmp "$WORK/cache/manifest" "$WORK/cache-order/manifest" ||
    fail 'inventory discovery order changed the persisted graph'

# A logical path is inventory data, not a shell word: one containing a space
# must survive the manifest round trip intact and still be reused.
{
    printf '%s|%s|%s|demo.core|demo/spaced core.kofun|%s\n' \
        "$PACKAGE_ID" "$CORE_MODULE" "$CORE_FILE" "$FIXTURES/core.kofun"
    printf '%s|%s|%s|demo.util|demo/util.kofun|%s\n' \
        "$PACKAGE_ID" "$UTIL_MODULE" "$UTIL_FILE" "$FIXTURES/util.kofun"
} >"$WORK/spaced.inventory"
rm -rf "$WORK/cache-spaced"
run_graph "$TOOL" "$WORK/spaced.inventory" "$WORK/cache-spaced" \
    "$WORK/spaced-cold.report" >/dev/null || fail 'spaced logical path run failed'
run_graph "$TOOL" "$WORK/spaced.inventory" "$WORK/cache-spaced" \
    "$WORK/spaced-warm.report" >/dev/null ||
    fail 'spaced logical path warm run failed'
expect_set "$WORK/spaced-warm.report" \
    'demo/spaced core.kofun=reused demo/util.kofun=reused ' \
    'logical path containing a space'

# ------------------------------------------------------- required edit matrix

# Row 1: comment and formatting edit. Parse runs; every semantic dependent is
# reused because no interface digest moves.
run_row row1 "$EDITS/core_comment.kofun" "$FIXTURES/service.kofun" \
    "$FIXTURES/app.kofun"
expect_set "$WORK/row1.report" \
    'demo/app.kofun=reused demo/core.kofun=executed demo/service.kofun=reused demo/util.kofun=reused ' \
    'row 1 comment/format edit'
expect_reason "$WORK/row1.report" demo/core.kofun source-changed 'row 1'

# Row 2: private body edit. core is rechecked; service, app, and util are reused.
run_row row2 "$EDITS/core_private_body.kofun" "$FIXTURES/service.kofun" \
    "$FIXTURES/app.kofun"
expect_set "$WORK/row2.report" \
    'demo/app.kofun=reused demo/core.kofun=executed demo/service.kofun=reused demo/util.kofun=reused ' \
    'row 2 private body edit'
expect_summary "$WORK/row2.report" 'executed=1 reused=3' 'row 2'

# Row 3: internal signature edit. The same-package consumer with a matching
# edge is invalidated; the unrelated module and the external public view are not.
run_row row3 "$EDITS/core_internal_signature.kofun" "$FIXTURES/service.kofun" \
    "$FIXTURES/app.kofun"
expect_set "$WORK/row3.report" \
    'demo/app.kofun=reused demo/core.kofun=executed demo/service.kofun=executed demo/util.kofun=reused ' \
    'row 3 internal signature edit'
expect_reason "$WORK/row3.report" demo/service.kofun internal-digest-changed 'row 3'
[ "$(public_digest "$WORK/row3-cold.report" demo/core.kofun)" = \
  "$(public_digest "$WORK/row3.report" demo/core.kofun)" ] ||
    fail 'row 3: an internal edit moved the public interface digest'

# Row 4: public signature edit. The public digest moves, so every consumer of
# the public view is invalidated.
run_row row4 "$EDITS/core_public_signature.kofun" "$FIXTURES/service.kofun" \
    "$FIXTURES/app.kofun"
expect_set "$WORK/row4.report" \
    'demo/app.kofun=reused demo/core.kofun=executed demo/service.kofun=executed demo/util.kofun=reused ' \
    'row 4 public signature edit'
expect_reason "$WORK/row4.report" demo/service.kofun public-digest-changed 'row 4'
[ "$(public_digest "$WORK/row4-cold.report" demo/core.kofun)" != \
  "$(public_digest "$WORK/row4.report" demo/core.kofun)" ] ||
    fail 'row 4: a public signature edit left the public digest unchanged'

# Row 4b: the same public edit, propagated. When the intermediate module's own
# public interface also moves, invalidation continues to its consumers. This is
# the transitive half of rows 3 and 4: propagation stops at an unchanged
# interface, and continues through a changed one.
run_row row4b "$EDITS/core_public_signature.kofun" \
    "$EDITS/service_forwards_scale.kofun" "$FIXTURES/app.kofun"
expect_set "$WORK/row4b.report" \
    'demo/app.kofun=executed demo/core.kofun=executed demo/service.kofun=executed demo/util.kofun=reused ' \
    'row 4b transitive public change'
expect_reason "$WORK/row4b.report" demo/app.kofun public-digest-changed 'row 4b'
grep -q '^cause demo.service demo/app.kofun$' "$WORK/row4b.report" ||
    fail 'row 4b: app does not record demo.service as its invalidation cause'

# Row 5: an unused private declaration is added. No interface digest moves.
run_row row5 "$EDITS/core_unused_private.kofun" "$FIXTURES/service.kofun" \
    "$FIXTURES/app.kofun"
expect_set "$WORK/row5.report" \
    'demo/app.kofun=reused demo/core.kofun=executed demo/service.kofun=reused demo/util.kofun=reused ' \
    'row 5 unused private declaration'

# Row 6: a selected import is removed. Only the importer is invalidated; its
# own interface is unchanged, so nothing downstream follows.
run_row row6 "$FIXTURES/core.kofun" "$FIXTURES/service.kofun" \
    "$EDITS/app_selected_import_removed.kofun"
expect_set "$WORK/row6.report" \
    'demo/app.kofun=executed demo/core.kofun=reused demo/service.kofun=reused demo/util.kofun=reused ' \
    'row 6 selected import removal'
expect_summary "$WORK/row6.report" 'executed=1 reused=3' 'row 6'

# Row 7: a re-export is removed. The facade's public interface changes, so its
# consumers are invalidated even though the canonical target is untouched.
run_row row7 "$FIXTURES/core.kofun" "$EDITS/service_reexport_removed.kofun" \
    "$FIXTURES/app.kofun"
expect_set "$WORK/row7.report" \
    'demo/app.kofun=executed demo/core.kofun=reused demo/service.kofun=executed demo/util.kofun=reused ' \
    'row 7 re-export removal'
expect_reason "$WORK/row7.report" demo/app.kofun public-digest-changed 'row 7'
[ "$(public_digest "$WORK/row7-cold.report" demo/core.kofun)" = \
  "$(public_digest "$WORK/row7.report" demo/core.kofun)" ] ||
    fail 'row 7: removing a facade edge moved the canonical target digest'

# Row 8: the upstream target ABI/profile facts move while source and semantic
# interfaces remain byte-identical. Semantic nodes are reused, but every target
# artifact action is conservatively rebuilt under the new profile key.
rm -rf "$WORK/cache-row8"
cp -R "$WORK/cache" "$WORK/cache-row8"
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-row8" \
    "$WORK/row8.report" "$TARGET_PROFILE_CHANGED" >/dev/null ||
    fail 'row 8 target-profile run failed'
expect_set "$WORK/row8.report" "$ALL_REUSED" 'row 8 target profile change'
expect_target_set "$WORK/row8.report" "$ALL_TARGET_REBUILT" \
    'row 8 target profile change'
expect_target_reason "$WORK/row8.report" demo/core.kofun \
    target-profile-changed 'row 8'
expect_target_summary "$WORK/row8.report" 'rebuilt=4 reused=0' 'row 8'
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-row8" \
    "$WORK/row8-warm.report" "$TARGET_PROFILE_CHANGED" >/dev/null ||
    fail 'row 8 warm target-profile run failed'
expect_set "$WORK/row8-warm.report" "$ALL_REUSED" 'row 8 warm profile'
expect_target_set "$WORK/row8-warm.report" "$ALL_TARGET_REUSED" \
    'row 8 warm profile'

# ------------------------------------------------ external consumer boundary

# The external boundary is the public view. An internal edit leaves a
# source-free external consumer resolvable and byte-identical; a public
# signature edit rejects it. Cross-package source imports do not exist yet, so
# this is proved through the published interface, which is the real boundary.
resolve_external() {
    kif=$1
    output=$2
    "$KIF_TOOL" resolve "$kif" "$EXTERNAL_PACKAGE" demo.core \
        "$FIXTURES/external_consumer.kofun" "$output"
}

resolve_external "$WORK/cache/m-$CORE_MODULE.kif" "$WORK/external-base.hir" ||
    fail 'external consumer could not resolve the baseline public interface'
resolve_external "$WORK/cache-row3/m-$CORE_MODULE.kif" \
    "$WORK/external-row3.hir" ||
    fail 'row 3: external consumer lost resolution after an internal-only edit'
cmp "$WORK/external-base.hir" "$WORK/external-row3.hir" ||
    fail 'row 3: an internal-only edit changed the external resolution'

rm -f "$WORK/external-row4.hir"
if resolve_external "$WORK/cache-row4/m-$CORE_MODULE.kif" \
    "$WORK/external-row4.hir" >/dev/null 2>&1
then
    fail 'row 4: external consumer still resolved after a public signature edit'
fi
test ! -e "$WORK/external-row4.hir" ||
    fail 'row 4: rejected external resolution still published HIR'

# ------------------------------------------- bounded recovery and safety

# An unknown schema version is a bounded cache miss, never a trusted read.
rm -rf "$WORK/cache-schema"
cp -R "$WORK/cache" "$WORK/cache-schema"
sed 's|^schema kofun-incremental-graph/v2$|schema kofun-incremental-graph/v99|' \
    "$WORK/cache/manifest" >"$WORK/cache-schema/manifest"
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-schema" \
    "$WORK/schema.report" >/dev/null || fail 'unknown schema version was fatal'
expect_set "$WORK/schema.report" "$ALL_EXECUTED" 'unknown schema version'
grep -q '^cache miss$' "$WORK/schema.report" ||
    fail 'unknown schema version was not reported as a cache miss'
expect_reason "$WORK/schema.report" demo/core.kofun \
    manifest-unknown-schema 'unknown schema version'

# A manifest beyond its declared byte budget is never parsed or trusted.
rm -rf "$WORK/cache-oversized-manifest"
cp -R "$WORK/cache" "$WORK/cache-oversized-manifest"
dd if=/dev/zero bs=1048576 count=5 2>/dev/null >> \
    "$WORK/cache-oversized-manifest/manifest"
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-oversized-manifest" \
    "$WORK/oversized-manifest.report" >/dev/null ||
    fail 'an oversized manifest was fatal'
expect_set "$WORK/oversized-manifest.report" "$ALL_EXECUTED" \
    'oversized manifest'
expect_reason "$WORK/oversized-manifest.report" demo/core.kofun \
    manifest-unreadable-or-oversized 'oversized manifest'

# A truncated or garbled manifest is likewise a bounded miss.
for mutation in 'module not-hex' 'unknown-record 1' 'schema'
do
    rm -rf "$WORK/cache-mutated"
    cp -R "$WORK/cache" "$WORK/cache-mutated"
    printf '%s\n' "$mutation" >>"$WORK/cache-mutated/manifest"
    run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-mutated" \
        "$WORK/mutated.report" >/dev/null ||
        fail "mutated manifest was fatal: $mutation"
    expect_set "$WORK/mutated.report" "$ALL_EXECUTED" \
        "mutated manifest: $mutation"
    grep -q '^cache miss$' "$WORK/mutated.report" ||
        fail "mutated manifest was trusted: $mutation"
done

# A manifest naming another package is never applied to this one.
rm -rf "$WORK/cache-package"
cp -R "$WORK/cache" "$WORK/cache-package"
sed "s|^package $PACKAGE_ID\$|package $EXTERNAL_PACKAGE|" \
    "$WORK/cache/manifest" >"$WORK/cache-package/manifest"
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-package" \
    "$WORK/package.report" >/dev/null || fail 'package mismatch was fatal'
expect_reason "$WORK/package.report" demo/core.kofun \
    manifest-package-mismatch 'package mismatch'

# A mutated interface blob demotes exactly its own module, not the whole cache.
rm -rf "$WORK/cache-blob"
cp -R "$WORK/cache" "$WORK/cache-blob"
printf 'corruption' >>"$WORK/cache-blob/m-$CORE_MODULE.kif"
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-blob" \
    "$WORK/blob.report" >/dev/null || fail 'a corrupt interface blob was fatal'
expect_reason "$WORK/blob.report" demo/core.kofun \
    cached-interface-unusable 'corrupt interface blob'
expect_set "$WORK/blob.report" \
    'demo/app.kofun=reused demo/core.kofun=executed demo/service.kofun=reused demo/util.kofun=reused ' \
    'corrupt interface blob'

# The KIF envelope byte budget is enforced before hashing or reuse.
rm -rf "$WORK/cache-oversized-blob"
cp -R "$WORK/cache" "$WORK/cache-oversized-blob"
dd if=/dev/zero bs=1048576 count=17 2>/dev/null >> \
    "$WORK/cache-oversized-blob/m-$CORE_MODULE.kif"
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-oversized-blob" \
    "$WORK/oversized-blob.report" >/dev/null ||
    fail 'an oversized interface blob was fatal'
expect_reason "$WORK/oversized-blob.report" demo/core.kofun \
    cached-interface-unusable 'oversized interface blob'
expect_set "$WORK/oversized-blob.report" \
    'demo/app.kofun=reused demo/core.kofun=executed demo/service.kofun=reused demo/util.kofun=reused ' \
    'oversized interface blob'

# A removed interface blob is the same bounded miss.
rm -rf "$WORK/cache-missing"
cp -R "$WORK/cache" "$WORK/cache-missing"
rm -f "$WORK/cache-missing/m-$UTIL_MODULE.kif"
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-missing" \
    "$WORK/missing.report" >/dev/null || fail 'a missing interface blob was fatal'
expect_reason "$WORK/missing.report" demo/util.kofun \
    cached-interface-unusable 'missing interface blob'

# Recovery is complete: the repaired cache is warm and fully reused again.
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-blob" \
    "$WORK/blob-recovered.report" >/dev/null || fail 'recovery run failed'
expect_set "$WORK/blob-recovered.report" "$ALL_REUSED" 'recovered cache'

# A rejected edit never replaces the last committed reusable success.
rm -rf "$WORK/cache-invalid"
cp -R "$WORK/cache" "$WORK/cache-invalid"
cp "$WORK/cache-invalid/manifest" "$WORK/manifest.before-failure"
write_inventory "$WORK/invalid.inventory" "$EDITS/core_top_level_comment.kofun" \
    "$FIXTURES/service.kofun" "$FIXTURES/app.kofun" "$FIXTURES/util.kofun"
rm -f "$WORK/invalid.report"
if run_graph "$TOOL" "$WORK/invalid.inventory" "$WORK/cache-invalid" \
    "$WORK/invalid.report" >"$WORK/invalid.out" 2>&1
then
    fail 'a rejected source was accepted'
fi
grep -q '^error\[' "$WORK/invalid.out" ||
    fail 'a rejected source produced no diagnostic'
test ! -e "$WORK/invalid.report" ||
    fail 'a rejected source published a report'
cmp "$WORK/manifest.before-failure" "$WORK/cache-invalid/manifest" ||
    fail 'a rejected source mutated the committed graph'

# The last committed success survives the failure and remains reusable.
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-invalid" \
    "$WORK/after-failure.report" >/dev/null || fail 'post-failure run failed'
expect_set "$WORK/after-failure.report" "$ALL_REUSED" 'cache after a failure'
expect_target_set "$WORK/after-failure.report" "$ALL_TARGET_REUSED" \
    'preserved cache after a failure'

# Deterministic cancellation occurs after real semantic work but before the
# manifest/report transaction. The orphaned cold KIF has no graph reference,
# so repair executes the complete package and only its successor may reuse it.
rm -rf "$WORK/cache-cancelled"
rm -f "$WORK/cancelled.report"
if run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-cancelled" \
    "$WORK/cancelled.report" "$TARGET_PROFILE" 1 \
    >"$WORK/cancelled.out" 2>&1
then
    fail 'a cancelled incremental computation returned success'
fi
grep -q 'incremental computation cancelled after 1 executed module' \
    "$WORK/cancelled.out" || fail 'cancellation produced no bounded note'
test ! -e "$WORK/cancelled.report" ||
    fail 'a cancelled computation published a report'
test ! -e "$WORK/cache-cancelled/manifest" ||
    fail 'a cancelled computation published a reusable graph'
find "$WORK/cache-cancelled" -name 'm-*.kif' -print | grep -q . ||
    fail 'cancellation did not occur after semantic artifact work'
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-cancelled" \
    "$WORK/cancelled-repair.report" >/dev/null ||
    fail 'cancelled computation repair failed'
expect_set "$WORK/cancelled-repair.report" "$ALL_EXECUTED" \
    'cancelled computation repair'
expect_summary "$WORK/cancelled-repair.report" 'executed=4 reused=0' \
    'cancelled computation repair'
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-cancelled" \
    "$WORK/cancelled-warm.report" >/dev/null ||
    fail 'cancelled computation repaired warm run failed'
expect_set "$WORK/cancelled-warm.report" "$ALL_REUSED" \
    'cancelled computation repaired warm run'

# Row 9: a cold rejected compile publishes no reusable graph. Repairing the
# source therefore executes every semantic and target node once; only the next
# successful warm run may reuse those products.
rm -rf "$WORK/cache-row9"
rm -f "$WORK/row9-failed.report"
if run_graph "$TOOL" "$WORK/invalid.inventory" "$WORK/cache-row9" \
    "$WORK/row9-failed.report" >"$WORK/row9-failed.out" 2>&1
then
    fail 'row 9: a cold rejected source was accepted'
fi
grep -q '^error\[' "$WORK/row9-failed.out" ||
    fail 'row 9: a cold rejected source produced no diagnostic'
test ! -e "$WORK/row9-failed.report" ||
    fail 'row 9: a cold failure published a report'
test ! -e "$WORK/cache-row9/manifest" ||
    fail 'row 9: a cold failure published a reusable graph'
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-row9" \
    "$WORK/row9-repaired.report" >/dev/null ||
    fail 'row 9: repaired compile failed'
expect_set "$WORK/row9-repaired.report" "$ALL_EXECUTED" 'row 9 repair'
expect_summary "$WORK/row9-repaired.report" 'executed=4 reused=0' 'row 9 repair'
expect_target_set "$WORK/row9-repaired.report" "$ALL_TARGET_REBUILT" \
    'row 9 repair'
expect_target_summary "$WORK/row9-repaired.report" 'rebuilt=4 reused=0' \
    'row 9 repair'
run_graph "$TOOL" "$WORK/base.inventory" "$WORK/cache-row9" \
    "$WORK/row9-warm.report" >/dev/null ||
    fail 'row 9: repaired warm compile failed'
expect_set "$WORK/row9-warm.report" "$ALL_REUSED" 'row 9 repaired warm run'
expect_target_set "$WORK/row9-warm.report" "$ALL_TARGET_REUSED" \
    'row 9 repaired warm run'

# Row 10: clean copies rooted at different physical directories produce the
# same logical semantic graph IDs and target action decisions. Physical source
# roots and cache roots are never serialized into the manifest or report.
mkdir "$WORK/remap-a" "$WORK/remap-b"
cp "$FIXTURES/core.kofun" "$FIXTURES/service.kofun" \
    "$FIXTURES/app.kofun" "$FIXTURES/util.kofun" "$WORK/remap-a/"
cp "$FIXTURES/core.kofun" "$FIXTURES/service.kofun" \
    "$FIXTURES/app.kofun" "$FIXTURES/util.kofun" "$WORK/remap-b/"
write_inventory "$WORK/remap-a.inventory" "$WORK/remap-a/core.kofun" \
    "$WORK/remap-a/service.kofun" "$WORK/remap-a/app.kofun" \
    "$WORK/remap-a/util.kofun"
write_inventory "$WORK/remap-b.inventory" "$WORK/remap-b/core.kofun" \
    "$WORK/remap-b/service.kofun" "$WORK/remap-b/app.kofun" \
    "$WORK/remap-b/util.kofun"
run_graph "$TOOL" "$WORK/remap-a.inventory" "$WORK/cache-remap-a" \
    "$WORK/remap-a.report" >/dev/null || fail 'row 10 remap A failed'
run_graph "$TOOL" "$WORK/remap-b.inventory" "$WORK/cache-remap-b" \
    "$WORK/remap-b.report" >/dev/null || fail 'row 10 remap B failed'
cmp "$WORK/cache-remap-a/manifest" "$WORK/cache-remap-b/manifest" ||
    fail 'row 10: physical source root changed semantic graph IDs'
cmp "$WORK/remap-a.report" "$WORK/remap-b.report" ||
    fail 'row 10: physical source root changed incremental decisions'
if grep -F "$WORK/remap-" "$WORK/cache-remap-a/manifest" \
    "$WORK/cache-remap-b/manifest" >/dev/null
then
    fail 'row 10: a physical source root entered a persisted graph'
fi

# No temporary file survives a committed or a failed run.
find "$WORK/cache" "$WORK/cache-invalid" -name '*.tmp' | grep . >/dev/null &&
    fail 'a transaction temporary survived'

# --------------------------------------------------- explicit unsupported

# A comment before the module header is rejected by the shared declaration
# collector, so row 1 is gated with in-body comments and blank lines. This is
# recorded as an explicit boundary, not silently avoided.
if run_graph "$TOOL" "$WORK/invalid.inventory" "$WORK/cache-skip" \
    "$WORK/skip.report" >/dev/null 2>&1
then
    fail 'a top-level comment was unexpectedly accepted; widen row 1'
fi
printf '%s\n' \
    'SKIP: top-level comments are rejected by the declaration collector (row 1 uses in-body comments)'

# ------------------------------------------- toolchain, sanitizers, analyzer

if command -v clang >/dev/null 2>&1; then
    build_tool clang "$WORK/incremental-clang" source -O2
    rm -rf "$WORK/cache-clang"
    run_graph "$WORK/incremental-clang" "$WORK/base.inventory" "$WORK/cache-clang" \
        "$WORK/clang.report" >/dev/null
    cmp "$WORK/cache/manifest" "$WORK/cache-clang/manifest" ||
        fail 'clang produced a different persisted graph'
fi

build_tool "$CC" "$WORK/incremental-sanitized" source -O1 -g \
    -fsanitize=address,undefined -fno-omit-frame-pointer
rm -rf "$WORK/cache-sanitized"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    run_graph "$WORK/incremental-sanitized" "$WORK/base.inventory" \
    "$WORK/cache-sanitized" "$WORK/sanitized-cold.report" >/dev/null
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    run_graph "$WORK/incremental-sanitized" "$WORK/base.inventory" \
    "$WORK/cache-sanitized" "$WORK/sanitized-warm.report" >/dev/null
cmp "$WORK/cache/manifest" "$WORK/cache-sanitized/manifest" ||
    fail 'the sanitized build produced a different persisted graph'
expect_set "$WORK/sanitized-warm.report" "$ALL_REUSED" 'sanitized warm run'

if "$CC" -std=c11 -O0 -Wall -Wextra -Werror -pedantic -fanalyzer \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/incremental_graph.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/incremental-analyzed" >/dev/null 2>&1
then
    printf '%s\n' 'PASS: GCC analyzer accepts the incremental graph'
fi

printf '%s\n' \
    'PASS: cold runs execute every module and warm no-op runs reuse every module' \
    'PASS: comment, private body, and unused private edits stop at their module' \
    'PASS: internal digest changes invalidate same-package consumers only' \
    'PASS: public digest changes invalidate consumers, transitively when they change too' \
    'PASS: selected import and re-export removals invalidate exactly their edge consumers' \
    'PASS: the external public boundary is reused on internal edits and rejected on public edits' \
    'PASS: unknown schema, corrupt, and oversized cache artifacts are bounded misses' \
    'PASS: a target profile change reuses semantic nodes and rebuilds target artifacts' \
    'PASS: failures and cancellation publish no reusable success; repair executes cold' \
    'PASS: cold executed bytes equal warm reused bytes with exact work counts' \
    'PASS: path-remapped clean copies preserve semantic graph IDs and target decisions'

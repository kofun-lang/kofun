#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../../.." && pwd)
CASES=$ROOT/tests/conformance/discovery
ASSERT_CONTEXT='discovery sanitizer reuse'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"
. "$CASES/sanitizer-objects.sh"

if test "${KOFUN_DISCOVERY_SANITIZER_REUSE_WORK+x}" = x; then
    WORK=$KOFUN_DISCOVERY_SANITIZER_REUSE_WORK
else
    mkdir -p "$ROOT/build"
    WORK=$(mktemp -d "$ROOT/build/discovery-sanitizer-reuse.XXXXXX")
fi
case $WORK in
    */discovery-sanitizer-reuse|*/discovery-sanitizer-reuse.*) ;;
    *) assert_fail "work directory must end in discovery-sanitizer-reuse[.suffix]: $WORK" ;;
esac

cleanup() {
    if test -e "$WORK" || test -L "$WORK"; then
        kofun_stage2_owned_tree_remove "$WORK" 2>/dev/null || true
    fi
}
trap cleanup 0 1 2 15
cleanup
mkdir -p "$WORK"

if test -n "${KOFUN_DISCOVERY_SANITIZER_TEST_REAL_CC:-}"; then
    real_cc=$KOFUN_DISCOVERY_SANITIZER_TEST_REAL_CC
elif test -n "${KOFUN_VERIFY_REAL_CC:-}"; then
    real_cc=$KOFUN_VERIFY_REAL_CC
else
    real_cc=$(command -v "${CC:-cc}") ||
        assert_fail 'a C11 compiler is required'
fi
test -x "$real_cc" || assert_fail "real C compiler is not executable: $real_cc"
command -v nm >/dev/null 2>&1 || assert_fail 'nm is required'

wrapper=$CASES/sanitizer-cc-wrapper.sh
assert_executable 'sanitizer compiler argv wrapper' "$wrapper"
assert_grep 'discovery uses a unique private work directory' \
    -Fq 'mktemp -d "${TMPDIR:-/tmp}/kofun-discovery.XXXXXX"' \
    "$CASES/run.sh"
assert_grep 'discovery cleanup uses the owned-tree remover' \
    -Fq 'kofun_stage2_owned_tree_remove "$WORK"' "$CASES/run.sh"
assert_num 'run script has no superseded sanitizer producer source list' \
    "$(grep -Fc 'bootstrap/stage2/semantic_producer.c' "$CASES/run.sh")" -eq 0
assert_num 'helper owns one canonical sanitizer producer member' \
    "$(grep -Fc "'semantic-producer|semantic-producer-library.o|bootstrap/stage2/semantic_producer.c'" \
        "$CASES/sanitizer-objects.sh")" -eq 1
assert_grep 'first no-macro sanitizer program remains source-built' \
    -Fq '"$WORK/discovery-test-sanitized"' "$CASES/run.sh"
assert_grep 'second no-macro sanitizer program remains source-built' \
    -Fq '"$WORK/discovery-provider-sanitized"' "$CASES/run.sh"

embedded=0
if test "${KOFUN_DISCOVERY_SANITIZER_REUSE_BUNDLE+x}" = x; then
    embedded=1
    bundle=$KOFUN_DISCOVERY_SANITIZER_REUSE_BUNDLE
    census=${KOFUN_DISCOVERY_SANITIZER_REUSE_CENSUS:?missing embedded census}
    source_live=${KOFUN_DISCOVERY_SANITIZER_REUSE_SOURCE_LIVE:?missing embedded source executable}
    object_live=${KOFUN_DISCOVERY_SANITIZER_REUSE_OBJECT_LIVE:?missing embedded live executable}
    object_nominal=${KOFUN_DISCOVERY_SANITIZER_REUSE_OBJECT_NOMINAL:?missing embedded nominal executable}
    object_bounded=${KOFUN_DISCOVERY_SANITIZER_REUSE_OBJECT_BOUNDED:?missing embedded bounded executable}
    object_closure=${KOFUN_DISCOVERY_SANITIZER_REUSE_OBJECT_CLOSURE:?missing embedded closure executable}
else
    bundle=$WORK/objects
    census=$WORK/compiler-argv.tsv
    source_live=$WORK/live-query-source
    object_live=$WORK/live-query-sanitized
    object_nominal=$WORK/nominal-typeid-sanitized
    object_bounded=$WORK/bounded-typeid-sanitized
    object_closure=$WORK/closure-sanitized
    kofun_discovery_sanitizer_objects_build \
        "$ROOT" "$bundle" "$census" "$real_cc"
    kofun_discovery_sanitizer_link \
        "$ROOT" "$bundle" "$census" "$real_cc" \
        "$CASES/live_query_test.c" "$object_live"
    kofun_discovery_sanitizer_link \
        "$ROOT" "$bundle" "$census" "$real_cc" \
        "$CASES/nominal_typeid_test.c" "$object_nominal"
    kofun_discovery_sanitizer_link \
        "$ROOT" "$bundle" "$census" "$real_cc" \
        "$CASES/bounded_typeid_test.c" "$object_bounded"
    kofun_discovery_sanitizer_link \
        "$ROOT" "$bundle" "$census" "$real_cc" \
        "$CASES/closure_test.c" "$object_closure"
fi
kofun_discovery_sanitizer_census_validate "$census"

census_count() {
    awk -F '\t' -v wanted_kind="$2" -v wanted_unit="$3" '
        {
            delete field
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            if ((wanted_kind == "all" || field["kind"] == wanted_kind) &&
                (wanted_unit == "all" || field["unit"] == wanted_unit)) count++
        }
        END { print count + 0 }
    ' "$1"
}

census_wall_ns() {
    awk -F '\t' -v wanted_kind="$2" '
        {
            delete field
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            if (wanted_kind == "all" || field["kind"] == wanted_kind) {
                total += field["wall_ns"]
            }
        }
        END { printf "%.0f\n", total + 0 }
    ' "$1"
}

assert_num 'support translation-unit compile census' \
    "$(census_count "$census" compile all)" -eq 6
assert_num 'semantic producer sanitizer compile census' \
    "$(census_count "$census" compile semantic-producer)" -eq 1
assert_num 'unique driver compile/link census' \
    "$(census_count "$census" link all)" -eq 4
assert_not_grep 'census evidence contains no checkout host path' \
    -Fq "$ROOT" "$census"
assert_not_grep 'manifest evidence contains no checkout host path' \
    -Fq "$ROOT" "$bundle/manifest-v1.tsv"
assert_not_grep 'manifest evidence contains no private work host path' \
    -Fq "$WORK" "$bundle/manifest-v1.tsv"

# Every object-linked executable is both linked through the exact combined
# sanitizer profile above and carries references to both runtime families.
for executable_path in \
    "$object_live" \
    "$object_nominal" \
    "$object_bounded" \
    "$object_closure"
do
    executable=$(basename -- "$executable_path")
    nm -D "$executable_path" >"$WORK/$executable.nm"
    assert_grep "$executable carries the ASan runtime" \
        -Eq '[[:space:]]__asan_init(@|$)' "$WORK/$executable.nm"
    assert_grep "$executable carries the UBSan runtime" \
        -Eq '[[:space:]]__ubsan_handle_' "$WORK/$executable.nm"
done

# The standalone focused gate builds one same-profile source baseline.  When
# embedded in discovery, reuse its already-built normal-profile baseline so
# the full gate keeps the speedup.  Split stdout and stderr so equal combined
# bytes cannot hide a stream move in either path.
if test "$embedded" -eq 0; then
    comparison_name=source/object
    "$real_cc" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/semantic_producer.c" \
        "$ROOT/bootstrap/stage2/semantic_events.c" \
        "$ROOT/bootstrap/stage2/sha256.c" \
        "$ROOT/bootstrap/stage2/discovery_v1.c" \
        "$ROOT/bootstrap/stage2/discovery_provider.c" \
        "$ROOT/bootstrap/stage2/discovery_query.c" \
        "$CASES/live_query_test.c" \
        -o "$source_live"
else
    comparison_name=normal-profile/sanitizer-object
fi

source_status=0
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
    "$source_live" "$CASES/live_list_text.kofun" \
        >"$WORK/source.stdout" 2>"$WORK/source.stderr" || source_status=$?
object_status=0
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
    "$object_live" "$CASES/live_list_text.kofun" \
        >"$WORK/object.stdout" 2>"$WORK/object.stderr" || object_status=$?
assert_num 'baseline representative status' "$source_status" -eq 0
assert_eq 'baseline/object representative status' \
    "$object_status" "$source_status"
cmp "$WORK/source.stdout" "$WORK/object.stdout" ||
    assert_fail 'baseline/object representative stdout differs'
cmp "$WORK/source.stderr" "$WORK/object.stderr" ||
    assert_fail 'baseline/object representative stderr differs'
cmp "$CASES/live_query.golden" "$WORK/object.stdout" ||
    assert_fail 'object-linked representative differs from its golden observation'

copy_mutation_bundle() {
    cp -R "$bundle" "$1"
    chmod u+w "$1"
}

seal_mutation_bundle() {
    chmod 0555 "$1"
}

expect_invalid_bundle() {
    invalid_label=$1
    invalid_bundle=$2
    invalid_text=$3
    invalid_status=0
    kofun_discovery_sanitizer_objects_validate "$ROOT" "$invalid_bundle" \
        >"$WORK/$invalid_label.stdout" \
        2>"$WORK/$invalid_label.stderr" || invalid_status=$?
    assert_num "$invalid_label refusal status" "$invalid_status" -ne 0
    assert_grep "$invalid_label refusal diagnostic" \
        -Fq "$invalid_text" "$WORK/$invalid_label.stderr"
}

corrupt=$WORK/corrupt
copy_mutation_bundle "$corrupt"
chmod u+w "$corrupt/semantic-producer-library.o"
printf '%s\n' corrupt >>"$corrupt/semantic-producer-library.o"
chmod 0444 "$corrupt/semantic-producer-library.o"
seal_mutation_bundle "$corrupt"
expect_invalid_bundle corrupt "$corrupt" \
    'bundle manifest does not match the fixed profile and member bytes'

missing=$WORK/missing
copy_mutation_bundle "$missing"
rm -f -- "$missing/discovery-query.o"
seal_mutation_bundle "$missing"
expect_invalid_bundle missing "$missing" \
    'object bundle must contain exactly eight members'

writable=$WORK/writable
copy_mutation_bundle "$writable"
chmod u+w "$writable/discovery-v1.o"
seal_mutation_bundle "$writable"
expect_invalid_bundle writable "$writable" \
    'bundle member is mutable: discovery-v1.o'

symlink=$WORK/symlink
copy_mutation_bundle "$symlink"
rm -f -- "$symlink/discovery-provider.o"
ln -s "$bundle/discovery-provider.o" "$symlink/discovery-provider.o"
seal_mutation_bundle "$symlink"
expect_invalid_bundle symlink "$symlink" \
    'bundle member is missing or not regular: discovery-provider.o'

# An incomplete set is rejected by the link entry point before a compiler
# which always succeeds can create a false executable.
incomplete_log=$WORK/incomplete-link.tsv
: >"$incomplete_log"
incomplete_status=0
kofun_discovery_sanitizer_link \
    "$ROOT" "$missing" "$incomplete_log" /bin/true \
    "$CASES/live_query_test.c" "$WORK/incomplete-false-pass" \
    >"$WORK/incomplete.stdout" 2>"$WORK/incomplete.stderr" ||
    incomplete_status=$?
assert_num 'incomplete bundle link refusal status' "$incomplete_status" -ne 0
assert_file_empty 'incomplete bundle invokes no compiler' "$incomplete_log"
assert_absent 'incomplete bundle publishes no executable' \
    "$WORK/incomplete-false-pass"

# A compiler failure on the first member must not fall through a shell loop,
# publish a partial directory, or leave its private staging tree behind.
failed_build=$WORK/failed-build-objects
failed_build_log=$WORK/failed-build.tsv
failed_build_status=0
kofun_discovery_sanitizer_objects_build \
    "$ROOT" "$failed_build" "$failed_build_log" /bin/false \
    >"$WORK/failed-build.stdout" 2>"$WORK/failed-build.stderr" ||
    failed_build_status=$?
assert_num 'failed support compile refusal status' \
    "$failed_build_status" -ne 0
assert_absent 'failed support compile publishes no bundle' "$failed_build"
failed_build_temps=$(
    find "$WORK" -mindepth 1 -maxdepth 1 \
        -name '.failed-build-objects.*' -print | awk 'END { print NR + 0 }'
)
assert_num 'failed support compile cleans its private staging tree' \
    "$failed_build_temps" -eq 0
assert_num 'failed support compile stops at the first member' \
    "$(awk 'END { print NR + 0 }' "$failed_build_log")" -eq 1

mutation_log=$WORK/argv-mutations.tsv
: >"$mutation_log"
KOFUN_DISCOVERY_SANITIZER_REAL_CC=/bin/true
KOFUN_DISCOVERY_SANITIZER_CENSUS_LOG=$mutation_log
KOFUN_DISCOVERY_SANITIZER_ROOT=$ROOT
KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR=$bundle
KOFUN_DISCOVERY_SANITIZER_OUTPUT=$object_live
export KOFUN_DISCOVERY_SANITIZER_REAL_CC \
    KOFUN_DISCOVERY_SANITIZER_CENSUS_LOG \
    KOFUN_DISCOVERY_SANITIZER_ROOT \
    KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR \
    KOFUN_DISCOVERY_SANITIZER_OUTPUT

mutated_compile() {
    mutated_opt=$1
    mutated_sanitizer=$2
    mutated_macro=$3
    set -- -std=c11 "$mutated_opt" -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer
    if test "$mutated_sanitizer" = present; then
        set -- "$@" -fsanitize=address,undefined
    fi
    if test "$mutated_macro" = present; then
        set -- "$@" -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY
    fi
    set -- "$@" -I"$ROOT/bootstrap/stage2" \
        -c "$ROOT/bootstrap/stage2/semantic_producer.c" \
        -o "$bundle/semantic-producer-library.o"
    "$wrapper" "$@"
}

mutated_source_object_mix() {
    "$wrapper" \
        -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
        -I"$ROOT/bootstrap/stage2" \
        "$bundle/semantic-producer-library.o" \
        "$bundle/semantic-events.o" \
        "$bundle/sha256.o" \
        "$bundle/discovery-v1.o" \
        "$bundle/discovery-provider.o" \
        "$bundle/discovery-query.o" \
        "$ROOT/bootstrap/stage2/semantic_producer.c" \
        "$CASES/live_query_test.c" \
        -o "$object_live"
}

expect_argv_refusal() {
    argv_label=$1
    shift
    argv_status=0
    "$@" >"$WORK/$argv_label.stdout" 2>"$WORK/$argv_label.stderr" ||
        argv_status=$?
    assert_num "$argv_label argv refusal status" "$argv_status" -eq 2
    assert_grep "$argv_label names the argv refusal" \
        -Fq 'discovery sanitizer compiler: refused argv:' \
        "$WORK/$argv_label.stderr"
}

expect_argv_refusal o0 mutated_compile -O0 present present
expect_argv_refusal missing-sanitizer mutated_compile -O1 missing present
expect_argv_refusal missing-library-macro mutated_compile -O1 present missing
expect_argv_refusal source-object-mix mutated_source_object_mix
assert_file_empty 'refused argv never reaches the always-success compiler' \
    "$mutation_log"

incomplete_census=$WORK/incomplete-census.tsv
sed '$d' "$census" >"$incomplete_census"
incomplete_census_status=0
kofun_discovery_sanitizer_census_validate "$incomplete_census" \
    >"$WORK/incomplete-census.stdout" \
    2>"$WORK/incomplete-census.stderr" || incomplete_census_status=$?
assert_num 'incomplete argv census refusal status' \
    "$incomplete_census_status" -ne 0

# Two unique run-owned paths coexist; removing one through the same cleanup
# primitive used by discovery cannot touch the other.
private_one=$(mktemp -d "$WORK/private-run.XXXXXX")
private_two=$(mktemp -d "$WORK/private-run.XXXXXX")
assert_ne 'concurrent private work identities' "$private_one" "$private_two"
printf '%s\n' keep >"$private_two/caller-owned-sentinel"
kofun_stage2_owned_tree_remove "$private_one"
assert_absent 'first private work is removed' "$private_one"
assert_file_nonempty 'second private work remains intact' \
    "$private_two/caller-owned-sentinel"

compile_wall_ns=$(census_wall_ns "$census" compile)
link_wall_ns=$(census_wall_ns "$census" link)
printf '%s\n' \
    "MEASURE: support_compiles=6 driver_links=4 compile_wall_ns=$compile_wall_ns link_wall_ns=$link_wall_ns" \
    'PASS: one immutable discovery sanitizer bundle serves four drivers' \
    "PASS: $comparison_name status, stdout, stderr, and golden observation agree" \
    'PASS: profile, member, census, and private-lifecycle mutations refuse'

#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../../.." && pwd)
ASSERT_CONTEXT='verify object reuse'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"
. "$ROOT/bootstrap/stage2/fuzz-sanitizer-object.sh"

if test "${KOFUN_VERIFY_OBJECT_REUSE_WORK+x}" = x; then
    WORK=$KOFUN_VERIFY_OBJECT_REUSE_WORK
else
    mkdir -p "$ROOT/build"
    WORK=$(mktemp -d "$ROOT/build/verify-object-reuse.XXXXXX")
fi
case $WORK in
    */verify-object-reuse|*/verify-object-reuse.*) ;;
    *) assert_fail "work directory must end in verify-object-reuse[.suffix]: $WORK" ;;
esac

cleanup() {
    if test -e "$WORK" || test -L "$WORK"; then
        kofun_stage2_owned_tree_remove "$WORK" 2>/dev/null || true
    fi
}
trap cleanup 0 1 2 15
cleanup
mkdir -p "$WORK"

# The standard producer used to occur in thirteen direct gate build stanzas
# plus the driver's main and library build stanzas.  All fifteen now use the
# selector.  Raw source references remain only in explicitly distinct
# sanitizer/analyzer/PIC profiles.
direct_consumers='tests/conformance/effects/pure-io/run.sh
tests/typed-sidecar/producer-races.sh
tests/typed-sidecar/stage2-projector.sh
tests/typed-sidecar/stage2-events.sh
tests/conformance/discovery/run.sh
tests/conformance/modules/stage2-kif-producer/run.sh
tests/diagnostics/visibility-api-leaks.sh
tests/docs/documentation-index.sh
tests/interfaces/visibility-filtering.sh'

printf '%s\n' "$direct_consumers" |
while IFS= read -r consumer; do
    assert_grep "$consumer sources the object selector" \
        -Fq 'bootstrap/stage2/semantic-objects.sh' "$ROOT/$consumer"
    assert_grep "$consumer links the selected producer input" \
        -Fq '"$KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT"' "$ROOT/$consumer"
done
assert_grep 'bin/kofun sources the object selector' \
    -Fq 'bootstrap/stage2/semantic-objects.sh' "$ROOT/bin/kofun"
assert_grep 'bin/kofun selects the main profile' \
    -Fq 'kofun_stage2_semantic_inputs "$ROOT" main' "$ROOT/bin/kofun"
assert_grep 'bin/kofun selects the library profile' \
    -Fq 'kofun_stage2_semantic_inputs "$ROOT" library' "$ROOT/bin/kofun"
assert_grep 'events executable cache uses bundle content identity' \
    -Fq 'kofun-stage2-semantic-events.$KOFUN_STAGE2_SEMANTIC_EXECUTABLE_ID' \
    "$ROOT/bin/kofun"
assert_grep 'KIF executable cache uses bundle content identity' \
    -Fq 'kofun-stage2-kif.$KOFUN_STAGE2_SEMANTIC_EXECUTABLE_ID' \
    "$ROOT/bin/kofun"

direct_stanzas=$(
    printf '%s\n' "$direct_consumers" |
    while IFS= read -r consumer; do
        grep -Fc '"$KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT"' "$ROOT/$consumer"
    done |
    awk '{ total += $1 } END { print total + 0 }'
)
driver_stanzas=$(
    grep -Ec '^[[:space:]]+kofun_stage2_semantic_executable_link "\$STAGE2_(EVENTS|KIF)_COMPILER" \\$' \
        "$ROOT/bin/kofun"
)
assert_num 'direct standard producer build stanzas' "$direct_stanzas" -eq 13
assert_num 'driver standard producer build stanzas' "$driver_stanzas" -eq 2
legacy_standard_stanzas=$((direct_stanzas + driver_stanzas))
assert_num 'legacy standard producer build census' \
    "$legacy_standard_stanzas" -eq 15

assert_num 'stage2-events keeps only three special producer source profiles' \
    "$(grep -Fc 'bootstrap/stage2/semantic_producer.c' \
        "$ROOT/tests/typed-sidecar/stage2-events.sh")" -eq 3
assert_grep 'stage2-events keeps sanitizer coverage local' \
    -Fq -- '-fsanitize=address,undefined' \
    "$ROOT/tests/typed-sidecar/stage2-events.sh"
assert_grep 'stage2-events keeps clang analyzer coverage local' \
    -Fq -- 'clang --analyze' "$ROOT/tests/typed-sidecar/stage2-events.sh"
assert_grep 'stage2-events keeps GCC analyzer coverage local' \
    -Fq -- '-fanalyzer' "$ROOT/tests/typed-sidecar/stage2-events.sh"
assert_num 'discovery run has no repeated sanitizer producer source lists' \
    "$(grep -Fc 'bootstrap/stage2/semantic_producer.c' \
        "$ROOT/tests/conformance/discovery/run.sh")" -eq 0
assert_num 'discovery helper owns one sanitizer producer member' \
    "$(grep -Fc \
        "'semantic-producer|semantic-producer-library.o|bootstrap/stage2/semantic_producer.c'" \
        "$ROOT/tests/conformance/discovery/sanitizer-objects.sh")" -eq 1
assert_grep 'discovery keeps sanitizer coverage local' \
    -Fq -- '-fsanitize=address,undefined' \
    "$ROOT/tests/conformance/discovery/sanitizer-objects.sh"
assert_grep 'LSP keeps its PIC producer source profile local' \
    -Fq -- '-fPIC' "$ROOT/tooling/lsp/build-semantic-bundle.sh"
assert_grep 'LSP still compiles the producer source' \
    -Fq 'bootstrap/stage2/semantic_producer.c' \
    "$ROOT/tooling/lsp/build-semantic-bundle.sh"

common_consumers='tests/conformance/modules/kif-v1/run.sh
tests/artifact-qualification/check.sh
tests/conformance/modules/stage2-kif-producer/run.sh
tests/conformance/incremental/run.sh
tests/docs/documentation-index.sh
tests/interfaces/visibility-filtering.sh
tests/fuzz/visibility-artifacts.sh
tests/conformance/modules/re-exports/run.sh'
printf '%s\n' "$common_consumers" |
while IFS= read -r consumer; do
    assert_grep "$consumer sources the common selector" \
        -Fq 'bootstrap/stage2/semantic-objects.sh' "$ROOT/$consumer"
    assert_grep "$consumer selects the closed common inputs" \
        -Fq 'kofun_stage2_semantic_common_inputs "$ROOT"' "$ROOT/$consumer"
done

# The `-O0 -fanalyzer` consumers (#1449). Three of them also link the O2
# members and appear above; two reach the bundle only through the analysed
# selector, so a list derived from the O2 consumers would not see them, and
# their site identities would never be compared against the wrapper's table.
analyzer_consumers='tests/conformance/modules/kif-v1/run.sh
tests/conformance/incremental/run.sh
tests/conformance/modules/imports-selective/run.sh
tests/conformance/modules/re-exports/run.sh
tests/conformance/modules/top-level-declarations/run.sh'
printf '%s\n' "$analyzer_consumers" |
while IFS= read -r analyzer_consumer; do
    assert_grep "$analyzer_consumer sources the common selector" \
        -Fq 'bootstrap/stage2/semantic-objects.sh' "$ROOT/$analyzer_consumer"
    assert_grep "$analyzer_consumer selects the closed analysed inputs" \
        -Fq 'kofun_stage2_analyzer_common_inputs "$ROOT"' \
        "$ROOT/$analyzer_consumer"
done
for analyzer_role_var in \
    KOFUN_STAGE2_ANALYZER_KIF_V1_INPUT \
    KOFUN_STAGE2_ANALYZER_UNICODE_INPUT \
    KOFUN_STAGE2_ANALYZER_SHA256_INPUT \
    KOFUN_STAGE2_ANALYZER_VISIBILITY_INPUT
do
    assert_grep "analysed selector assigns $analyzer_role_var" \
        -Fq "$analyzer_role_var=" "$ROOT/bootstrap/stage2/semantic-objects.sh"
done

expected_common_sites=$WORK/common-sites.expected
actual_common_sites=$WORK/common-sites.actual
printf '%s\n' \
    artifact-qualification/kif-measure \
    artifact-qualification/kif-tool \
    documentation-index/producer \
    documentation-index/reader \
    fuzz-visibility-artifacts/reader \
    fuzz-visibility-artifacts/resolver \
    imports-selective/analyzed \
    incremental/analyzed \
    incremental/graph \
    incremental/reader \
    kif-v1/analyzed \
    kif-v1/codec-test \
    kif-v1/tool \
    re-exports/analyzed \
    re-exports/export-binding-reference \
    re-exports/reader \
    re-exports/resolver \
    stage2-kif-producer/producer \
    stage2-kif-producer/reader \
    top-level-declarations/analyzed \
    visibility-filtering/producer \
    visibility-filtering/reader >"$expected_common_sites"
printf '%s\n%s\n' "$common_consumers" "$analyzer_consumers" |
LC_ALL=C sort -u |
while IFS= read -r consumer; do
    sed -n 's/.*KOFUN_STAGE2_COMMON_LINK_ID=\([^ \\]*\).*/\1/p' \
        "$ROOT/$consumer"
done | LC_ALL=C sort >"$actual_common_sites"
cmp "$expected_common_sites" "$actual_common_sites"
assert_num 'closed common site identity count' \
    "$(wc -l <"$actual_common_sites" | tr -d ' ')" -eq 22

for common_role_var in \
    KOFUN_STAGE2_COMMON_KIF_V1_INPUT \
    KOFUN_STAGE2_COMMON_UNICODE_INPUT \
    KOFUN_STAGE2_COMMON_SHA256_INPUT \
    KOFUN_STAGE2_COMMON_VISIBILITY_INPUT
do
    assert_grep "common selector assigns $common_role_var" \
        -Fq "$common_role_var=" "$ROOT/bootstrap/stage2/semantic-objects.sh"
done
common_var_census() {
    printf '%s\n' "$common_consumers" |
    while IFS= read -r consumer; do
        grep -Fc "\"\$$1\"" "$ROOT/$consumer" || true
    done | awk '{ n += $1 } END { print n + 0 }'
}
assert_num 'selected common KIF input occurrence census' \
    "$(common_var_census KOFUN_STAGE2_COMMON_KIF_V1_INPUT)" -eq 16
assert_num 'selected common Unicode input occurrence census' \
    "$(common_var_census KOFUN_STAGE2_COMMON_UNICODE_INPUT)" -eq 13
assert_num 'selected common SHA-256 input occurrence census' \
    "$(common_var_census KOFUN_STAGE2_COMMON_SHA256_INPUT)" -eq 17
assert_num 'selected common visibility input occurrence census' \
    "$(common_var_census KOFUN_STAGE2_COMMON_VISIBILITY_INPUT)" -eq 3

assert_common_source_occurrences() {
    source_consumer=$1
    expected_occurrences=$2
    shift 2
    for preserved_source in "$@"; do
        assert_num "$source_consumer preserves $expected_occurrences excluded $preserved_source profiles" \
            "$(grep -Fc "$preserved_source" "$ROOT/$source_consumer" || true)" \
            -eq "$expected_occurrences"
    done
}
# Each of these three dropped by exactly one when #1449 moved the `-O0
# -fanalyzer` arm onto the shared bundle: the arm was the one remaining site in
# each gate that named these sources literally under that profile. The counts
# are lowered deliberately here, in the same commit, so the reduction is
# recorded rather than absorbed -- and so a later change that re-splits the
# family fails instead of silently costing the analyses back.
assert_common_source_occurrences tests/conformance/modules/kif-v1/run.sh 2 \
    bootstrap/stage2/kif_v1.c \
    unicode/kofun_unicode.c \
    bootstrap/stage2/sha256.c
assert_common_source_occurrences tests/conformance/incremental/run.sh 1 \
    bootstrap/stage2/kif_v1.c \
    unicode/kofun_unicode.c \
    bootstrap/stage2/sha256.c \
    bootstrap/stage2/visibility_access.c
assert_common_source_occurrences tests/conformance/modules/re-exports/run.sh 3 \
    bootstrap/stage2/kif_v1.c \
    unicode/kofun_unicode.c \
    bootstrap/stage2/sha256.c \
    bootstrap/stage2/visibility_access.c
for shared_only_consumer in \
    tests/artifact-qualification/check.sh \
    tests/conformance/modules/stage2-kif-producer/run.sh \
    tests/docs/documentation-index.sh \
    tests/interfaces/visibility-filtering.sh \
    tests/fuzz/visibility-artifacts.sh
do
    assert_common_source_occurrences "$shared_only_consumer" 0 \
        bootstrap/stage2/kif_v1.c \
        unicode/kofun_unicode.c \
        bootstrap/stage2/sha256.c \
        bootstrap/stage2/visibility_access.c
done

for source_only_consumer in \
    bin/kofun \
    tests/conformance/effects/pure-io/run.sh \
    tests/typed-sidecar/producer-races.sh \
    tests/typed-sidecar/stage2-projector.sh \
    tests/conformance/modules/stage2-kif-producer/run.sh \
    tests/diagnostics/visibility-api-leaks.sh \
    tests/docs/documentation-index.sh \
    tests/interfaces/visibility-filtering.sh
do
    assert_not_grep "$source_only_consumer has no duplicate producer source branch" \
        -Fq 'bootstrap/stage2/semantic_producer.c' \
        "$ROOT/$source_only_consumer"
done

assert_num 'bundle builder compiles exactly two producer profiles' \
    "$(grep -Fc -- \
        '-c "$kofun_semantic_build_root/bootstrap/stage2/semantic_producer.c"' \
        "$ROOT/bootstrap/stage2/semantic-objects.sh")" -eq 2
assert_grep 'bundle builder retains optimized strict warnings' \
    -Fq -- '-std=c11 -O2 -g -Wall -Wextra -Werror -pedantic' \
    "$ROOT/bootstrap/stage2/semantic-objects.sh"
assert_grep 'bundle validator derives content identity' \
    -Fq 'KOFUN_STAGE2_SEMANTIC_OBJECT_ID=' \
    "$ROOT/bootstrap/stage2/semantic-objects.sh"
assert_grep 'bundle publishes canonical provenance' \
    -Fq 'kofun.stage2-semantic-object-manifest/v2' \
    "$ROOT/bootstrap/stage2/semantic-objects.sh"
assert_num 'bundle builder compiles exactly four common O2 roles' \
    "$(grep -Ec -- '-o "\$kofun_semantic_build_tmp/(kif-v1-common-o2|kofun-unicode-common-o2|sha256-common-o2|visibility-access-common-o2)\.o"' \
        "$ROOT/bootstrap/stage2/semantic-objects.sh")" -eq 4
# The `-O0 -fanalyzer` family (#1449). Counted separately from the O2 family
# rather than folded into one total, so a bundle that dropped an analyzer role
# and gained an O2 one could not keep the number right.
assert_num 'bundle builder compiles exactly four common analyzer roles' \
    "$(grep -Ec -- '-o "\$kofun_semantic_build_tmp/(kif-v1-common-analyzer|kofun-unicode-common-analyzer|sha256-common-analyzer|visibility-access-common-analyzer)\.o"' \
        "$ROOT/bootstrap/stage2/semantic-objects.sh")" -eq 4
assert_grep 'KIF identity names its complete non-object source closure' \
    -Fq 'kofun_stage2_semantic_kif_source_paths' \
    "$ROOT/bootstrap/stage2/semantic-objects.sh"
assert_grep 'verify delegates to an owned runner' \
    -Fq 'bootstrap/stage2/verify-runner.sh' "$ROOT/Taskfile.yml"
assert_grep 'task help retains the object reuse gate' \
    -Fq "'verify-object-reuse'" "$ROOT/tooling/task-help.mjs"
assert_not_grep 'Taskfile no longer deletes a shared verify directory' \
    -Fq 'rm -rf "$PWD/build/verify"' "$ROOT/Taskfile.yml"
assert_grep 'verify runner creates a unique owned directory' \
    -Fq 'mktemp -d "$verify_root/build/verify.XXXXXX"' \
    "$ROOT/bootstrap/stage2/verify-runner.sh"
assert_grep 'verify runner owns semantic event executables' \
    -Fq 'KOFUN_STAGE2_EVENTS_BUILD_DIR=$verify_run/stage2-events-cli' \
    "$ROOT/bootstrap/stage2/verify-runner.sh"
assert_grep 'verify runner owns KIF executables' \
    -Fq 'KOFUN_STAGE2_KIF_BUILD_DIR=$verify_run/stage2-kif-cli' \
    "$ROOT/bootstrap/stage2/verify-runner.sh"
assert_grep 'verify runner checks the completed census last' \
    -Fq 'task verify-object-reuse' \
    "$ROOT/bootstrap/stage2/verify-runner.sh"
assert_not_grep 'semantic event links use no predictable pid temp' \
    -Fq 'STAGE2_EVENTS_COMPILER.tmp.$$' "$ROOT/bin/kofun"
assert_not_grep 'semantic KIF links use no predictable pid temp' \
    -Fq 'STAGE2_KIF_COMPILER.tmp.$$' "$ROOT/bin/kofun"
assert_grep 'semantic executable links use mktemp' \
    -Fq 'kofun_semantic_executable_tmp=$(mktemp' \
    "$ROOT/bootstrap/stage2/semantic-objects.sh"
assert_grep 'verify runner refuses a recursive compiler wrapper' \
    -Fq 'CC resolves to the compiler census wrapper itself' \
    "$ROOT/bootstrap/stage2/verify-runner.sh"
assert_not_grep 'verify runner cleanup does not recursively chmod a mutable root' \
    -Eq '^[[:space:]]*chmod -R' "$ROOT/bootstrap/stage2/verify-runner.sh"
assert_not_grep 'object cleanup does not recursively chmod a mutable root' \
    -Eq '^[[:space:]]*chmod -R' \
    "$ROOT/bootstrap/stage2/semantic-objects.sh"

# These fixtures copy 0444 bundle members into a writable, run-owned
# directory.  Bare rm prompts when this gate has a TTY, so assert the exact
# noninteractive removal before reaching any of the mutations.
for owned_fixture_removal in \
    '$partial/semantic-producer-library.o' \
    '$partial_common/kif-v1-common-o2.o' \
    '$nonregular/semantic-producer-main.o' \
    '$member_symlink/kif-v1-common-o2.o' \
    '$missing_manifest/manifest-v2.tsv' \
    '$o0_bundle/semantic-producer-main.o' \
    '$swapped_bundle/.semantic-producer-main.o.saved' \
    '$swapped_common_bundle/.kif-v1-common-o2.o.saved'
do
    assert_grep "owned fixture removal is noninteractive: $owned_fixture_removal" \
        -Fxq "rm -f -- \"$owned_fixture_removal\"" \
        "$ROOT/tests/tooling/verify-object-reuse/check.sh"
done

if test -n "${KOFUN_VERIFY_REAL_CC:-}"; then
    real_cc=$KOFUN_VERIFY_REAL_CC
    test -x "$real_cc" || assert_fail "real C compiler is not executable: $real_cc"
else
    real_cc=$(command -v "${CC:-cc}") ||
        assert_fail 'a C11 compiler is required'
fi
wrapper=$ROOT/bootstrap/stage2/verify-cc-wrapper.sh
assert_executable 'semantic compiler census wrapper' "$wrapper"
KOFUN_VERIFY_REAL_CC=$real_cc
export KOFUN_VERIFY_REAL_CC
kofun_stage2_semantic_compiler_identity "$ROOT"
expected_common_cc_path=$KOFUN_STAGE2_SEMANTIC_COMPILER_PATH
expected_common_cc_sha256=$KOFUN_STAGE2_SEMANTIC_COMPILER_SHA256
expected_common_cc_path_hex=$(printf '%s' "$expected_common_cc_path" |
    od -An -v -tx1 | tr -d ' \n')
if test "${KOFUN_VERIFY_REAL_CC_PATH+x}" = x; then
    assert_eq 'runner expected compiler path matches fresh resolution' \
        "$KOFUN_VERIFY_REAL_CC_PATH" "$expected_common_cc_path"
    assert_eq 'runner expected compiler digest matches fresh resolution' \
        "$KOFUN_VERIFY_REAL_CC_SHA256" "$expected_common_cc_sha256"
else
    KOFUN_VERIFY_REAL_CC_PATH=$expected_common_cc_path
    KOFUN_VERIFY_REAL_CC_SHA256=$expected_common_cc_sha256
    export KOFUN_VERIFY_REAL_CC_PATH KOFUN_VERIFY_REAL_CC_SHA256
fi

# A failed or signalled compile in the newly shared strict-O2 half must never
# publish a partial bundle or leave its sibling staging directory behind.  The
# fake compiler writes enough earlier members to make both cleanup assertions
# meaningful, then fails during one of the four new common-role compiles.
failing_common_cc=$WORK/failing-common-cc.sh
cat >"$failing_common_cc" <<'EOF_FAILING_COMMON_CC'
#!/bin/sh
set -eu

test -n "${KOFUN_FAILING_CC_COUNTER:-}" || exit 97
test -n "${KOFUN_FAILING_CC_AT:-}" || exit 97
test -n "${KOFUN_FAILING_CC_MODE:-}" || exit 97

if test -f "$KOFUN_FAILING_CC_COUNTER"; then
    failing_common_count=$(cat "$KOFUN_FAILING_CC_COUNTER")
else
    failing_common_count=0
fi
failing_common_count=$((failing_common_count + 1))
printf '%s\n' "$failing_common_count" >"$KOFUN_FAILING_CC_COUNTER"

failing_common_output=
while test "$#" -gt 0; do
    case $1 in
        -o)
            shift
            test "$#" -gt 0 || exit 97
            failing_common_output=$1
            ;;
    esac
    shift
done
test -n "$failing_common_output" || exit 97

if test "$failing_common_count" -eq "$KOFUN_FAILING_CC_AT"; then
    case $KOFUN_FAILING_CC_MODE in
        fail) exit 86 ;;
        term)
            kill -TERM "$PPID"
            exit 143
            ;;
        *) exit 97 ;;
    esac
fi
printf 'fake object %s\n' "$failing_common_count" \
    >"$failing_common_output"
EOF_FAILING_COMMON_CC
chmod 0755 "$failing_common_cc"

exercise_interrupted_common_build() {
    interrupted_label=$1
    interrupted_mode=$2
    interrupted_at=$3
    interrupted_expected_status=$4
    interrupted_target=$WORK/$interrupted_label-bundle
    interrupted_counter=$WORK/$interrupted_label.count

    set +e
    (
        CC=$failing_common_cc
        KOFUN_FAILING_CC_COUNTER=$interrupted_counter
        KOFUN_FAILING_CC_AT=$interrupted_at
        KOFUN_FAILING_CC_MODE=$interrupted_mode
        export CC KOFUN_FAILING_CC_COUNTER KOFUN_FAILING_CC_AT \
            KOFUN_FAILING_CC_MODE
        kofun_stage2_semantic_objects_build "$ROOT" "$interrupted_target"
    ) >"$WORK/$interrupted_label.stdout" \
        2>"$WORK/$interrupted_label.stderr"
    interrupted_status=$?
    set -e

    assert_num "$interrupted_label terminal status" \
        "$interrupted_status" -eq "$interrupted_expected_status"
    assert_eq "$interrupted_label reaches the selected common compile" \
        "$(cat "$interrupted_counter")" "$interrupted_at"
    assert_absent "$interrupted_label publishes no partial bundle" \
        "$interrupted_target"
    assert_num "$interrupted_label removes sibling staging directories" \
        "$(find "$WORK" -mindepth 1 -maxdepth 1 -type d \
            -name ".$interrupted_label-bundle.*" -print | \
            wc -l | tr -d ' ')" -eq 0
}

exercise_interrupted_common_build failed-common-build fail 6 86
exercise_interrupted_common_build signalled-common-build term 7 143

# Keep both enumerated source closures honest when a local #include changes.
# -MM excludes system headers; every remaining dependency must normalize under
# this checkout and equal the helper's exact, sorted path set.
record_dependency_closure() {
    dependency_root=$1
    dependency_output=$2
    shift 2
    dependency_root_physical=$(CDPATH= cd -P -- "$dependency_root" && pwd) ||
        assert_fail "cannot normalize dependency root: $dependency_root"
    : >"$dependency_output.unsorted"
    for dependency_spec in "$@"; do
        dependency_profile=${dependency_spec%%:*}
        dependency_source=${dependency_spec#*:}
        case $dependency_profile in
            producer-main|semantic-events|sha256|common-kif-v1-o2|\
common-unicode-o2|common-sha256-o2|common-visibility-o2|\
common-kif-v1-analyzer|common-unicode-analyzer|\
common-sha256-analyzer|common-visibility-analyzer)
                dependency_define=
                ;;
            producer-library|kif)
                dependency_define=-DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY
                ;;
            *) assert_fail "unknown dependency profile: $dependency_profile" ;;
        esac
        # Ask for a fixed target and relative dependency paths, then parse the
        # Make depfile framing without eval.  Backslash escapes (including an
        # escaped checkout/file-name space), continuations, and $$ are decoded
        # into one literal dependency per line before the quoted read below.
        dependency_paths=$(
            CDPATH= cd -- "$dependency_root" &&
            "$real_cc" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
                ${dependency_define:+"$dependency_define"} \
                -Ibootstrap/stage2 -MM -MT kofun-dependency-scan \
                "$dependency_source" |
                awk '
                    function emit_token() {
                        if (token == "") return
                        field_count++
                        if (field_count > 1) print token
                        token = ""
                    }
                    {
                        line = $0 "\n"
                        for (index_in_line = 1;
                             index_in_line <= length(line);
                             index_in_line++) {
                            character = substr(line, index_in_line, 1)
                            if (escaped) {
                                if (character != "\n") token = token character
                                escaped = 0
                            } else if (character == "\\") {
                                escaped = 1
                            } else if (character == "$" &&
                                       substr(line, index_in_line + 1, 1) == "$") {
                                token = token "$"
                                index_in_line++
                            } else if (character == " " ||
                                       character == "\t" ||
                                       character == "\n") {
                                emit_token()
                            } else {
                                token = token character
                            }
                        }
                    }
                    END {
                        if (escaped) token = token "\\"
                        emit_token()
                    }
                '
        ) || assert_fail "cannot derive dependencies for $dependency_source"
        while IFS= read -r dependency_path; do
            test -n "$dependency_path" || continue
            case $dependency_path in
                /*)
                    assert_fail \
                        "dependency is not checkout-relative: $dependency_path"
                    ;;
            esac
            dependency_dir=$(dirname -- "$dependency_root/$dependency_path")
            dependency_base=$(basename -- "$dependency_path")
            dependency_dir=$(CDPATH= cd -P -- "$dependency_dir" && pwd) ||
                assert_fail "cannot normalize dependency $dependency_path"
            dependency_absolute=$dependency_dir/$dependency_base
            case $dependency_absolute in
                "$dependency_root_physical"/*)
                    printf '%s\n' \
                        "${dependency_absolute#"$dependency_root_physical"/}" \
                        >>"$dependency_output.unsorted"
                    ;;
                *)
                    assert_fail \
                        "non-system dependency escapes checkout: $dependency_absolute"
                    ;;
            esac
        done <<EOF_DEPENDENCY_PATHS
$dependency_paths
EOF_DEPENDENCY_PATHS
    done
    LC_ALL=C sort -u "$dependency_output.unsorted" >"$dependency_output"
}

semantic_role_sources='producer-main:bootstrap/stage2/semantic_producer.c
producer-library:bootstrap/stage2/semantic_producer.c
semantic-events:bootstrap/stage2/semantic_events.c
sha256:bootstrap/stage2/sha256.c
common-kif-v1-o2:bootstrap/stage2/kif_v1.c
common-unicode-o2:unicode/kofun_unicode.c
common-sha256-o2:bootstrap/stage2/sha256.c
common-visibility-o2:bootstrap/stage2/visibility_access.c
common-kif-v1-analyzer:bootstrap/stage2/kif_v1.c
common-unicode-analyzer:unicode/kofun_unicode.c
common-sha256-analyzer:bootstrap/stage2/sha256.c
common-visibility-analyzer:bootstrap/stage2/visibility_access.c'
printf '%s\n' "$semantic_role_sources" |
while IFS= read -r semantic_role_spec; do
    semantic_role=${semantic_role_spec%%:*}
    record_dependency_closure "$ROOT" \
        "$WORK/$semantic_role-source-closure.actual" \
        "$semantic_role_spec"
    kofun_stage2_semantic_role_input_paths "$semantic_role" \
        >"$WORK/$semantic_role-source-closure.expected"
    cmp "$WORK/$semantic_role-source-closure.expected" \
        "$WORK/$semantic_role-source-closure.actual"
done

common_macro_consumers=$WORK/common-macro-consumers.actual
: >"$common_macro_consumers"
for common_macro_role in \
    common-kif-v1-o2 \
    common-unicode-o2 \
    common-sha256-o2 \
    common-visibility-o2 \
    common-kif-v1-analyzer \
    common-unicode-analyzer \
    common-sha256-analyzer \
    common-visibility-analyzer
do
    kofun_stage2_semantic_role_input_paths "$common_macro_role" |
    while IFS= read -r common_macro_input; do
        if grep -En \
            'KOFUN_TEST_DIAGNOSTIC_FAULTS|KOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY|RE_EXPORT_GRAPH_WORK_LIMIT' \
            "$ROOT/$common_macro_input" >/dev/null
        then
            printf '%s:%s\n' "$common_macro_role" "$common_macro_input" \
                >>"$common_macro_consumers"
        fi
    done
done
assert_file_empty \
    'target-local macros are absent from every common role closure' \
    "$common_macro_consumers"

record_dependency_closure "$ROOT" "$WORK/kif-source-closure.actual" \
    kif:bootstrap/stage2/stage2_kif_producer.c \
    kif:bootstrap/stage2/kif_v1.c
kofun_stage2_semantic_kif_source_paths | LC_ALL=C sort -u \
    >"$WORK/kif-source-closure.expected"
cmp "$WORK/kif-source-closure.expected" "$WORK/kif-source-closure.actual"

spaced_dependency_root=$WORK/'checkout path with spaces'
ln -s "$ROOT" "$spaced_dependency_root"
printf '%s\n' "$semantic_role_sources" |
while IFS= read -r semantic_role_spec; do
    semantic_role=${semantic_role_spec%%:*}
    record_dependency_closure "$spaced_dependency_root" \
        "$WORK/spaced-$semantic_role-source-closure.actual" \
        "$semantic_role_spec"
    cmp "$WORK/$semantic_role-source-closure.expected" \
        "$WORK/spaced-$semantic_role-source-closure.actual"
done

census_count() {
    awk -F '\t' -v classifier="$2" '
        {
            delete field
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            standard = field["class"] == "standard-producer-main" ||
                field["class"] == "standard-producer-library"
            selected = 0
            if (classifier == "standard" && standard) selected = 1
            if (classifier == "standard-main" &&
                field["class"] == "standard-producer-main") selected = 1
            if (classifier == "standard-library" &&
                field["class"] == "standard-producer-library") selected = 1
            if (classifier == "events-standard" &&
                field["class"] == "standard-events") selected = 1
            if (classifier == "sha-standard" &&
                field["class"] == "standard-sha") selected = 1
            if (classifier == "producer-source" &&
                field["producer_source"] == 1) selected = 1
            if (classifier == "producer-object" &&
                field["producer_object"] == 1) selected = 1
            if (classifier == "sanitizer" &&
                field["class"] == "special-sanitizer") selected = 1
            if (classifier == "discovery-sanitizer" &&
                field["class"] == "special-sanitizer" &&
                field["output"] == "semantic-producer-library.o" &&
                field["library"] == 1 && field["compile_only"] == 1)
                selected = 1
            if (classifier == "analyzer" &&
                field["class"] == "special-analyzer") selected = 1
            if (classifier == "pic" &&
                field["class"] == "special-pic") selected = 1
            if (classifier == "unexpected-producer" &&
                (field["class"] == "other-producer-source" ||
                 (field["class"] == "mixed-semantic-source-object" &&
                  field["producer_source"] == 1)))
                selected = 1
            if (classifier == "unexpected-semantic-source" &&
                (field["class"] == "other-producer-source" ||
                 field["class"] == "mixed-semantic-source-object" ||
                 field["class"] == "unexpected-events-source" ||
                 field["class"] == "unexpected-sha-source")) selected = 1
            if (classifier == "unexpected-events" &&
                (field["class"] == "unexpected-events-source" ||
                 (field["class"] == "mixed-semantic-source-object" &&
                  field["events_source"] == 1))) selected = 1
            if (classifier == "unexpected-sha" &&
                (field["class"] == "unexpected-sha-source" ||
                 (field["class"] == "mixed-semantic-source-object" &&
                  field["sha_source"] == 1))) selected = 1
            if (classifier == "special-events" &&
                field["class"] == "special-events-source") selected = 1
            if (classifier == "special-sha" &&
                field["class"] == "special-sha-source") selected = 1
            if (classifier == "unexpected-object" &&
                (field["class"] == "producer-object-mixed" ||
                 field["class"] == "mixed-semantic-source-object"))
                selected = 1
            if (classifier == "mixed-object-roles" &&
                field["class"] == "producer-object-mixed") selected = 1
            if (classifier == "failed-object" &&
                field["producer_object"] == 1 && field["status"] != 0)
                selected = 1
            if (classifier == "failed-producer" &&
                (field["producer_source"] == 1 ||
                 field["producer_object"] == 1) &&
                field["status"] != 0)
                selected = 1
            if (classifier == "common-compile" &&
                field["common_class"] ~ /^common-compile-/) selected = 1
            if (classifier == "common-compile-o2" &&
                field["common_class"] ~ /^common-compile-/ &&
                field["common_class"] !~ /-analyzer$/) selected = 1
            if (classifier == "common-compile-analyzer" &&
                field["common_class"] ~ /^common-compile-.*-analyzer$/)
                selected = 1
            if (classifier == "common-compile-kif-v1-analyzer" &&
                field["common_class"] == "common-compile-kif-v1-analyzer")
                selected = 1
            if (classifier == "common-compile-unicode-analyzer" &&
                field["common_class"] == "common-compile-unicode-analyzer")
                selected = 1
            if (classifier == "common-compile-sha256-analyzer" &&
                field["common_class"] == "common-compile-sha256-analyzer")
                selected = 1
            if (classifier == "common-compile-visibility-analyzer" &&
                field["common_class"] == "common-compile-visibility-analyzer")
                selected = 1
            if (classifier == "common-analyzer-object-link" &&
                field["common_class"] == "common-analyzer-object-link")
                selected = 1
            if (classifier == "common-analyzer-source-link" &&
                field["common_class"] == "common-analyzer-source-link")
                selected = 1
            if (classifier == "common-compile-kif-v1" &&
                field["common_class"] == "common-compile-kif-v1") selected = 1
            if (classifier == "common-compile-unicode" &&
                field["common_class"] == "common-compile-unicode") selected = 1
            if (classifier == "common-compile-sha256" &&
                field["common_class"] == "common-compile-sha256") selected = 1
            if (classifier == "common-compile-visibility" &&
                field["common_class"] == "common-compile-visibility") selected = 1
            if (classifier == "common-object-link" &&
                field["common_class"] == "common-object-link") selected = 1
            if (classifier == "common-source-link" &&
                field["common_class"] == "common-source-link") selected = 1
            if (classifier == "unexpected-common" &&
                (field["common_class"] == "unexpected-common-compile" ||
                 field["common_class"] == "unexpected-common-link" ||
                 field["common_class"] == "unexpected-common-object" ||
                 field["common_class"] == "mixed-common-source-object" ||
                 field["common_class"] == "unknown-common-site" ||
                 field["common_class"] == "invalid-common-compiler")) selected = 1
            if (classifier == "failed-common" &&
                (field["site"] != "none" ||
                 field["common_class"] ~ /^common-compile-/) &&
                field["status"] != 0) selected = 1
            count += selected
        }
        END { print count + 0 }
    ' "$1"
}

census_site_count() {
    awk -F '\t' -v wanted_site="$2" \
        -v wanted_class="${3:-common-object-link}" '
        {
            delete field
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            if (field["site"] == wanted_site &&
                field["common_class"] == wanted_class) count++
        }
        END { print count + 0 }
    ' "$1"
}

common_census_error_count() {
    common_census_scope=$2
    case $common_census_scope in
        owners|aggregate) ;;
        *) assert_fail "unknown common census scope: $common_census_scope" ;;
    esac
    awk -F '\t' \
        -v expected_path_hex="$expected_common_cc_path_hex" \
        -v expected_sha256="$expected_common_cc_sha256" \
        -v scope="$common_census_scope" '
        BEGIN {
            expected["kif-v1/tool"] = scope == "aggregate" ? 3 : 2
            expected["kif-v1/codec-test"] = scope == "aggregate" ? 3 : 2
            expected["artifact-qualification/kif-tool"] = 1
            expected["artifact-qualification/kif-measure"] = 1
            expected["stage2-kif-producer/producer"] = 1
            expected["stage2-kif-producer/reader"] = 1
            expected["incremental/graph"] = 1
            expected["incremental/reader"] = 1
            expected["documentation-index/producer"] = 1
            expected["documentation-index/reader"] = 1
            expected["visibility-filtering/producer"] = 1
            expected["visibility-filtering/reader"] = 1
            expected["fuzz-visibility-artifacts/resolver"] = 1
            expected["fuzz-visibility-artifacts/reader"] = 1
            expected["re-exports/resolver"] = scope == "aggregate" ? 2 : 1
            expected["re-exports/reader"] = scope == "aggregate" ? 2 : 1
            expected["re-exports/export-binding-reference"] = \
                scope == "aggregate" ? 2 : 1
            expected_links = scope == "aggregate" ? 24 : 19
            # The analysed sites (#1449), kept in their own map so that an
            # analysed link landing on an O2 site -- or the reverse -- is an
            # unknown site rather than a satisfied expectation.
            expected_analyzed["kif-v1/analyzed"] = \
                scope == "aggregate" ? 3 : 2
            expected_analyzed["re-exports/analyzed"] = \
                scope == "aggregate" ? 2 : 1
            expected_analyzed["incremental/analyzed"] = 1
            expected_analyzed["imports-selective/analyzed"] = 1
            expected_analyzed["top-level-declarations/analyzed"] = 1
            expected_analyzed_links = scope == "aggregate" ? 8 : 6
        }
        {
            delete field
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            common = field["common_class"]
            if (common == "common-object-link") {
                links++
                observed[field["site"]]++
                if (!(field["site"] in expected)) errors++
            } else if (common == "common-analyzer-object-link") {
                analyzed_links++
                observed_analyzed[field["site"]]++
                if (!(field["site"] in expected_analyzed)) errors++
            } else if (common == "common-compile-kif-v1-analyzer") {
                compile_kif_analyzer++
            } else if (common == "common-compile-unicode-analyzer") {
                compile_unicode_analyzer++
            } else if (common == "common-compile-sha256-analyzer") {
                compile_sha_analyzer++
            } else if (common == "common-compile-visibility-analyzer") {
                compile_visibility_analyzer++
            } else if (common == "common-compile-kif-v1") {
                compile_kif++
            } else if (common == "common-compile-unicode") {
                compile_unicode++
            } else if (common == "common-compile-sha256") {
                compile_sha++
            } else if (common == "common-compile-visibility") {
                compile_visibility++
            } else if (common == "common-source-link" ||
                       common == "common-analyzer-source-link" ||
                       common == "unexpected-common-compile" ||
                       common == "unexpected-common-link" ||
                       common == "unexpected-common-object" ||
                       common == "mixed-common-source-object" ||
                       common == "unknown-common-site" ||
                       common == "invalid-common-compiler") {
                errors++
            }
            selected = common == "common-object-link" ||
                common == "common-analyzer-object-link" ||
                common ~ /^common-compile-/
            if (selected && (field["status"] != 0 ||
                field["compiler_identity"] != "valid" ||
                field["compiler_path_hex"] != expected_path_hex ||
                field["compiler_sha256"] != expected_sha256 ||
                field["compiler_path_hex"] !~ /^([0-9a-f][0-9a-f])+$/ ||
                field["compiler_sha256"] !~ /^[0-9a-f]+$/ ||
                length(field["compiler_sha256"]) != 64 ||
                field["argc"] !~ /^[1-9][0-9]*$/ ||
                field["argv_hex"] !~ /^([0-9a-f][0-9a-f])+$/ ||
                field["wall_ns"] !~ /^[0-9]+$/)) errors++
        }
        END {
            if (links != expected_links) errors++
            if (analyzed_links != expected_analyzed_links) errors++
            if (compile_kif != 1) errors++
            if (compile_unicode != 1) errors++
            if (compile_sha != 1) errors++
            if (compile_visibility != 1) errors++
            if (compile_kif_analyzer != 1) errors++
            if (compile_unicode_analyzer != 1) errors++
            if (compile_sha_analyzer != 1) errors++
            if (compile_visibility_analyzer != 1) errors++
            for (site in expected)
                if (observed[site] != expected[site]) errors++
            for (site in expected_analyzed)
                if (observed_analyzed[site] != expected_analyzed[site])
                    errors++
            print errors + 0
        }
    ' "$1"
}

census_wall_ns() {
    awk -F '\t' -v classifier="$2" '
        {
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            selected = classifier == "all"
            if (classifier == "standard" &&
                (field["class"] == "standard-producer-main" ||
                 field["class"] == "standard-producer-library")) selected = 1
            if (classifier == "common-compile" &&
                field["common_class"] ~ /^common-compile-/) selected = 1
            if (classifier == "common-object-link" &&
                field["common_class"] == "common-object-link") selected = 1
            if (classifier == "common-source-link" &&
                field["common_class"] == "common-source-link") selected = 1
            if (classifier == "common-analyzer-object-link" &&
                field["common_class"] == "common-analyzer-object-link")
                selected = 1
            if (classifier == "common-analyzer-source-link" &&
                field["common_class"] == "common-analyzer-source-link")
                selected = 1
            if (selected) total += field["wall_ns"]
        }
        END { printf "%.0f\n", total + 0 }
    ' "$1"
}

census_diagnose() {
    awk -F '\t' -v classifier="$2" '
        {
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            selected = classifier == "unexpected-producer" &&
                (field["class"] == "other-producer-source" ||
                 (field["class"] == "mixed-semantic-source-object" &&
                  field["producer_source"] == 1))
            if (classifier == "unexpected-semantic-source" &&
                (field["class"] == "other-producer-source" ||
                 field["class"] == "mixed-semantic-source-object" ||
                 field["class"] == "unexpected-events-source" ||
                 field["class"] == "unexpected-sha-source")) selected = 1
            if (classifier == "unexpected-object" &&
                (field["class"] == "producer-object-mixed" ||
                 field["class"] == "mixed-semantic-source-object"))
                selected = 1
            if (classifier == "failed-producer" &&
                (field["producer_source"] == 1 ||
                 field["producer_object"] == 1) &&
                field["status"] != 0) selected = 1
            if (selected) {
                printf "CENSUS %s: class=%s output=%s opt=%s", classifier,
                    field["class"], field["output"], field["opt"] > "/dev/stderr"
                printf " library=%s sanitizer=%s analyzer=%s pic=%s",
                    field["library"], field["sanitizer"],
                    field["analyzer"], field["pic"] > "/dev/stderr"
                printf " compile_only=%s extra=%s status=%s\n",
                    field["compile_only"], field["extra"],
                    field["status"] > "/dev/stderr"
            }
        }
    ' "$1"
}

assert_standard_bundle_census() {
    census_log=$1
    assert_regular_file 'semantic compile census' "$census_log"
    assert_num 'standard producer compilation count' \
        "$(census_count "$census_log" standard)" -eq 2
    assert_num 'standard main producer compilation count' \
        "$(census_count "$census_log" standard-main)" -eq 1
    assert_num 'standard library producer compilation count' \
        "$(census_count "$census_log" standard-library)" -eq 1
    assert_num 'standard semantic-events compilation count' \
        "$(census_count "$census_log" events-standard)" -eq 1
    assert_num 'standard SHA-256 compilation count' \
        "$(census_count "$census_log" sha-standard)" -eq 1
    assert_num 'common compilation count across both variants' \
        "$(census_count "$census_log" common-compile)" -eq 8
    assert_num 'common O2 compilation count' \
        "$(census_count "$census_log" common-compile-o2)" -eq 4
    assert_num 'common KIF O2 compilation count' \
        "$(census_count "$census_log" common-compile-kif-v1)" -eq 1
    assert_num 'common Unicode O2 compilation count' \
        "$(census_count "$census_log" common-compile-unicode)" -eq 1
    assert_num 'common SHA-256 O2 compilation count' \
        "$(census_count "$census_log" common-compile-sha256)" -eq 1
    assert_num 'common visibility O2 compilation count' \
        "$(census_count "$census_log" common-compile-visibility)" -eq 1
    # Each analysed source is compiled once for the whole run (#1449). The
    # per-role counts are asserted alongside the total because a total of
    # four is also what compiling one source four times would produce.
    assert_num 'common analysed compilation count' \
        "$(census_count "$census_log" common-compile-analyzer)" -eq 4
    assert_num 'common KIF analysed compilation count' \
        "$(census_count "$census_log" common-compile-kif-v1-analyzer)" -eq 1
    assert_num 'common Unicode analysed compilation count' \
        "$(census_count "$census_log" common-compile-unicode-analyzer)" -eq 1
    assert_num 'common SHA-256 analysed compilation count' \
        "$(census_count "$census_log" common-compile-sha256-analyzer)" -eq 1
    assert_num 'common visibility analysed compilation count' \
        "$(census_count "$census_log" common-compile-visibility-analyzer)" \
        -eq 1
}

if test "${KOFUN_STAGE2_SEMANTIC_OBJECT_DIR+x}" = x; then
    bundle=$KOFUN_STAGE2_SEMANTIC_OBJECT_DIR
    kofun_stage2_semantic_objects_validate "$ROOT" "$bundle"
    test -n "${KOFUN_VERIFY_OBJECT_REUSE_CENSUS_LOG:-}" ||
        assert_fail 'runner bundle is missing its completed compiler census'
    build_log=$KOFUN_VERIFY_OBJECT_REUSE_CENSUS_LOG
    assert_standard_bundle_census "$build_log"
    assert_num 'full verify sanitizer producer classification' \
        "$(census_count "$build_log" sanitizer)" -eq 2
    assert_num 'full verify discovery sanitizer producer compile' \
        "$(census_count "$build_log" discovery-sanitizer)" -eq 1
    assert_num 'full verify PIC producer classification' \
        "$(census_count "$build_log" pic)" -eq 1
    unexpected_semantic_source_count=$(
        census_count "$build_log" unexpected-semantic-source
    )
    if test "$unexpected_semantic_source_count" -ne 0; then
        census_diagnose "$build_log" unexpected-semantic-source
    fi
    assert_num 'full verify nonstandard or mixed semantic source builds' \
        "$unexpected_semantic_source_count" -eq 0
    unexpected_object_count=$(census_count "$build_log" unexpected-object)
    if test "$unexpected_object_count" -ne 0; then
        census_diagnose "$build_log" unexpected-object
    fi
    assert_num 'full verify mixed producer object builds' \
        "$unexpected_object_count" -eq 0
    failed_producer_count=$(census_count "$build_log" failed-producer)
    if test "$failed_producer_count" -ne 0; then
        census_diagnose "$build_log" failed-producer
    fi
    assert_num 'full verify producer compiler failures' \
        "$failed_producer_count" -eq 0
    # The eight owner tasks execute 19 links. Aggregate verify intentionally
    # executes re-exports once more through the diagnostic adapter; that gate
    # also runs its nested KIF prerequisite, adding exactly five executions.
    assert_num 'full verify selected common object-link executions' \
        "$(census_count "$build_log" common-object-link)" -eq 24
    assert_num 'full verify exact-family common source links' \
        "$(census_count "$build_log" common-source-link)" -eq 0
    assert_num 'full verify selected analysed object-link executions' \
        "$(census_count "$build_log" common-analyzer-object-link)" -eq 8
    assert_num 'full verify exact-family analysed source links' \
        "$(census_count "$build_log" common-analyzer-source-link)" -eq 0
    assert_num 'full verify mixed, malformed, or unknown common rows' \
        "$(census_count "$build_log" unexpected-common)" -eq 0
    assert_num 'full verify selected common compiler failures' \
        "$(census_count "$build_log" failed-common)" -eq 0
    assert_num 'full verify distinct selected common site identities' \
        "$(awk -F '\t' '
            {
                delete field
                for (column = 2; column <= NF; column++) {
                    split($column, pair, "=")
                    field[pair[1]] = pair[2]
                }
                if (field["common_class"] == "common-object-link")
                    seen[field["site"]] = 1
            }
            END { for (site in seen) count++; print count + 0 }
        ' "$build_log")" -eq 17
    assert_num 'full verify distinct analysed common site identities' \
        "$(awk -F '\t' '
            {
                delete field
                for (column = 2; column <= NF; column++) {
                    split($column, pair, "=")
                    field[pair[1]] = pair[2]
                }
                if (field["common_class"] == "common-analyzer-object-link")
                    seen[field["site"]] = 1
            }
            END { for (site in seen) count++; print count + 0 }
        ' "$build_log")" -eq 5
    while IFS= read -r expected_site; do
        # An analysed site is counted in its own class; counting it in the O2
        # class would report zero for every one of them and read as a passing
        # `-eq 0` if the expectation were ever written that way.
        expected_site_class=common-object-link
        case $expected_site in
            */analyzed) expected_site_class=common-analyzer-object-link ;;
        esac
        case $expected_site in
            kif-v1/tool|kif-v1/codec-test) expected_site_count=3 ;;
            kif-v1/analyzed) expected_site_count=3 ;;
            re-exports/resolver|re-exports/reader|\
            re-exports/export-binding-reference) expected_site_count=2 ;;
            re-exports/analyzed) expected_site_count=2 ;;
            *) expected_site_count=1 ;;
        esac
        assert_num "full verify $expected_site multiplicity" \
            "$(census_site_count "$build_log" "$expected_site" \
                "$expected_site_class")" \
            -eq "$expected_site_count"
    done <"$expected_common_sites"
    assert_num 'full verify selected rows bind complete argv' \
        "$(awk -F '\t' '
            {
                delete field
                for (column = 2; column <= NF; column++) {
                    split($column, pair, "=")
                    field[pair[1]] = pair[2]
                }
                if ((field["site"] != "none" ||
                     field["common_class"] ~ /^common-compile-/) &&
                    (field["compiler_identity"] != "valid" ||
                     field["compiler_path_hex"] != \
                        "'"$expected_common_cc_path_hex"'" ||
                     field["compiler_sha256"] != \
                        "'"$expected_common_cc_sha256"'" ||
                     field["compiler_path_hex"] !~ /^([0-9a-f][0-9a-f])+$/ ||
                     field["compiler_sha256"] !~ /^[0-9a-f]+$/ ||
                     length(field["compiler_sha256"]) != 64 ||
                     field["argc"] !~ /^[1-9][0-9]*$/ ||
                     field["argv_hex"] !~ /^([0-9a-f][0-9a-f])+$/ ||
                     field["wall_ns"] !~ /^[0-9]+$/)) bad++
            }
            END { print bad + 0 }
        ' "$build_log")" -eq 0
    assert_num 'full verify closed common census contract' \
        "$(common_census_error_count "$build_log" aggregate)" -eq 0
else
    bundle=$WORK/semantic-objects
    build_log=$WORK/bundle-build.log
    : >"$build_log"
    KOFUN_VERIFY_CC_LOG=$build_log \
    CC=$wrapper \
        kofun_stage2_semantic_objects_build "$ROOT" "$bundle"
    kofun_stage2_semantic_objects_validate "$ROOT" "$bundle"
    assert_standard_bundle_census "$build_log"
fi
bundle_identity=$KOFUN_STAGE2_SEMANTIC_OBJECT_ID
bundle_wall_ns=$(census_wall_ns "$build_log" standard)
common_bundle_wall_ns=$(census_wall_ns "$build_log" common-compile)
common_object_link_wall_ns=$(census_wall_ns "$build_log" common-object-link)

saved_semantic_object_dir=$bundle
unset KOFUN_STAGE2_SEMANTIC_OBJECT_DIR
kofun_stage2_semantic_common_inputs "$ROOT"
assert_eq 'standalone common KIF input is source-local' \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" \
    "$ROOT/bootstrap/stage2/kif_v1.c"
assert_eq 'standalone common Unicode input is source-local' \
    "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
    "$ROOT/unicode/kofun_unicode.c"
assert_eq 'standalone common SHA input is source-local' \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" \
    "$ROOT/bootstrap/stage2/sha256.c"
assert_eq 'standalone common visibility input is source-local' \
    "$KOFUN_STAGE2_COMMON_VISIBILITY_INPUT" \
    "$ROOT/bootstrap/stage2/visibility_access.c"
KOFUN_STAGE2_SEMANTIC_OBJECT_DIR=$saved_semantic_object_dir
export KOFUN_STAGE2_SEMANTIC_OBJECT_DIR
kofun_stage2_semantic_common_inputs "$ROOT"
assert_eq 'shared common KIF input is immutable object' \
    "$KOFUN_STAGE2_COMMON_KIF_V1_INPUT" "$bundle/kif-v1-common-o2.o"
assert_eq 'shared common Unicode input is immutable object' \
    "$KOFUN_STAGE2_COMMON_UNICODE_INPUT" \
    "$bundle/kofun-unicode-common-o2.o"
assert_eq 'shared common SHA input is immutable object' \
    "$KOFUN_STAGE2_COMMON_SHA256_INPUT" "$bundle/sha256-common-o2.o"
assert_eq 'shared common visibility input is immutable object' \
    "$KOFUN_STAGE2_COMMON_VISIBILITY_INPUT" \
    "$bundle/visibility-access-common-o2.o"

synthetic_common_census=$WORK/common-census.expected.tsv
: >"$synthetic_common_census"
for synthetic_compile_class in \
    common-compile-kif-v1 \
    common-compile-unicode \
    common-compile-sha256 \
    common-compile-visibility \
    common-compile-kif-v1-analyzer \
    common-compile-unicode-analyzer \
    common-compile-sha256-analyzer \
    common-compile-visibility-analyzer
do
    printf 'cc\tcommon_class=%s\tsite=none\tcompiler_path_hex=%s\tcompiler_sha256=%s\tcompiler_identity=valid\tstatus=0\targc=1\targv_hex=00\twall_ns=1\n' \
        "$synthetic_compile_class" "$expected_common_cc_path_hex" \
        "$expected_common_cc_sha256" >>"$synthetic_common_census"
done
while IFS= read -r synthetic_site; do
    synthetic_class=common-object-link
    case $synthetic_site in
        */analyzed) synthetic_class=common-analyzer-object-link ;;
    esac
    case $synthetic_site in
        kif-v1/tool|kif-v1/codec-test|kif-v1/analyzed) synthetic_count=2 ;;
        *) synthetic_count=1 ;;
    esac
    synthetic_index=0
    while test "$synthetic_index" -lt "$synthetic_count"; do
        printf 'cc\tcommon_class=%s\tsite=%s\tcompiler_path_hex=%s\tcompiler_sha256=%s\tcompiler_identity=valid\tstatus=0\targc=1\targv_hex=00\twall_ns=1\n' \
            "$synthetic_class" "$synthetic_site" \
            "$expected_common_cc_path_hex" \
            "$expected_common_cc_sha256" >>"$synthetic_common_census"
        synthetic_index=$((synthetic_index + 1))
    done
done <"$expected_common_sites"
assert_num 'synthetic closed common census baseline' \
    "$(common_census_error_count "$synthetic_common_census" owners)" -eq 0

# Aggregate verify runs the re-exports gate both as its own owner task and as
# the diagnostic registry adapter.  Re-exports also executes its nested KIF
# prerequisite, so the second owner execution contributes these exact seven
# rows without adding a new call-site identity -- five O2 links and the two
# analysed links those same two gates carry (#1449).
synthetic_aggregate_census=$WORK/common-census.aggregate.tsv
cp "$synthetic_common_census" "$synthetic_aggregate_census"
for synthetic_aggregate_site in \
    kif-v1/tool \
    kif-v1/codec-test \
    kif-v1/analyzed \
    re-exports/resolver \
    re-exports/reader \
    re-exports/export-binding-reference \
    re-exports/analyzed
do
    synthetic_aggregate_class=common-object-link
    case $synthetic_aggregate_site in
        */analyzed) synthetic_aggregate_class=common-analyzer-object-link ;;
    esac
    awk -F '\t' -v wanted_site="$synthetic_aggregate_site" \
        -v wanted_class="$synthetic_aggregate_class" '
        {
            delete field
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            if (field["site"] == wanted_site &&
                field["common_class"] == wanted_class) {
                print
                found = 1
                exit
            }
        }
        END { if (!found) exit 1 }
    ' "$synthetic_common_census" >>"$synthetic_aggregate_census"
done
assert_num 'synthetic aggregate common census baseline' \
    "$(common_census_error_count "$synthetic_aggregate_census" aggregate)" \
    -eq 0
assert_num 'owner census cannot masquerade as aggregate verify' \
    "$(common_census_error_count "$synthetic_common_census" aggregate)" \
    -gt 0
assert_num 'aggregate census cannot masquerade as one owner pass' \
    "$(common_census_error_count "$synthetic_aggregate_census" owners)" \
    -gt 0
sed '$d' "$synthetic_aggregate_census" \
    >"$WORK/common-census.aggregate-missing.tsv"
assert_num 'aggregate census rejects one missing diagnostic-adapter link' \
    "$(common_census_error_count \
        "$WORK/common-census.aggregate-missing.tsv" aggregate)" -gt 0

# The row each mutation edits is located by its class, not by a line number.
# Adding the four analysed compile rows above pushed the first link row from
# line 5 to line 9, and the `unknown` mutation went on rewriting `site=` on a
# compile row -- where the model does not read it -- so a mutation that no
# longer reached a link still reported a rejection for every other case and
# only this one turned green.
census_first_line() {
    awk -F '\t' -v wanted="common_class=$2" '
        $2 == wanted { print NR; exit }
    ' "$1"
}

# Both link families, so neither one is covered only by the other's rows.
for census_family in o2 analyzed; do
    case $census_family in
        o2)
            census_object_class=common-object-link
            census_source_class=common-source-link
            ;;
        analyzed)
            census_object_class=common-analyzer-object-link
            census_source_class=common-analyzer-source-link
            ;;
    esac
    census_target=$(
        census_first_line "$synthetic_common_census" "$census_object_class"
    )
    test -n "$census_target" ||
        assert_fail "no $census_object_class row to mutate"
    for census_mutation in missing duplicate unknown source mixed failed argv \
        compiler wall missing-wall
    do
        census_mutant=$WORK/common-census.$census_family.$census_mutation.tsv
        case $census_mutation in
            missing)
                sed "${census_target}d" \
                    "$synthetic_common_census" >"$census_mutant"
                ;;
            duplicate)
                cp "$synthetic_common_census" "$census_mutant"
                sed -n "${census_target}p" \
                    "$synthetic_common_census" >>"$census_mutant"
                ;;
            unknown)
                sed "${census_target}s|site=[^\t]*|site=unknown/site|" \
                    "$synthetic_common_census" >"$census_mutant"
                ;;
            source)
                sed "${census_target}s/$census_object_class/$census_source_class/" \
                    "$synthetic_common_census" >"$census_mutant"
                ;;
            mixed)
                sed "${census_target}s/$census_object_class/mixed-common-source-object/" \
                    "$synthetic_common_census" >"$census_mutant"
                ;;
            failed)
                sed "${census_target}s/status=0/status=1/" \
                    "$synthetic_common_census" >"$census_mutant"
                ;;
            argv)
                sed "${census_target}s/argv_hex=00/argv_hex=not-hex/" \
                    "$synthetic_common_census" >"$census_mutant"
                ;;
            compiler)
                sed "${census_target}s/compiler_sha256=$expected_common_cc_sha256/compiler_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/" \
                    "$synthetic_common_census" >"$census_mutant"
                ;;
            wall)
                sed "${census_target}s/wall_ns=1/wall_ns=not-a-duration/" \
                    "$synthetic_common_census" >"$census_mutant"
                ;;
            missing-wall)
                sed "${census_target}s/\twall_ns=1//" \
                    "$synthetic_common_census" >"$census_mutant"
                ;;
        esac
        cmp -s "$synthetic_common_census" "$census_mutant" &&
            assert_fail \
                "$census_family $census_mutation mutation changed nothing"
        assert_num \
            "$census_family $census_mutation common census mutation is rejected" \
            "$(common_census_error_count "$census_mutant" owners)" -gt 0
    done
done

# The low-level publication helper owns unpredictable temporaries, rejects a
# pre-existing symlink at the content-key path, cleans on signals, and permits
# two equivalent publishers without ever exposing a partial executable.
link_contract=$WORK/link-contract
mkdir -p "$link_contract"
fake_link_cc=$link_contract/fake-link-cc
cat >"$fake_link_cc" <<'FAKE_LINK_CC'
#!/bin/sh
set -eu
output=
while test "$#" -gt 0; do
    case $1 in
        -o)
            shift
            output=$1
            ;;
    esac
    shift
done
test -n "$output"
sleep 1
printf '%s\n' '#!/bin/sh' 'exit 0' >"$output"
chmod 0755 "$output"
FAKE_LINK_CC
chmod 0755 "$fake_link_cc"

concurrent_executable=$link_contract/concurrent-executable
kofun_stage2_semantic_executable_link \
    "$concurrent_executable" "$fake_link_cc" &
concurrent_link_one=$!
kofun_stage2_semantic_executable_link \
    "$concurrent_executable" "$fake_link_cc" &
concurrent_link_two=$!
concurrent_link_one_status=0
concurrent_link_two_status=0
wait "$concurrent_link_one" || concurrent_link_one_status=$?
wait "$concurrent_link_two" || concurrent_link_two_status=$?
assert_num 'first concurrent semantic link status' \
    "$concurrent_link_one_status" -eq 0
assert_num 'second concurrent semantic link status' \
    "$concurrent_link_two_status" -eq 0
assert_executable 'concurrent semantic link publication' \
    "$concurrent_executable"
assert_num 'concurrent semantic link temporary count' \
    "$(find "$link_contract" -maxdepth 1 -type f \
        -name '.concurrent-executable.*' | wc -l | tr -d ' ')" -eq 0

symlink_victim=$link_contract/symlink-victim
symlink_output=$link_contract/symlink-output
printf '%s\n' sentinel >"$symlink_victim"
cp "$symlink_victim" "$link_contract/symlink-victim.before"
ln -s "$symlink_victim" "$symlink_output"
set +e
kofun_stage2_semantic_executable_link \
    "$symlink_output" "$fake_link_cc" \
    >"$link_contract/symlink.stdout" \
    2>"$link_contract/symlink.stderr"
symlink_link_status=$?
set -e
assert_num 'symlinked semantic executable refusal status' \
    "$symlink_link_status" -ne 0
assert_grep 'symlinked semantic executable refusal names cause' \
    -Fq 'cached semantic executable is a symlink' \
    "$link_contract/symlink.stderr"
cmp "$link_contract/symlink-victim.before" "$symlink_victim"

signal_link_cc=$link_contract/signal-link-cc
cat >"$signal_link_cc" <<'SIGNAL_LINK_CC'
#!/bin/sh
set -eu
output=
while test "$#" -gt 0; do
    case $1 in
        -o)
            shift
            output=$1
            ;;
    esac
    shift
done
test -n "$output"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$output"
chmod 0755 "$output"
kill -TERM "$PPID"
SIGNAL_LINK_CC
chmod 0755 "$signal_link_cc"
signal_executable=$link_contract/signal-executable
set +e
kofun_stage2_semantic_executable_link \
    "$signal_executable" "$signal_link_cc"
signal_link_status=$?
set -e
assert_num 'signalled semantic link status' "$signal_link_status" -eq 143
assert_absent 'signalled semantic executable publication' "$signal_executable"
assert_num 'signalled semantic link temporary count' \
    "$(find "$link_contract" -maxdepth 1 -type f \
        -name '.signal-executable.*' | wc -l | tr -d ' ')" -eq 0

self_wrapper_log=$link_contract/self-wrapper.log
self_wrapper_stderr=$link_contract/self-wrapper.stderr
: >"$self_wrapper_log"
set +e
KOFUN_VERIFY_REAL_CC=$wrapper \
KOFUN_VERIFY_CC_LOG=$self_wrapper_log \
    "$wrapper" -c unrelated.c -o "$link_contract/unrelated.o" \
    >"$link_contract/self-wrapper.stdout" 2>"$self_wrapper_stderr"
self_wrapper_status=$?
set -e
assert_num 'recursive compiler wrapper refusal status' \
    "$self_wrapper_status" -eq 2
assert_grep 'recursive compiler wrapper refusal names cause' \
    -Fq 'real compiler resolves to the wrapper itself' "$self_wrapper_stderr"
assert_file_empty 'recursive compiler wrapper writes no census' \
    "$self_wrapper_log"

# Dynamic compiler paths are data, never printf escape programs.  In
# particular a legal literal `\c` path cannot truncate the identity before the
# input digests that distinguish two executables.
backslash_compiler=$link_contract/'cc\c-truncated'
ln -s "$real_cc" "$backslash_compiler"
printf '%s\n' first >"$link_contract/identity-input-first"
printf '%s\n' second >"$link_contract/identity-input-second"
KOFUN_VERIFY_REAL_CC=$backslash_compiler
export KOFUN_VERIFY_REAL_CC
kofun_stage2_semantic_executable_identity "$ROOT" events \
    "$link_contract/identity-input-first" /bin/true /bin/true
backslash_identity_first=$KOFUN_STAGE2_SEMANTIC_EXECUTABLE_ID
kofun_stage2_semantic_executable_identity "$ROOT" events \
    "$link_contract/identity-input-second" /bin/true /bin/true
backslash_identity_second=$KOFUN_STAGE2_SEMANTIC_EXECUTABLE_ID
assert_ne 'backslash compiler path cannot truncate executable inputs' \
    "$backslash_identity_first" "$backslash_identity_second"
KOFUN_VERIFY_REAL_CC=$real_cc
export KOFUN_VERIFY_REAL_CC

wrapper_shape_log=$link_contract/wrapper-shapes.log
: >"$wrapper_shape_log"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" -c \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    -o "$link_contract/path with spaces/semantic-producer-main.o"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" -c \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    "-o$link_contract/path with spaces/semantic-producer-library.o"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -flto -I"$ROOT/bootstrap/stage2" -c \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    -o "$link_contract/semantic-producer-main.o"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" -c \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    "$link_contract/semantic-producer-main.o" \
    -o "$link_contract/mixed-producer"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" -c \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    -o "$link_contract/semantic\c-output.o"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" "$link_contract/semantic-producer-main.o" \
    "$link_contract/semantic-producer-library.o" \
    -o "$link_contract/mixed-object-output"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic -flto \
    -I"$ROOT/bootstrap/stage2" -c \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    -o "$link_contract/semantic-events.o"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic -flto \
    -I"$ROOT/bootstrap/stage2" -c \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$link_contract/sha256.o"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" "$ROOT/bootstrap/stage2/semantic_events.c" \
    "$link_contract/semantic-producer-main.o" \
    -o "$link_contract/mixed-events-object-output"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" "$ROOT/bootstrap/stage2/sha256.c" \
    "$link_contract/semantic-producer-main.o" \
    -o "$link_contract/mixed-sha-object-output"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" "$ROOT/bootstrap/stage2/semantic_events.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$link_contract/source-local-events-tool"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" -std=c11 -fanalyzer -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" -c \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    -o "$link_contract/semantic-events.o"
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$link_contract/source-local-sha-tool"
set +e
KOFUN_VERIFY_REAL_CC=/bin/false \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" -std=c11 -O2 unrelated.c \
    -o "$link_contract/unrelated-negative"
unrelated_negative_status=$?
KOFUN_VERIFY_REAL_CC=/bin/false \
KOFUN_VERIFY_CC_LOG=$wrapper_shape_log \
    "$wrapper" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" -c \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    -o "$link_contract/failed-producer.o"
failed_producer_status=$?
set -e
assert_num 'unrelated negative compiler status' \
    "$unrelated_negative_status" -eq 1
assert_num 'producer compiler failure status' "$failed_producer_status" -eq 1
assert_num 'separated -o main output classification' \
    "$(census_count "$wrapper_shape_log" standard-main)" -eq 1
assert_num 'attached -o library output classification' \
    "$(census_count "$wrapper_shape_log" standard-library)" -eq 1
assert_num 'producer failure classification' \
    "$(census_count "$wrapper_shape_log" failed-producer)" -eq 1
assert_num 'extra flags, mixed source/object, and wrong outputs stay unexpected' \
    "$(census_count "$wrapper_shape_log" unexpected-producer)" -eq 4
assert_num 'all extra or mixed semantic source builds stay unexpected' \
    "$(census_count "$wrapper_shape_log" unexpected-semantic-source)" -eq 8
assert_num 'extra semantic-events build stays unexpected' \
    "$(census_count "$wrapper_shape_log" unexpected-events)" -eq 2
assert_num 'extra SHA-256 build stays unexpected' \
    "$(census_count "$wrapper_shape_log" unexpected-sha)" -eq 2
assert_num 'standalone events link stays source-local and measured' \
    "$(census_count "$wrapper_shape_log" special-events)" -eq 2
assert_num 'unrelated SHA link stays source-local and measured' \
    "$(census_count "$wrapper_shape_log" special-sha)" -eq 1
assert_num 'all mixed semantic object argv stays unexpected' \
    "$(census_count "$wrapper_shape_log" unexpected-object)" -eq 4
assert_num 'mixed main/library roles stay separately visible' \
    "$(census_count "$wrapper_shape_log" mixed-object-roles)" -eq 1
wrapper_shape_diagnostics=$link_contract/wrapper-shapes.diagnostics
census_diagnose "$wrapper_shape_log" unexpected-semantic-source \
    2>"$wrapper_shape_diagnostics"
assert_num 'unexpected semantic diagnostics remain executable and exact' \
    "$(grep -c '^CENSUS unexpected-semantic-source:' \
        "$wrapper_shape_diagnostics")" -eq 8
assert_grep 'backslash output remains literal in the compiler census' \
    -Fq 'output=semantic\c-output.o' "$wrapper_shape_log"
assert_num 'every compiler census mutation remains fully framed' \
    "$(awk -F '\t' 'NF < 23 { bad++ } END { print bad + 0 }' \
        "$wrapper_shape_log")" -eq 0
assert_num 'unrelated failure is absent from semantic census' \
    "$(wc -l <"$wrapper_shape_log" | tr -d ' ')" -eq 14

common_wrapper_log=$link_contract/common-wrapper-shapes.log
: >"$common_wrapper_log"
common_wrapper_base_args='-std=c11 -O2 -Wall -Wextra -Werror -pedantic'
if test "${KOFUN_VERIFY_REAL_CC_PATH+x}" = x; then
    saved_expected_cc_path=$KOFUN_VERIFY_REAL_CC_PATH
    saved_expected_cc_sha256=$KOFUN_VERIFY_REAL_CC_SHA256
    had_expected_cc_identity=1
else
    saved_expected_cc_path=
    saved_expected_cc_sha256=
    had_expected_cc_identity=0
fi
KOFUN_VERIFY_REAL_CC_PATH=$(command -v /bin/true)
true_digest_output=$("$ROOT/bin/kofun-digest" "$KOFUN_VERIFY_REAL_CC_PATH")
KOFUN_VERIFY_REAL_CC_SHA256=${true_digest_output%% *}
export KOFUN_VERIFY_REAL_CC_PATH KOFUN_VERIFY_REAL_CC_SHA256
KOFUN_STAGE2_COMMON_LINK_ID=incremental/graph \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/incremental_graph.c" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/kofun-unicode-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    "$bundle/visibility-access-common-o2.o" \
    -o "$link_contract/kofun-incremental-graph"
KOFUN_STAGE2_COMMON_LINK_ID=incremental/graph \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/incremental_graph.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    -o "$link_contract/kofun-incremental-graph"
KOFUN_STAGE2_COMMON_LINK_ID=incremental/graph \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/incremental_graph.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$bundle/kofun-unicode-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    "$bundle/visibility-access-common-o2.o" \
    -o "$link_contract/kofun-incremental-graph"
KOFUN_STAGE2_COMMON_LINK_ID=incremental/graph \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/incremental_graph.c" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/kofun-unicode-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    -o "$link_contract/kofun-incremental-graph"
KOFUN_STAGE2_COMMON_LINK_ID=unknown/site \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/incremental_graph.c" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/kofun-unicode-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    "$bundle/visibility-access-common-o2.o" \
    -o "$link_contract/kofun-incremental-graph"
KOFUN_STAGE2_COMMON_LINK_ID=kif-v1/tool \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/kif_v1_tool.c" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/kofun-unicode-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    -o "$link_contract/kofun-kif-v1"
KOFUN_STAGE2_COMMON_LINK_ID=incremental/graph \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/incremental_graph.c" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/kofun-unicode-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    "$bundle/visibility-access-common-o2.o" \
    "$bundle/semantic-events.o" \
    -o "$link_contract/kofun-incremental-graph"
KOFUN_STAGE2_COMMON_LINK_ID=incremental/graph \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/incremental_graph.c" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/kofun-unicode-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    "$bundle/visibility-access-common-o2.o" \
    "$bundle/sha256.o" \
    -o "$link_contract/kofun-incremental-graph"
KOFUN_STAGE2_COMMON_LINK_ID=incremental/graph \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/incremental_graph.c" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/kofun-unicode-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    "$bundle/visibility-access-common-o2.o" \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    -o "$link_contract/kofun-incremental-graph"
KOFUN_STAGE2_COMMON_LINK_ID=stage2-kif-producer/producer \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/stage2_kif_producer.c" \
    "$bundle/semantic-producer-library.o" \
    "$bundle/semantic-events.o" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    -o "$link_contract/kofun-stage2-kif"
KOFUN_STAGE2_COMMON_LINK_ID=stage2-kif-producer/producer \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/stage2_kif_producer.c" \
    "$bundle/semantic-events.o" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    -o "$link_contract/kofun-stage2-kif"
KOFUN_STAGE2_COMMON_LINK_ID=stage2-kif-producer/producer \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/stage2_kif_producer.c" \
    "$bundle/semantic-producer-library.o" \
    "$bundle/semantic-producer-library.o" \
    "$bundle/semantic-events.o" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    -o "$link_contract/kofun-stage2-kif"
KOFUN_STAGE2_COMMON_LINK_ID=stage2-kif-producer/producer \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/stage2_kif_producer.c" \
    "$bundle/semantic-producer-library.o" \
    "$bundle/semantic-events.o" \
    "$bundle/semantic-events.o" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    -o "$link_contract/kofun-stage2-kif"
KOFUN_STAGE2_COMMON_LINK_ID=incremental/graph \
KOFUN_VERIFY_REAL_CC=/bin/true \
KOFUN_VERIFY_REAL_CC_PATH=/wrong/compiler \
KOFUN_VERIFY_REAL_CC_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
KOFUN_VERIFY_CC_LOG=$common_wrapper_log \
    "$wrapper" $common_wrapper_base_args \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/incremental_graph.c" \
    "$bundle/kif-v1-common-o2.o" \
    "$bundle/kofun-unicode-common-o2.o" \
    "$bundle/sha256-common-o2.o" \
    "$bundle/visibility-access-common-o2.o" \
    -o "$link_contract/kofun-incremental-graph"
assert_num 'wrapper accepts exact common object links including producer semantic roles' \
    "$(census_count "$common_wrapper_log" common-object-link)" -eq 2
assert_num 'wrapper accepts one exact standalone common source link' \
    "$(census_count "$common_wrapper_log" common-source-link)" -eq 1
assert_num 'wrapper rejects mixes, role drift, semantic extras, and compiler drift' \
    "$(census_count "$common_wrapper_log" unexpected-common)" -eq 11
assert_num 'wrapper common shape mutation count' \
    "$(wc -l <"$common_wrapper_log" | tr -d ' ')" -eq 14
assert_num 'wrapper common rows preserve lossless complete argv' \
    "$(awk -F '\t' '
        {
            delete field
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            if (field["compiler_path_hex"] !~ /^([0-9a-f][0-9a-f])+$/ ||
                field["compiler_sha256"] !~ /^[0-9a-f]+$/ ||
                length(field["compiler_sha256"]) != 64 ||
                field["argc"] !~ /^[1-9][0-9]*$/ ||
                field["argv_hex"] !~ /^([0-9a-f][0-9a-f])+$/ ||
                field["wall_ns"] !~ /^[0-9]+$/) bad++
        }
        END { print bad + 0 }
    ' "$common_wrapper_log")" -eq 0
assert_num 'wrapper records one intentional compiler identity mismatch' \
    "$(awk -F '\t' '
        {
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                if (pair[1] == "compiler_identity" && pair[2] == "mismatch")
                    count++
            }
        }
        END { print count + 0 }
    ' "$common_wrapper_log")" -eq 1
assert_num 'producer site binds exact library and event semantic objects' \
    "$(awk -F '\t' '
        {
            delete field
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            if (field["site"] == "stage2-kif-producer/producer" &&
                field["common_class"] == "common-object-link" &&
                field["main_object_count"] == 0 &&
                field["library_object_count"] == 1 &&
                field["events_object_count"] == 1 &&
                field["semantic_sha_object_count"] == 0) count++
        }
        END { print count + 0 }
    ' "$common_wrapper_log")" -eq 1
if test "$had_expected_cc_identity" -eq 1; then
    KOFUN_VERIFY_REAL_CC_PATH=$saved_expected_cc_path
    KOFUN_VERIFY_REAL_CC_SHA256=$saved_expected_cc_sha256
    export KOFUN_VERIFY_REAL_CC_PATH KOFUN_VERIFY_REAL_CC_SHA256
else
    unset KOFUN_VERIFY_REAL_CC_PATH KOFUN_VERIFY_REAL_CC_SHA256
fi

assert_mode() {
    mode=$(kofun_stage2_semantic_mode "$2") ||
        assert_fail "$1: cannot inspect $2"
    case $mode in
        "$3"*) ;;
        *) assert_fail "$1: expected $3, got $mode" ;;
    esac
}

# Replacing the owned root with a symlink must unlink that entry without
# chmodding or traversing its target.  The victim mode check remains meaningful
# under uid 0 because it inspects permission bits, not effective access.
cleanup_victim=$link_contract/cleanup-victim
cleanup_owned=$link_contract/cleanup-owned
mkdir "$cleanup_victim" "$cleanup_owned"
printf '%s\n' sentinel >"$cleanup_victim/sentinel"
chmod 0555 "$cleanup_victim"
rmdir "$cleanup_owned"
ln -s "$cleanup_victim" "$cleanup_owned"
kofun_stage2_owned_tree_remove "$cleanup_owned"
assert_absent 'owned cleanup replacement symlink' "$cleanup_owned"
assert_mode 'owned cleanup preserves victim mode' \
    "$cleanup_victim" dr-xr-xr-x
assert_grep 'owned cleanup preserves victim bytes' \
    -Fxq sentinel "$cleanup_victim/sentinel"
chmod 0755 "$cleanup_victim"

# The four `-common-analyzer.o` members are #1449's `-O0 -fanalyzer` family.
# Naming each one here rather than only counting them is what makes a missing
# member a named failure instead of an arithmetic one.
for member in semantic-producer-main.o semantic-producer-library.o \
    semantic-events.o sha256.o kif-v1-common-o2.o \
    kofun-unicode-common-o2.o sha256-common-o2.o \
    visibility-access-common-o2.o kif-v1-common-analyzer.o \
    kofun-unicode-common-analyzer.o sha256-common-analyzer.o \
    visibility-access-common-analyzer.o complete-v2 manifest-v2.tsv
do
    assert_regular_file "published $member" "$bundle/$member"
    assert_mode "published $member mode" "$bundle/$member" -r--r--r--
done
assert_mode 'published bundle directory mode' "$bundle" dr-xr-xr-x
assert_num 'published semantic v2 closed member count' \
    "$(find "$bundle" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" \
    -eq 14
assert_num 'semantic v2 manifest schema row count' \
    "$(awk -F '\t' '$1 == "schema" { n++ } END { print n + 0 }' \
        "$bundle/manifest-v2.tsv")" -eq 1
assert_num 'semantic v2 manifest trust row count' \
    "$(awk -F '\t' '$1 == "trust" { n++ } END { print n + 0 }' \
        "$bundle/manifest-v2.tsv")" -eq 1
# 8 -> 12 profiles, 48 -> 62 inputs, 8 -> 12 members: #1449's four
# `-O0 -fanalyzer` roles. Each carries its own normalized argv, its own source
# and header closure, and its own member digest, so the family is provenanced
# exactly like the `-O2` one rather than riding on it.
assert_num 'semantic v2 manifest profile row count' \
    "$(awk -F '\t' '$1 == "profile" { n++ } END { print n + 0 }' \
        "$bundle/manifest-v2.tsv")" -eq 12
assert_num 'semantic v2 manifest input row count' \
    "$(awk -F '\t' '$1 == "input" { n++ } END { print n + 0 }' \
        "$bundle/manifest-v2.tsv")" -eq 62
assert_num 'semantic v2 manifest member row count' \
    "$(awk -F '\t' '$1 == "member" { n++ } END { print n + 0 }' \
        "$bundle/manifest-v2.tsv")" -eq 12
assert_num 'semantic v2 manifest marker row count' \
    "$(awk -F '\t' '$1 == "marker" { n++ } END { print n + 0 }' \
        "$bundle/manifest-v2.tsv")" -eq 1
assert_num 'semantic v2 canonical manifest row count' \
    "$(wc -l <"$bundle/manifest-v2.tsv" | tr -d ' ')" -eq 91
awk 'BEGIN {
    print "schema"
    print "trust"
    print "compiler-path"
    print "compiler-sha256"
    for (i = 0; i < 12; i++) print "profile"
    for (i = 0; i < 62; i++) print "input"
    for (i = 0; i < 12; i++) print "member"
    print "marker"
}' >"$WORK/manifest-keys.expected"
cut -f1 "$bundle/manifest-v2.tsv" >"$WORK/manifest-keys.actual"
cmp "$WORK/manifest-keys.expected" "$WORK/manifest-keys.actual"
assert_grep 'semantic v2 exact schema row' -Fxq \
    'schema	kofun.stage2-semantic-object-manifest/v2' \
    "$bundle/manifest-v2.tsv"
assert_grep 'semantic v2 exact trust boundary row' -Fxq \
    'trust	helper-produced-drift-detection-not-authentication' \
    "$bundle/manifest-v2.tsv"
assert_eq 'manifest compiler path matches runner expected compiler' \
    "$(awk -F '\t' '$1 == "compiler-path" { print $2 }' \
        "$bundle/manifest-v2.tsv")" "$expected_common_cc_path"
assert_eq 'manifest compiler digest matches runner expected compiler' \
    "$(awk -F '\t' '$1 == "compiler-sha256" { print $2 }' \
        "$bundle/manifest-v2.tsv")" "$expected_common_cc_sha256"
printf '%s\n' \
    'producer-main	-std=c11|-O2|-g|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|-c|bootstrap/stage2/semantic_producer.c|-o|semantic-producer-main.o' \
    'producer-library	-std=c11|-O2|-g|-Wall|-Wextra|-Werror|-pedantic|-DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY|-Ibootstrap/stage2|-c|bootstrap/stage2/semantic_producer.c|-o|semantic-producer-library.o' \
    'semantic-events	-std=c11|-O2|-g|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|-c|bootstrap/stage2/semantic_events.c|-o|semantic-events.o' \
    'sha256	-std=c11|-O2|-g|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|-c|bootstrap/stage2/sha256.c|-o|sha256.o' \
    'common-kif-v1-o2	-std=c11|-O2|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|-c|bootstrap/stage2/kif_v1.c|-o|kif-v1-common-o2.o' \
    'common-unicode-o2	-std=c11|-O2|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|-c|unicode/kofun_unicode.c|-o|kofun-unicode-common-o2.o' \
    'common-sha256-o2	-std=c11|-O2|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|-c|bootstrap/stage2/sha256.c|-o|sha256-common-o2.o' \
    'common-visibility-o2	-std=c11|-O2|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|-c|bootstrap/stage2/visibility_access.c|-o|visibility-access-common-o2.o' \
    'common-kif-v1-analyzer	-std=c11|-O0|-Wall|-Wextra|-Werror|-pedantic|-fanalyzer|-Ibootstrap/stage2|-c|bootstrap/stage2/kif_v1.c|-o|kif-v1-common-analyzer.o' \
    'common-unicode-analyzer	-std=c11|-O0|-Wall|-Wextra|-Werror|-pedantic|-fanalyzer|-Ibootstrap/stage2|-c|unicode/kofun_unicode.c|-o|kofun-unicode-common-analyzer.o' \
    'common-sha256-analyzer	-std=c11|-O0|-Wall|-Wextra|-Werror|-pedantic|-fanalyzer|-Ibootstrap/stage2|-c|bootstrap/stage2/sha256.c|-o|sha256-common-analyzer.o' \
    'common-visibility-analyzer	-std=c11|-O0|-Wall|-Wextra|-Werror|-pedantic|-fanalyzer|-Ibootstrap/stage2|-c|bootstrap/stage2/visibility_access.c|-o|visibility-access-common-analyzer.o' \
    >"$WORK/manifest-profiles.expected"
awk -F '\t' '$1 == "profile" { print $2 "\t" $3 }' \
    "$bundle/manifest-v2.tsv" >"$WORK/manifest-profiles.actual"
cmp "$WORK/manifest-profiles.expected" "$WORK/manifest-profiles.actual"
printf '%s\n' \
    'producer-main	semantic-producer-main.o	bootstrap/stage2/semantic_producer.c	producer-main' \
    'producer-library	semantic-producer-library.o	bootstrap/stage2/semantic_producer.c	producer-library' \
    'semantic-events	semantic-events.o	bootstrap/stage2/semantic_events.c	semantic-events' \
    'sha256	sha256.o	bootstrap/stage2/sha256.c	sha256' \
    'common-kif-v1-o2	kif-v1-common-o2.o	bootstrap/stage2/kif_v1.c	common-kif-v1-o2' \
    'common-unicode-o2	kofun-unicode-common-o2.o	unicode/kofun_unicode.c	common-unicode-o2' \
    'common-sha256-o2	sha256-common-o2.o	bootstrap/stage2/sha256.c	common-sha256-o2' \
    'common-visibility-o2	visibility-access-common-o2.o	bootstrap/stage2/visibility_access.c	common-visibility-o2' \
    'common-kif-v1-analyzer	kif-v1-common-analyzer.o	bootstrap/stage2/kif_v1.c	common-kif-v1-analyzer' \
    'common-unicode-analyzer	kofun-unicode-common-analyzer.o	unicode/kofun_unicode.c	common-unicode-analyzer' \
    'common-sha256-analyzer	sha256-common-analyzer.o	bootstrap/stage2/sha256.c	common-sha256-analyzer' \
    'common-visibility-analyzer	visibility-access-common-analyzer.o	bootstrap/stage2/visibility_access.c	common-visibility-analyzer' \
    >"$WORK/manifest-members.expected"
awk -F '\t' '$1 == "member" {
    print $2 "\t" $3 "\t" $4 "\t" $7
}' "$bundle/manifest-v2.tsv" >"$WORK/manifest-members.actual"
cmp "$WORK/manifest-members.expected" "$WORK/manifest-members.actual"
kofun_stage2_semantic_roles >"$WORK/manifest-roles.expected"
awk -F '\t' '$1 == "profile" { print $2 }' "$bundle/manifest-v2.tsv" \
    >"$WORK/manifest-profile-roles.actual"
awk -F '\t' '$1 == "member" { print $2 }' "$bundle/manifest-v2.tsv" \
    >"$WORK/manifest-member-roles.actual"
cmp "$WORK/manifest-roles.expected" "$WORK/manifest-profile-roles.actual"
cmp "$WORK/manifest-roles.expected" "$WORK/manifest-member-roles.actual"
: >"$WORK/manifest-inputs.expected"
while IFS= read -r manifest_role; do
    cat "$WORK/$manifest_role-source-closure.actual" |
    while IFS= read -r manifest_input; do
        printf '%s\t%s\n' "$manifest_role" "$manifest_input"
    done >>"$WORK/manifest-inputs.expected"
done <"$WORK/manifest-roles.expected"
awk -F '\t' '$1 == "input" { print $2 "\t" $3 }' \
    "$bundle/manifest-v2.tsv" >"$WORK/manifest-inputs.actual"
cmp "$WORK/manifest-inputs.expected" "$WORK/manifest-inputs.actual"

manifest_digest_of() {
    manifest_digest_output=$("$ROOT/bin/kofun-digest" "$1")
    printf '%s\n' "${manifest_digest_output%% *}"
}
while IFS='	' read -r manifest_key manifest_role manifest_path \
    manifest_digest
do
    assert_eq "manifest input digest $manifest_role:$manifest_path" \
        "$manifest_digest" "$(manifest_digest_of "$ROOT/$manifest_path")"
done <<EOF_MANIFEST_INPUT_DIGESTS
$(awk -F '\t' '$1 == "input" { print $1 "\t" $2 "\t" $3 "\t" $4 }' \
    "$bundle/manifest-v2.tsv")
EOF_MANIFEST_INPUT_DIGESTS
while IFS='	' read -r manifest_key manifest_role manifest_member \
    manifest_source manifest_source_digest manifest_member_digest \
    manifest_profile
do
    assert_eq "manifest primary digest $manifest_role" \
        "$manifest_source_digest" \
        "$(manifest_digest_of "$ROOT/$manifest_source")"
    assert_eq "manifest member digest $manifest_role" \
        "$manifest_member_digest" \
        "$(manifest_digest_of "$bundle/$manifest_member")"
done <<EOF_MANIFEST_MEMBER_DIGESTS
$(awk -F '\t' '$1 == "member" { print }' "$bundle/manifest-v2.tsv")
EOF_MANIFEST_MEMBER_DIGESTS
assert_eq 'manifest marker digest' \
    "$(awk -F '\t' '$1 == "marker" { print $3 }' \
        "$bundle/manifest-v2.tsv")" \
    "$(manifest_digest_of "$bundle/complete-v2")"

capture() {
    capture_label=$1
    capture_binary=$2
    shift 2
    set +e
    "$capture_binary" "$@" \
        >"$WORK/$capture_label.stdout" \
        2>"$WORK/$capture_label.stderr"
    capture_status=$?
    set -e
    printf '%s\n' "$capture_status" >"$WORK/$capture_label.status"
}

# This differential always runs, including inside `task verify`.  It delegates
# directly to KOFUN_VERIFY_REAL_CC, so its two explicit source baselines are
# separately measured and cannot inflate or hide the runner-standard census.
source_log=$WORK/source-build.log
object_log=$WORK/object-link.log
: >"$source_log"
: >"$object_log"

KOFUN_VERIFY_CC_LOG=$source_log "$wrapper" \
    -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/source-main"
KOFUN_VERIFY_CC_LOG=$source_log "$wrapper" \
    -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/stage2_kif_producer.c" \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/source-library"

KOFUN_VERIFY_CC_LOG=$object_log "$wrapper" \
    -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$bundle/semantic-producer-main.o" \
    "$bundle/semantic-events.o" \
    "$bundle/sha256.o" \
    -o "$WORK/object-main"
KOFUN_VERIFY_CC_LOG=$object_log "$wrapper" \
    -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/stage2_kif_producer.c" \
    "$bundle/semantic-producer-library.o" \
    "$bundle/semantic-events.o" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$bundle/sha256.o" \
    -o "$WORK/object-library"

fixture=$ROOT/tests/typed-sidecar/fixtures/stage2_events.kofun
capture source-main-ok "$WORK/source-main" \
    "$fixture" src/main.kofun "$WORK/source-main-ok.kse" 41
capture object-main-ok "$WORK/object-main" \
    "$fixture" src/main.kofun "$WORK/object-main-ok.kse" 41
assert_num 'source-path main success status' \
    "$(cat "$WORK/source-main-ok.status")" -eq 0
cmp "$WORK/source-main-ok.status" "$WORK/object-main-ok.status"
cmp "$WORK/source-main-ok.stdout" "$WORK/object-main-ok.stdout"
cmp "$WORK/source-main-ok.stderr" "$WORK/object-main-ok.stderr"
cmp "$WORK/source-main-ok.kse" "$WORK/object-main-ok.kse"

failed=$ROOT/bootstrap/stage2/function_unknown_error.kofun
capture source-main-failed "$WORK/source-main" \
    "$failed" src/failed.kofun "$WORK/source-main-failed.kse" 42
capture object-main-failed "$WORK/object-main" \
    "$failed" src/failed.kofun "$WORK/object-main-failed.kse" 42
assert_num 'source-path diagnostic status' \
    "$(cat "$WORK/source-main-failed.status")" -eq 1
cmp "$WORK/source-main-failed.status" "$WORK/object-main-failed.status"
cmp "$WORK/source-main-failed.stdout" "$WORK/object-main-failed.stdout"
cmp "$WORK/source-main-failed.stderr" "$WORK/object-main-failed.stderr"
cmp "$WORK/source-main-failed.kse" "$WORK/object-main-failed.kse"

interface=$ROOT/tests/conformance/modules/stage2-kif-producer/fixtures/interface.kofun
capture source-library "$WORK/source-library" \
    "$interface" demo/api.kofun "$WORK/source-library.kif" 2026
capture object-library "$WORK/object-library" \
    "$interface" demo/api.kofun "$WORK/object-library.kif" 2026
assert_num 'source-path library success status' \
    "$(cat "$WORK/source-library.status")" -eq 0
cmp "$WORK/source-library.status" "$WORK/object-library.status"
cmp "$WORK/source-library.stdout" "$WORK/object-library.stdout"
cmp "$WORK/source-library.stderr" "$WORK/object-library.stderr"
cmp "$WORK/source-library.kif" "$WORK/object-library.kif"

source_compile_count=$(census_count "$source_log" producer-source)
object_compile_count=$(census_count "$object_log" producer-source)
assert_num 'representative source producer compile count' \
    "$source_compile_count" -eq 2
assert_num 'representative object producer compile count' \
    "$object_compile_count" -eq 0
assert_num 'representative object producer link count' \
    "$(census_count "$object_log" producer-object)" -eq 2
source_wall_ns=$(census_wall_ns "$source_log" all)
object_wall_ns=$(census_wall_ns "$object_log" all)

printf '%s\n' \
    "MEASURE: bundle producer_compiles=2 compiler_wall_ns=$bundle_wall_ns" \
    "MEASURE: common bundle compiles=4 compiler_wall_ns=$common_bundle_wall_ns selected_object_link_wall_ns=$common_object_link_wall_ns" \
    'MEASURE: audited direct-owner common source baseline links=19 KIF=18 Unicode=15 no-g-SHA256=16 visibility=3 total=52' \
    'MEASURE: audited aggregate-verify common source baseline links=24 KIF=22 Unicode=19 no-g-SHA256=21 visibility=4 total=66; shared compile count=4' \
    "MEASURE: source paths producer_compiles=$source_compile_count compiler_wall_ns=$source_wall_ns" \
    "MEASURE: object paths producer_compiles=$object_compile_count compiler_wall_ns=$object_wall_ns" \
    'PASS: main events, diagnostics, and library KIF are byte-identical through source and object paths'

# Exercise one complete owner in both selector states.  The gate itself pins
# canonical KIF bytes, HIR, diagnostics, exit status, and failed-publication
# preservation; the comparisons below make those assertions cross-mode.
common_kif_source_work=$WORK/kif-v1.source
common_kif_object_work=$WORK/kif-v1.object
common_kif_source_log=$WORK/kif-v1.source.census.tsv
common_kif_object_log=$WORK/kif-v1.object.census.tsv
: >"$common_kif_source_log"
: >"$common_kif_object_log"
(
    unset KOFUN_STAGE2_SEMANTIC_OBJECT_DIR
    KOFUN_VERIFY_CC_LOG=$common_kif_source_log \
    KOFUN_KIF_V1_WORK=$common_kif_source_work \
    CC=$wrapper \
        sh "$ROOT/tests/conformance/modules/kif-v1/run.sh"
) >"$WORK/kif-v1.source.stdout" 2>"$WORK/kif-v1.source.stderr"
KOFUN_VERIFY_CC_LOG=$common_kif_object_log \
KOFUN_STAGE2_SEMANTIC_OBJECT_DIR=$bundle \
KOFUN_KIF_V1_WORK=$common_kif_object_work \
CC=$wrapper \
    sh "$ROOT/tests/conformance/modules/kif-v1/run.sh" \
    >"$WORK/kif-v1.object.stdout" 2>"$WORK/kif-v1.object.stderr"
cmp "$WORK/kif-v1.source.stdout" "$WORK/kif-v1.object.stdout"
cmp "$WORK/kif-v1.source.stderr" "$WORK/kif-v1.object.stderr"
for common_kif_result in \
    interface.kif \
    interface.json \
    source-free.hir \
    export-interface.kif \
    export-interface.json \
    export-external.hir \
    export-same-package.hir \
    module-export-call.log \
    preserved-resolution.hir \
    interrupted-resolution.log \
    unsupported.log
do
    cmp "$common_kif_source_work/$common_kif_result" \
        "$common_kif_object_work/$common_kif_result"
done
assert_num 'complete KIF owner standalone source-link count' \
    "$(census_count "$common_kif_source_log" common-source-link)" -eq 2
assert_num 'complete KIF owner shared object-link count' \
    "$(census_count "$common_kif_object_log" common-object-link)" -eq 2
# The analysed arm, in both selector states (#1449). Asserted in both
# directions: without the bundle it must still compile its own sources, or
# the standalone path has silently stopped analysing anything.
assert_num 'complete KIF owner standalone analysed source-link count' \
    "$(census_count "$common_kif_source_log" common-analyzer-source-link)" \
    -eq 1
assert_num 'complete KIF owner shared analysed object-link count' \
    "$(census_count "$common_kif_object_log" common-analyzer-object-link)" \
    -eq 1
assert_num 'complete KIF owner has no analysed link in the wrong state' \
    "$((
        $(census_count "$common_kif_source_log" common-analyzer-object-link) +
        $(census_count "$common_kif_object_log" common-analyzer-source-link)
    ))" -eq 0
assert_num 'complete KIF owner has no malformed common rows' \
    "$((
        $(census_count "$common_kif_source_log" unexpected-common) +
        $(census_count "$common_kif_object_log" unexpected-common)
    ))" -eq 0
printf '%s\n' \
    "MEASURE: KIF owner source_link_wall_ns=$(census_wall_ns "$common_kif_source_log" common-source-link)" \
    "MEASURE: KIF owner object_link_wall_ns=$(census_wall_ns "$common_kif_object_log" common-object-link)" \
    'PASS: common timing reports compiler/link process wall only, not whole-suite wall savings'

copy_bundle() {
    copy_target=$1
    cp -R "$bundle" "$copy_target"
    chmod u+w "$copy_target"
}

seal_bundle() {
    chmod 0555 "$1"
}

rewrite_bundle_manifest() {
    rewrite_bundle=$1
    rewrite_manifest=$rewrite_bundle/.manifest-v2.tsv.new
    kofun_stage2_semantic_manifest_write "$ROOT" "$rewrite_bundle" \
        >"$rewrite_manifest"
    chmod 0444 "$rewrite_manifest"
    mv -f "$rewrite_manifest" "$rewrite_bundle/manifest-v2.tsv"
}

expect_refusal() {
    refusal_label=$1
    refusal_bundle=$2
    refusal_text=$3
    refusal_log=$WORK/refusal-$refusal_label.cc.log
    : >"$refusal_log"
    set +e
    KOFUN_VERIFY_CC_LOG="$refusal_log" \
    KOFUN_STAGE2_SEMANTIC_OBJECT_DIR="$refusal_bundle" \
    CC="$wrapper" \
    KOFUN_KIF_V1_WORK="$WORK/kif-v1.$refusal_label" \
        sh "$ROOT/tests/conformance/modules/kif-v1/run.sh" \
        >"$WORK/refusal-$refusal_label.stdout" \
        2>"$WORK/refusal-$refusal_label.stderr"
    refusal_status=$?
    set -e
    assert_num "$refusal_label refusal status" "$refusal_status" -ne 0
    assert_file_empty "$refusal_label compiler log" "$refusal_log"
    assert_grep "$refusal_label names its refusal" \
        -Fq "$refusal_text" "$WORK/refusal-$refusal_label.stderr"
}

expect_refusal empty '' \
    'KOFUN_STAGE2_SEMANTIC_OBJECT_DIR is set but empty'
expect_refusal missing "$WORK/missing-bundle" \
    'object bundle is not a directory'

bundle_root_symlink=$WORK/bundle-root-symlink
ln -s "$bundle" "$bundle_root_symlink"
expect_refusal bundle-root-symlink "$bundle_root_symlink" \
    'object bundle is not a directory'

partial=$WORK/partial-bundle
copy_bundle "$partial"
rm -f -- "$partial/semantic-producer-library.o"
seal_bundle "$partial"
expect_refusal partial "$partial" \
    'bundle member is missing: semantic-producer-library.o'

partial_common=$WORK/partial-common-bundle
copy_bundle "$partial_common"
rm -f -- "$partial_common/kif-v1-common-o2.o"
seal_bundle "$partial_common"
expect_refusal partial-common "$partial_common" \
    'bundle member is missing: kif-v1-common-o2.o'

extra_member=$WORK/extra-member-bundle
copy_bundle "$extra_member"
printf '%s\n' unexpected >"$extra_member/unexpected.o"
chmod 0444 "$extra_member/unexpected.o"
seal_bundle "$extra_member"
expect_refusal extra-member "$extra_member" \
    'object bundle must contain exactly fourteen members, found 15'

legacy_v1=$WORK/legacy-v1-bundle
copy_bundle "$legacy_v1"
mv "$legacy_v1/complete-v2" "$legacy_v1/complete-v1"
mv "$legacy_v1/manifest-v2.tsv" "$legacy_v1/manifest-v1.tsv"
seal_bundle "$legacy_v1"
expect_refusal legacy-v1 "$legacy_v1" \
    'semantic object bundle version v1 is unsupported; expected v2'

nonregular=$WORK/nonregular-bundle
copy_bundle "$nonregular"
rm -f -- "$nonregular/semantic-producer-main.o"
mkdir "$nonregular/semantic-producer-main.o"
seal_bundle "$nonregular"
expect_refusal nonregular "$nonregular" \
    'bundle member is not a regular file: semantic-producer-main.o'

member_symlink=$WORK/member-symlink-bundle
copy_bundle "$member_symlink"
rm -f -- "$member_symlink/kif-v1-common-o2.o"
ln -s "$bundle/kif-v1-common-o2.o" \
    "$member_symlink/kif-v1-common-o2.o"
seal_bundle "$member_symlink"
expect_refusal member-symlink "$member_symlink" \
    'bundle member is not a regular file: kif-v1-common-o2.o'

unreadable=$WORK/unreadable-bundle
copy_bundle "$unreadable"
chmod 000 "$unreadable/semantic-producer-main.o"
seal_bundle "$unreadable"
expect_refusal unreadable "$unreadable" \
    'bundle member is not readable: semantic-producer-main.o'

mutable_member=$WORK/mutable-member-bundle
copy_bundle "$mutable_member"
chmod u+w "$mutable_member/semantic-producer-main.o"
seal_bundle "$mutable_member"
expect_refusal mutable-member "$mutable_member" \
    'bundle member is mutable: semantic-producer-main.o'

mutable=$WORK/mutable-bundle
copy_bundle "$mutable"
expect_refusal mutable "$mutable" \
    'object bundle directory is mutable'

wrong_marker=$WORK/wrong-marker-bundle
copy_bundle "$wrong_marker"
chmod u+w "$wrong_marker/complete-v2"
printf '%s\n' 'kofun.stage2-semantic-objects/v2' extra \
    >"$wrong_marker/complete-v2"
chmod 0444 "$wrong_marker/complete-v2"
seal_bundle "$wrong_marker"
expect_refusal marker "$wrong_marker" \
    'bundle member has the wrong profile marker: complete-v2'

missing_manifest=$WORK/missing-manifest-bundle
copy_bundle "$missing_manifest"
rm -f -- "$missing_manifest/manifest-v2.tsv"
seal_bundle "$missing_manifest"
expect_refusal missing-manifest "$missing_manifest" \
    'bundle member is missing: manifest-v2.tsv'

extra_manifest=$WORK/extra-manifest-bundle
copy_bundle "$extra_manifest"
chmod u+w "$extra_manifest/manifest-v2.tsv"
printf '%s\n' 'unknown\textra' >>"$extra_manifest/manifest-v2.tsv"
chmod 0444 "$extra_manifest/manifest-v2.tsv"
seal_bundle "$extra_manifest"
expect_refusal extra-manifest "$extra_manifest" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

duplicate_manifest=$WORK/duplicate-manifest-bundle
copy_bundle "$duplicate_manifest"
chmod u+w "$duplicate_manifest/manifest-v2.tsv"
sed -n '1p' "$duplicate_manifest/manifest-v2.tsv" \
    >>"$duplicate_manifest/manifest-v2.tsv"
chmod 0444 "$duplicate_manifest/manifest-v2.tsv"
seal_bundle "$duplicate_manifest"
expect_refusal duplicate-manifest "$duplicate_manifest" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

malformed_manifest=$WORK/malformed-manifest-bundle
copy_bundle "$malformed_manifest"
chmod u+w "$malformed_manifest/manifest-v2.tsv"
sed '1s/\t//' "$malformed_manifest/manifest-v2.tsv" \
    >"$malformed_manifest/.manifest-v2.tsv.new"
chmod 0444 "$malformed_manifest/.manifest-v2.tsv.new"
mv -f "$malformed_manifest/.manifest-v2.tsv.new" \
    "$malformed_manifest/manifest-v2.tsv"
seal_bundle "$malformed_manifest"
expect_refusal malformed-manifest "$malformed_manifest" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

for compiler_manifest_kind in path digest; do
    compiler_manifest=$WORK/compiler-$compiler_manifest_kind-manifest-bundle
    copy_bundle "$compiler_manifest"
    chmod u+w "$compiler_manifest/manifest-v2.tsv"
    case $compiler_manifest_kind in
        path)
            sed 's#^compiler-path\t.*#compiler-path\t/not/the/resolved/compiler#' \
                "$compiler_manifest/manifest-v2.tsv" \
                >"$compiler_manifest/.manifest-v2.tsv.new"
            ;;
        digest)
            sed 's/^compiler-sha256\t.*/compiler-sha256\t0000000000000000000000000000000000000000000000000000000000000000/' \
                "$compiler_manifest/manifest-v2.tsv" \
                >"$compiler_manifest/.manifest-v2.tsv.new"
            ;;
    esac
    chmod 0444 "$compiler_manifest/.manifest-v2.tsv.new"
    mv -f "$compiler_manifest/.manifest-v2.tsv.new" \
        "$compiler_manifest/manifest-v2.tsv"
    seal_bundle "$compiler_manifest"
    expect_refusal "compiler-$compiler_manifest_kind-manifest" \
        "$compiler_manifest" \
        'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'
done

while IFS= read -r input_manifest_role; do
    input_manifest=$WORK/input-$input_manifest_role-manifest-bundle
    copy_bundle "$input_manifest"
    chmod u+w "$input_manifest/manifest-v2.tsv"
    awk -F '\t' -v OFS='\t' -v role="$input_manifest_role" '
        $1 == "input" && $2 == role && !changed {
            $4 = "0000000000000000000000000000000000000000000000000000000000000000"
            changed = 1
        }
        { print }
        END { if (!changed) exit 1 }
    ' "$input_manifest/manifest-v2.tsv" \
        >"$input_manifest/.manifest-v2.tsv.new"
    chmod 0444 "$input_manifest/.manifest-v2.tsv.new"
    mv -f "$input_manifest/.manifest-v2.tsv.new" \
        "$input_manifest/manifest-v2.tsv"
    seal_bundle "$input_manifest"
    expect_refusal "input-$input_manifest_role-manifest" \
        "$input_manifest" \
        'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'
done <"$WORK/manifest-roles.expected"

# The per-role mutation above covers each primary source.  These independent
# rows hold the rest of the physical dependency contract: headers and the
# generated Unicode table must be provenance inputs too, not merely whatever
# the implementation happens to enumerate first.
while IFS='|' read -r input_manifest_label input_manifest_role \
    input_manifest_path
do
    input_manifest=$WORK/input-$input_manifest_label-manifest-bundle
    copy_bundle "$input_manifest"
    chmod u+w "$input_manifest/manifest-v2.tsv"
    awk -F '\t' -v OFS='\t' -v role="$input_manifest_role" \
        -v path="$input_manifest_path" '
        $1 == "input" && $2 == role && $3 == path && !changed {
            $4 = "0000000000000000000000000000000000000000000000000000000000000000"
            changed = 1
        }
        { print }
        END { if (!changed) exit 1 }
    ' "$input_manifest/manifest-v2.tsv" \
        >"$input_manifest/.manifest-v2.tsv.new"
    chmod 0444 "$input_manifest/.manifest-v2.tsv.new"
    mv -f "$input_manifest/.manifest-v2.tsv.new" \
        "$input_manifest/manifest-v2.tsv"
    seal_bundle "$input_manifest"
    expect_refusal "input-$input_manifest_label-manifest" \
        "$input_manifest" \
        'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'
done <<'EOF_NONPRIMARY_INPUT_MUTATIONS'
kif-header|common-kif-v1-o2|bootstrap/stage2/kif_v1.h
unicode-table|common-unicode-o2|unicode/kofun_unicode_tables.inc
sha-header|common-sha256-o2|bootstrap/stage2/sha256.h
visibility-header|common-visibility-o2|bootstrap/stage2/visibility_access.h
EOF_NONPRIMARY_INPUT_MUTATIONS

profile_manifest=$WORK/profile-manifest-bundle
copy_bundle "$profile_manifest"
chmod u+w "$profile_manifest/manifest-v2.tsv"
sed 's/-std=c11|-O2|-g/-std=c11|-O0|-g/' \
    "$profile_manifest/manifest-v2.tsv" \
    >"$profile_manifest/.manifest-v2.tsv.new"
chmod 0444 "$profile_manifest/.manifest-v2.tsv.new"
mv -f "$profile_manifest/.manifest-v2.tsv.new" \
    "$profile_manifest/manifest-v2.tsv"
seal_bundle "$profile_manifest"
expect_refusal profile-manifest "$profile_manifest" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

common_profile_manifest=$WORK/common-profile-manifest-bundle
copy_bundle "$common_profile_manifest"
chmod u+w "$common_profile_manifest/manifest-v2.tsv"
sed '/^profile\tcommon-kif-v1-o2\t/s/|-Wall/|-g|-Wall/' \
    "$common_profile_manifest/manifest-v2.tsv" \
    >"$common_profile_manifest/.manifest-v2.tsv.new"
chmod 0444 "$common_profile_manifest/.manifest-v2.tsv.new"
mv -f "$common_profile_manifest/.manifest-v2.tsv.new" \
    "$common_profile_manifest/manifest-v2.tsv"
seal_bundle "$common_profile_manifest"
expect_refusal common-profile-manifest "$common_profile_manifest" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

o0_bundle=$WORK/o0-bundle
copy_bundle "$o0_bundle"
rm -f -- "$o0_bundle/semantic-producer-main.o"
"$real_cc" -std=c11 -O0 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    -c "$ROOT/bootstrap/stage2/semantic_producer.c" \
    -o "$o0_bundle/semantic-producer-main.o"
chmod 0444 "$o0_bundle/semantic-producer-main.o"
seal_bundle "$o0_bundle"
expect_refusal o0-profile "$o0_bundle" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

swapped_bundle=$WORK/swapped-bundle
copy_bundle "$swapped_bundle"
chmod u+w "$swapped_bundle/semantic-producer-main.o" \
    "$swapped_bundle/semantic-producer-library.o"
cp "$swapped_bundle/semantic-producer-main.o" \
    "$swapped_bundle/.semantic-producer-main.o.saved"
cp "$swapped_bundle/semantic-producer-library.o" \
    "$swapped_bundle/semantic-producer-main.o"
cp "$swapped_bundle/.semantic-producer-main.o.saved" \
    "$swapped_bundle/semantic-producer-library.o"
rm -f -- "$swapped_bundle/.semantic-producer-main.o.saved"
chmod 0444 "$swapped_bundle/semantic-producer-main.o" \
    "$swapped_bundle/semantic-producer-library.o"
seal_bundle "$swapped_bundle"
expect_refusal swapped-role "$swapped_bundle" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

swapped_common_bundle=$WORK/swapped-common-bundle
copy_bundle "$swapped_common_bundle"
chmod u+w "$swapped_common_bundle/kif-v1-common-o2.o" \
    "$swapped_common_bundle/kofun-unicode-common-o2.o"
cp "$swapped_common_bundle/kif-v1-common-o2.o" \
    "$swapped_common_bundle/.kif-v1-common-o2.o.saved"
cp "$swapped_common_bundle/kofun-unicode-common-o2.o" \
    "$swapped_common_bundle/kif-v1-common-o2.o"
cp "$swapped_common_bundle/.kif-v1-common-o2.o.saved" \
    "$swapped_common_bundle/kofun-unicode-common-o2.o"
rm -f -- "$swapped_common_bundle/.kif-v1-common-o2.o.saved"
chmod 0444 "$swapped_common_bundle/kif-v1-common-o2.o" \
    "$swapped_common_bundle/kofun-unicode-common-o2.o"
seal_bundle "$swapped_common_bundle"
expect_refusal swapped-common-role "$swapped_common_bundle" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

# Cache provenance: append bytes that the ELF linker accepts, then restore the
# original mtimes.  The alternate bundle remains valid but must receive a new
# executable key; repeating one identity must reuse only its own executables.
alternate=$WORK/alternate-bundle
copy_bundle "$alternate"
for profile in semantic-producer-main.o semantic-producer-library.o \
    kif-v1-common-o2.o
do
    chmod u+w "$alternate/$profile"
    printf '\000' >>"$alternate/$profile"
    touch -r "$bundle/$profile" "$alternate/$profile"
    chmod 0444 "$alternate/$profile"
    test ! "$alternate/$profile" -nt "$bundle/$profile" ||
        assert_fail "$profile alternate mtime is newer"
    test ! "$bundle/$profile" -nt "$alternate/$profile" ||
        assert_fail "$profile alternate mtime is older"
done
rewrite_bundle_manifest "$alternate"
seal_bundle "$alternate"
kofun_stage2_semantic_objects_validate "$ROOT" "$alternate"
alternate_identity=$KOFUN_STAGE2_SEMANTIC_OBJECT_ID
assert_ne 'content identity changes despite equal mtimes' \
    "$alternate_identity" "$bundle_identity"

# The final KIF executable key also covers the complete non-object source
# closure.  Equal mtimes therefore cannot preserve a stale executable after a
# top-level source or included header changes.
kif_identity_root=$WORK/kif-link-identity-root
mkdir -p "$kif_identity_root/bin"
cp "$ROOT/bin/kofun-digest" "$kif_identity_root/bin/kofun-digest"
kofun_stage2_semantic_kif_source_paths |
while IFS= read -r kif_identity_source_path; do
    mkdir -p "$kif_identity_root/$(dirname -- "$kif_identity_source_path")"
    cp -p "$ROOT/$kif_identity_source_path" \
        "$kif_identity_root/$kif_identity_source_path"
done
cp -p "$kif_identity_root/bootstrap/stage2/stage2_kif_producer.c" \
    "$WORK/stage2_kif_producer.c.mtime"
cp -p "$kif_identity_root/bootstrap/stage2/kif_v1.h" \
    "$WORK/kif_v1.h.mtime"
kif_identity_digest_tool=$ROOT/build/digest/kofun-digest
assert_executable 'KIF identity digest tool' "$kif_identity_digest_tool"
if test "${KOFUN_DIGEST_TOOL+x}" = x; then
    saved_kofun_digest_tool=$KOFUN_DIGEST_TOOL
    had_kofun_digest_tool=1
else
    saved_kofun_digest_tool=
    had_kofun_digest_tool=0
fi
KOFUN_DIGEST_TOOL=$kif_identity_digest_tool
export KOFUN_DIGEST_TOOL

derive_kif_identity() {
    kofun_stage2_semantic_executable_identity "$kif_identity_root" kif \
        "$bundle/semantic-producer-library.o" \
        "$bundle/semantic-events.o" "$bundle/sha256.o"
}
derive_kif_identity
kif_identity_base=$KOFUN_STAGE2_SEMANTIC_EXECUTABLE_ID
printf '%s\n' '/* equal-mtime source mutation */' \
    >>"$kif_identity_root/bootstrap/stage2/stage2_kif_producer.c"
touch -r "$WORK/stage2_kif_producer.c.mtime" \
    "$kif_identity_root/bootstrap/stage2/stage2_kif_producer.c"
derive_kif_identity
kif_identity_source=$KOFUN_STAGE2_SEMANTIC_EXECUTABLE_ID
assert_ne 'equal-mtime KIF source changes executable identity' \
    "$kif_identity_source" "$kif_identity_base"
printf '%s\n' '/* equal-mtime header mutation */' \
    >>"$kif_identity_root/bootstrap/stage2/kif_v1.h"
touch -r "$WORK/kif_v1.h.mtime" \
    "$kif_identity_root/bootstrap/stage2/kif_v1.h"
derive_kif_identity
assert_ne 'equal-mtime KIF header changes executable identity' \
    "$KOFUN_STAGE2_SEMANTIC_EXECUTABLE_ID" "$kif_identity_source"
if test "$had_kofun_digest_tool" -eq 1; then
    KOFUN_DIGEST_TOOL=$saved_kofun_digest_tool
    export KOFUN_DIGEST_TOOL
else
    unset KOFUN_DIGEST_TOOL
fi

cache_log=$WORK/cache-links.log
: >"$cache_log"
cache_events=$WORK/cache/events
cache_kif=$WORK/cache/kif
run_cache_pair() {
    cache_label=$1
    cache_bundle=$2
    set +e
    KOFUN_VERIFY_CC_LOG="$cache_log" \
    KOFUN_STAGE2_SEMANTIC_OBJECT_DIR="$cache_bundle" \
    KOFUN_STAGE2_EVENTS_BUILD_DIR="$cache_events" \
    KOFUN_STAGE2_KIF_BUILD_DIR="$cache_kif" \
    CC="$wrapper" \
        "$ROOT/bin/kofun" check "$fixture" \
            --emit-typed-sidecar "$WORK/$cache_label.sidecar.json" \
            --generation 7 \
            >"$WORK/$cache_label.events.stdout" \
            2>"$WORK/$cache_label.events.stderr"
    cache_events_status=$?
    KOFUN_VERIFY_CC_LOG="$cache_log" \
    KOFUN_STAGE2_SEMANTIC_OBJECT_DIR="$cache_bundle" \
    KOFUN_STAGE2_EVENTS_BUILD_DIR="$cache_events" \
    KOFUN_STAGE2_KIF_BUILD_DIR="$cache_kif" \
    CC="$wrapper" \
        "$ROOT/bin/kofun" check "$interface" \
            --emit-kif "$WORK/$cache_label.kif" \
            >"$WORK/$cache_label.kif.stdout" \
            2>"$WORK/$cache_label.kif.stderr"
    cache_kif_status=$?
    set -e
    assert_num "$cache_label events status" "$cache_events_status" -eq 0
    assert_num "$cache_label KIF status" "$cache_kif_status" -eq 0
}

run_cache_pair cache-a "$bundle"
assert_num 'first bundle links one main and one library executable' \
    "$(census_count "$cache_log" producer-object)" -eq 2
run_cache_pair cache-a-repeat "$bundle"
assert_num 'same bundle identity reuses only its own executables' \
    "$(census_count "$cache_log" producer-object)" -eq 2
run_cache_pair cache-b "$alternate"
assert_num 'equal-mtime alternate bundle relinks both executables' \
    "$(census_count "$cache_log" producer-object)" -eq 4
cmp "$WORK/cache-a.sidecar.json" "$WORK/cache-b.sidecar.json"
cmp "$WORK/cache-a.kif" "$WORK/cache-b.kif"

# Supplying a bundle without explicit link-cache directories is a standalone
# one-command session.  It must leave neither content-key generations in the
# launcher's historical default cache nor its private session directory.
snapshot_default_semantic_links() {
    for default_link_dir in \
        "$ROOT/build/stage2-events-cli" \
        "$ROOT/build/stage2-kif-cli"
    do
        if test -d "$default_link_dir"; then
            find "$default_link_dir" -maxdepth 1 -type f -print
        fi
    done | LC_ALL=C sort
}
snapshot_private_semantic_sessions() {
    find "$ROOT/build" -maxdepth 1 -type d \
        -name 'stage2-semantic-links.*' -print | LC_ALL=C sort
}
snapshot_default_semantic_links >"$WORK/default-links.before"
snapshot_private_semantic_sessions >"$WORK/private-sessions.before"
standalone_log=$WORK/standalone-session-links.log
: >"$standalone_log"
(
    unset KOFUN_STAGE2_EVENTS_BUILD_DIR KOFUN_STAGE2_KIF_BUILD_DIR \
        KOFUN_VERIFY_RUN_DIR
    KOFUN_VERIFY_CC_LOG=$standalone_log \
    KOFUN_STAGE2_SEMANTIC_OBJECT_DIR=$bundle \
    CC=$wrapper \
        "$ROOT/bin/kofun" check "$fixture" \
            --emit-typed-sidecar "$WORK/standalone-session.sidecar.json" \
            --generation 8 \
            >"$WORK/standalone-session.events.stdout" \
            2>"$WORK/standalone-session.events.stderr"
    KOFUN_VERIFY_CC_LOG=$standalone_log \
    KOFUN_STAGE2_SEMANTIC_OBJECT_DIR=$bundle \
    CC=$wrapper \
        "$ROOT/bin/kofun" check "$interface" \
            --emit-kif "$WORK/standalone-session.kif" \
            >"$WORK/standalone-session.kif.stdout" \
            2>"$WORK/standalone-session.kif.stderr"
)
assert_regular_file 'standalone session sidecar' \
    "$WORK/standalone-session.sidecar.json"
assert_regular_file 'standalone session KIF' "$WORK/standalone-session.kif"
assert_num 'standalone session links both object profiles' \
    "$(census_count "$standalone_log" producer-object)" -eq 2
snapshot_default_semantic_links >"$WORK/default-links.after"
snapshot_private_semantic_sessions >"$WORK/private-sessions.after"
cmp "$WORK/default-links.before" "$WORK/default-links.after"
cmp "$WORK/private-sessions.before" "$WORK/private-sessions.after"

# Corrupt both profile objects while retaining the original mtimes.  Their
# new content key must bypass the two valid cache entries and reach the linker,
# which refuses before either requested artifact is published.
corrupt=$WORK/corrupt-bundle
copy_bundle "$corrupt"
for profile in semantic-producer-main.o semantic-producer-library.o; do
    chmod u+w "$corrupt/$profile"
    printf '%s\n' 'not an object file' >"$corrupt/$profile"
    touch -r "$bundle/$profile" "$corrupt/$profile"
    chmod 0444 "$corrupt/$profile"
done
rewrite_bundle_manifest "$corrupt"
seal_bundle "$corrupt"
kofun_stage2_semantic_objects_validate "$ROOT" "$corrupt"
assert_ne 'corrupt replacement receives a distinct identity' \
    "$KOFUN_STAGE2_SEMANTIC_OBJECT_ID" "$bundle_identity"

corrupt_log=$WORK/corrupt-links.log
: >"$corrupt_log"
set +e
KOFUN_VERIFY_CC_LOG="$corrupt_log" \
KOFUN_STAGE2_SEMANTIC_OBJECT_DIR="$corrupt" \
KOFUN_STAGE2_EVENTS_BUILD_DIR="$cache_events" \
KOFUN_STAGE2_KIF_BUILD_DIR="$cache_kif" \
CC="$wrapper" \
    "$ROOT/bin/kofun" check "$fixture" \
        --emit-typed-sidecar "$WORK/corrupt.sidecar.json" --generation 7 \
        >"$WORK/corrupt.events.stdout" 2>"$WORK/corrupt.events.stderr"
corrupt_events_status=$?
KOFUN_VERIFY_CC_LOG="$corrupt_log" \
KOFUN_STAGE2_SEMANTIC_OBJECT_DIR="$corrupt" \
KOFUN_STAGE2_EVENTS_BUILD_DIR="$cache_events" \
KOFUN_STAGE2_KIF_BUILD_DIR="$cache_kif" \
CC="$wrapper" \
    "$ROOT/bin/kofun" check "$interface" \
        --emit-kif "$WORK/corrupt.kif" \
        >"$WORK/corrupt.kif.stdout" 2>"$WORK/corrupt.kif.stderr"
corrupt_kif_status=$?
set -e
assert_num 'corrupt main replacement refusal status' \
    "$corrupt_events_status" -ne 0
assert_num 'corrupt library replacement refusal status' \
    "$corrupt_kif_status" -ne 0
assert_num 'corrupt replacements both reach and fail the linker' \
    "$(census_count "$corrupt_log" failed-object)" -eq 2
assert_absent 'corrupt main publishes no sidecar' "$WORK/corrupt.sidecar.json"
assert_absent 'corrupt library publishes no KIF' "$WORK/corrupt.kif"

# Two cheap runner probes use fake compilers/tasks but the real lifecycle.
# They overlap, obtain distinct owned directories, clean only those
# directories, and leave a caller-supplied compiler under the old fixed path.
probe_root=$WORK/runner-probe-root
probe_bin=$WORK/runner-probe-bin
mkdir -p "$probe_root/bootstrap/stage2" "$probe_root/build/verify" \
    "$probe_root/bin" "$probe_bin"
cp "$ROOT/bootstrap/stage2/semantic-objects.sh" \
    "$probe_root/bootstrap/stage2/semantic-objects.sh"
cp "$ROOT/bootstrap/stage2/fuzz-sanitizer-object.sh" \
    "$probe_root/bootstrap/stage2/fuzz-sanitizer-object.sh"
cp "$ROOT/bootstrap/stage2/fuzz-sanitizer-cc-wrapper.sh" \
    "$probe_root/bootstrap/stage2/fuzz-sanitizer-cc-wrapper.sh"
cp "$ROOT/bootstrap/stage2/verify-cc-wrapper.sh" \
    "$probe_root/bootstrap/stage2/verify-cc-wrapper.sh"
cp "$ROOT/bin/kofun-digest" "$probe_root/bin/kofun-digest"
chmod 0755 \
    "$probe_root/bootstrap/stage2/fuzz-sanitizer-cc-wrapper.sh" \
    "$probe_root/bootstrap/stage2/verify-cc-wrapper.sh"
probe_digest_tool=$ROOT/build/digest/kofun-digest
assert_executable 'runner probe digest tool' "$probe_digest_tool"
kofun_stage2_semantic_source_paths |
while IFS= read -r probe_source; do
    mkdir -p "$probe_root/$(dirname -- "$probe_source")"
    printf '%s\n' "probe source: $probe_source" >"$probe_root/$probe_source"
done
kofun_stage2_fuzz_sanitizer_source_paths |
while IFS= read -r probe_source; do
    mkdir -p "$probe_root/$(dirname -- "$probe_source")"
    printf '%s\n' "probe source: $probe_source" >"$probe_root/$probe_source"
done

external_compiler=$probe_root/build/verify/external-compiler
printf '%s\n' 'caller-owned compiler' >"$external_compiler"
chmod 0755 "$external_compiler"
cp "$external_compiler" "$WORK/external-compiler.before"

fake_cc=$probe_bin/fake-cc
cat >"$fake_cc" <<'FAKE_CC'
#!/bin/sh
set -eu
output=
while test "$#" -gt 0; do
    if test "$1" = -o; then
        shift
        output=$1
    fi
    shift
done
test -n "$output"
printf '%s\n' 'fake compiler output' >"$output"
FAKE_CC
chmod 0755 "$fake_cc"

probe_log=$WORK/runner-probe.log
: >"$probe_log"
cat >"$probe_bin/task" <<'FAKE_TASK'
#!/bin/sh
set -eu
case ${1:-} in
    --parallel)
        probe_run=$(dirname -- "$KOFUN_STAGE2_SEMANTIC_OBJECT_DIR")
        printf 'parallel\t%s\t%s\t%s\t%s\t%s\n' \
            "$probe_run" \
            "$KOFUN_STAGE2_SEMANTIC_OBJECT_DIR" \
            "$KOFUN_STAGE2_COMPILER" \
            "$KOFUN_STAGE2_EVENTS_BUILD_DIR" \
            "$KOFUN_STAGE2_KIF_BUILD_DIR" >>"$KOFUN_RUNNER_PROBE_LOG"
        if test -n "${KOFUN_RUNNER_PROBE_SIGNAL:-}"; then
            kill -"$KOFUN_RUNNER_PROBE_SIGNAL" "$PPID"
        fi
        sleep 1
        ;;
esac
FAKE_TASK
chmod 0755 "$probe_bin/task"

set +e
PATH="$probe_bin:$PATH" \
KOFUN_STAGE2_COMPILER="$external_compiler" \
KOFUN_DIGEST_TOOL="$probe_digest_tool" \
CC="$probe_root/bootstrap/stage2/verify-cc-wrapper.sh" \
    sh "$ROOT/bootstrap/stage2/verify-runner.sh" "$probe_root" 1 smoke \
    >"$WORK/runner-self-wrapper.stdout" \
    2>"$WORK/runner-self-wrapper.stderr"
runner_self_wrapper_status=$?
set -e
assert_num 'runner recursive compiler refusal status' \
    "$runner_self_wrapper_status" -eq 2
assert_grep 'runner recursive compiler refusal names cause' \
    -Fq 'CC resolves to the compiler census wrapper itself' \
    "$WORK/runner-self-wrapper.stderr"

set +e
PATH="$probe_bin:$PATH" \
KOFUN_STAGE2_COMPILER="$external_compiler" \
KOFUN_DIGEST_TOOL="$probe_digest_tool" \
CC='cc -pipe' \
    sh "$ROOT/bootstrap/stage2/verify-runner.sh" "$probe_root" 1 smoke \
    >"$WORK/runner-multiword-cc.stdout" \
    2>"$WORK/runner-multiword-cc.stderr"
runner_multiword_cc_status=$?
set -e
assert_num 'runner multiword CC refusal status' \
    "$runner_multiword_cc_status" -eq 2
assert_grep 'runner multiword CC refusal names executable contract' \
    -Fq 'a C11 compiler is required; set CC' \
    "$WORK/runner-multiword-cc.stderr"

for runner_signal_case in TERM HUP; do
    signal_probe_log=$WORK/runner-$runner_signal_case-probe.log
    : >"$signal_probe_log"
    set +e
    env PATH="$probe_bin:$PATH" \
        KOFUN_RUNNER_PROBE_LOG="$signal_probe_log" \
        KOFUN_RUNNER_PROBE_SIGNAL="$runner_signal_case" \
        KOFUN_STAGE2_COMPILER="$external_compiler" \
        KOFUN_DIGEST_TOOL="$probe_digest_tool" \
        CC="$fake_cc" \
        sh "$ROOT/bootstrap/stage2/verify-runner.sh" \
            "$probe_root" 1 smoke \
            >"$WORK/runner-$runner_signal_case.stdout" \
            2>"$WORK/runner-$runner_signal_case.stderr"
    runner_signal_status=$?
    set -e
    case $runner_signal_case in
        TERM) runner_signal_expected=143 ;;
        HUP) runner_signal_expected=129 ;;
    esac
    assert_num "$runner_signal_case verify runner status" \
        "$runner_signal_status" -eq "$runner_signal_expected"
    assert_executable "$runner_signal_case preserves external compiler" \
        "$external_compiler"
    cmp "$WORK/external-compiler.before" "$external_compiler"
    while IFS= read -r interrupted_run; do
        assert_absent "$runner_signal_case removes interrupted run" \
            "$interrupted_run"
    done <<EOF_INTERRUPTED_RUNS
$(awk -F '\t' '$1 == "parallel" { print $2 }' "$signal_probe_log")
EOF_INTERRUPTED_RUNS
done

env PATH="$probe_bin:$PATH" \
    KOFUN_RUNNER_PROBE_LOG="$probe_log" \
    KOFUN_STAGE2_COMPILER="$external_compiler" \
    KOFUN_DIGEST_TOOL="$probe_digest_tool" \
    CC="$fake_cc" \
    sh "$ROOT/bootstrap/stage2/verify-runner.sh" "$probe_root" 1 smoke &
probe_one=$!
env PATH="$probe_bin:$PATH" \
    KOFUN_RUNNER_PROBE_LOG="$probe_log" \
    KOFUN_STAGE2_COMPILER="$external_compiler" \
    KOFUN_DIGEST_TOOL="$probe_digest_tool" \
    CC="$fake_cc" \
    sh "$ROOT/bootstrap/stage2/verify-runner.sh" "$probe_root" 1 smoke &
probe_two=$!
probe_one_status=0
probe_two_status=0
wait "$probe_one" || probe_one_status=$?
wait "$probe_two" || probe_two_status=$?
assert_num 'first concurrent verify runner status' "$probe_one_status" -eq 0
assert_num 'second concurrent verify runner status' "$probe_two_status" -eq 0
assert_num 'concurrent verify runner record count' \
    "$(awk -F '\t' '$1 == "parallel" { count++ } END { print count + 0 }' \
        "$probe_log")" -eq 2
assert_num 'concurrent verify runners own distinct directories' \
    "$(awk -F '\t' '$1 == "parallel" { print $2 }' "$probe_log" |
        sort -u | wc -l | tr -d ' ')" -eq 2
assert_num 'runner-owned event cache follows its run directory' \
    "$(awk -F '\t' '$1 == "parallel" && index($5, $2 "/") == 1 { count++ }
        END { print count + 0 }' "$probe_log")" -eq 2
assert_num 'runner-owned KIF cache follows its run directory' \
    "$(awk -F '\t' '$1 == "parallel" && index($6, $2 "/") == 1 { count++ }
        END { print count + 0 }' "$probe_log")" -eq 2
while IFS= read -r completed_run; do
    assert_absent 'completed verify runner removes only its run directory' \
        "$completed_run"
done <<EOF_RUNS
$(awk -F '\t' '$1 == "parallel" { print $2 }' "$probe_log" | sort -u)
EOF_RUNS
assert_executable 'caller-supplied compiler survives concurrent verify' \
    "$external_compiler"
cmp "$WORK/external-compiler.before" "$external_compiler"
assert_absent 'runner leaves no persistent semantic event cache' \
    "$probe_root/build/stage2-events-cli"
assert_absent 'runner leaves no persistent KIF cache' \
    "$probe_root/build/stage2-kif-cli"

printf '%s\n' \
    "PASS: $legacy_standard_stanzas standard producer build stanzas select two published profiles" \
    'PASS: semantic bundle v2 publishes eight closed roles and exact per-role source closures' \
    'PASS: 17 common site identities cover 19 owner links and 24 aggregate-verify links' \
    'PASS: standalone and shared KIF paths preserve bytes, diagnostics, and transactional failure' \
    'PASS: task verify census enforces exact profiles, rejects mixed argv, and classifies sanitizer/PIC separately' \
    'PASS: helper-produced manifests bind the complete source closure and detect bundle drift or corruption' \
    'PASS: final executable identities bind complete inputs by content, independent of mtime and path escapes' \
    'PASS: semantic executable publication is collision-safe, signal-clean, and session-bounded' \
    'PASS: verify runners own symlink-safe disjoint cleanup and preserve an external compiler on exit or signal' \
    'PASS: sanitizer, analyzer, PIC, and standalone source profiles remain explicit'

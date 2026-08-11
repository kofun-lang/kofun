#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../../.." && pwd)
ASSERT_CONTEXT='verify object reuse'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

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
assert_num 'discovery keeps only four sanitizer producer source profiles' \
    "$(grep -Fc 'bootstrap/stage2/semantic_producer.c' \
        "$ROOT/tests/conformance/discovery/run.sh")" -eq 4
assert_grep 'discovery keeps sanitizer coverage local' \
    -Fq -- '-fsanitize=address,undefined' \
    "$ROOT/tests/conformance/discovery/run.sh"
assert_grep 'LSP keeps its PIC producer source profile local' \
    -Fq -- '-fPIC' "$ROOT/tooling/lsp/build-semantic-bundle.sh"
assert_grep 'LSP still compiles the producer source' \
    -Fq 'bootstrap/stage2/semantic_producer.c' \
    "$ROOT/tooling/lsp/build-semantic-bundle.sh"

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
    -Fq 'kofun.stage2-semantic-object-manifest/v1' \
    "$ROOT/bootstrap/stage2/semantic-objects.sh"
assert_grep 'KIF identity names its complete non-object source closure' \
    -Fq 'kofun_stage2_semantic_kif_source_paths' \
    "$ROOT/bootstrap/stage2/semantic-objects.sh"
assert_grep 'verify delegates to an owned runner' \
    -Fq 'bootstrap/stage2/verify-runner.sh' "$ROOT/Taskfile.yml"
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
            main) dependency_define= ;;
            library|kif)
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
            "$real_cc" -std=c11 ${dependency_define:+"$dependency_define"} \
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

record_dependency_closure "$ROOT" "$WORK/bundle-source-closure.actual" \
    main:bootstrap/stage2/semantic_producer.c \
    library:bootstrap/stage2/semantic_producer.c \
    main:bootstrap/stage2/semantic_events.c \
    main:bootstrap/stage2/sha256.c
kofun_stage2_semantic_source_paths | LC_ALL=C sort -u \
    >"$WORK/bundle-source-closure.expected"
cmp "$WORK/bundle-source-closure.expected" \
    "$WORK/bundle-source-closure.actual"

record_dependency_closure "$ROOT" "$WORK/kif-source-closure.actual" \
    kif:bootstrap/stage2/stage2_kif_producer.c \
    kif:bootstrap/stage2/kif_v1.c
kofun_stage2_semantic_kif_source_paths | LC_ALL=C sort -u \
    >"$WORK/kif-source-closure.expected"
cmp "$WORK/kif-source-closure.expected" "$WORK/kif-source-closure.actual"

spaced_dependency_root=$WORK/'checkout path with spaces'
ln -s "$ROOT" "$spaced_dependency_root"
record_dependency_closure \
    "$spaced_dependency_root" "$WORK/spaced-source-closure.actual" \
    main:bootstrap/stage2/semantic_producer.c \
    library:bootstrap/stage2/semantic_producer.c \
    main:bootstrap/stage2/semantic_events.c \
    main:bootstrap/stage2/sha256.c
cmp "$WORK/bundle-source-closure.expected" \
    "$WORK/spaced-source-closure.actual"

census_count() {
    awk -F '\t' -v classifier="$2" '
        {
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
            count += selected
        }
        END { print count + 0 }
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
}

if test "${KOFUN_STAGE2_SEMANTIC_OBJECT_DIR+x}" = x; then
    bundle=$KOFUN_STAGE2_SEMANTIC_OBJECT_DIR
    kofun_stage2_semantic_objects_validate "$ROOT" "$bundle"
    test -n "${KOFUN_VERIFY_OBJECT_REUSE_CENSUS_LOG:-}" ||
        assert_fail 'runner bundle is missing its completed compiler census'
    build_log=$KOFUN_VERIFY_OBJECT_REUSE_CENSUS_LOG
    assert_standard_bundle_census "$build_log"
    assert_num 'full verify sanitizer producer classification' \
        "$(census_count "$build_log" sanitizer)" -eq 5
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

for member in semantic-producer-main.o semantic-producer-library.o \
    semantic-events.o sha256.o complete-v1 manifest-v1.tsv
do
    assert_regular_file "published $member" "$bundle/$member"
    assert_mode "published $member mode" "$bundle/$member" -r--r--r--
done
assert_mode 'published bundle directory mode' "$bundle" dr-xr-xr-x

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
    "MEASURE: source paths producer_compiles=$source_compile_count compiler_wall_ns=$source_wall_ns" \
    "MEASURE: object paths producer_compiles=$object_compile_count compiler_wall_ns=$object_wall_ns" \
    'PASS: main events, diagnostics, and library KIF are byte-identical through source and object paths'

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
    rewrite_manifest=$rewrite_bundle/.manifest-v1.tsv.new
    kofun_stage2_semantic_manifest_write "$ROOT" "$rewrite_bundle" \
        >"$rewrite_manifest"
    chmod 0444 "$rewrite_manifest"
    mv -f "$rewrite_manifest" "$rewrite_bundle/manifest-v1.tsv"
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
    KOFUN_PURE_IO_WORK="$WORK/pure-io-effects.$refusal_label" \
        sh "$ROOT/tests/conformance/effects/pure-io/run.sh" \
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

partial=$WORK/partial-bundle
copy_bundle "$partial"
rm "$partial/semantic-producer-library.o"
seal_bundle "$partial"
expect_refusal partial "$partial" \
    'bundle member is missing: semantic-producer-library.o'

nonregular=$WORK/nonregular-bundle
copy_bundle "$nonregular"
rm "$nonregular/semantic-producer-main.o"
mkdir "$nonregular/semantic-producer-main.o"
seal_bundle "$nonregular"
expect_refusal nonregular "$nonregular" \
    'bundle member is not a regular file: semantic-producer-main.o'

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
chmod u+w "$wrong_marker/complete-v1"
printf '%s\n' 'kofun.stage2-semantic-objects/v1' extra \
    >"$wrong_marker/complete-v1"
chmod 0444 "$wrong_marker/complete-v1"
seal_bundle "$wrong_marker"
expect_refusal marker "$wrong_marker" \
    'bundle member has the wrong profile marker: complete-v1'

missing_manifest=$WORK/missing-manifest-bundle
copy_bundle "$missing_manifest"
rm "$missing_manifest/manifest-v1.tsv"
seal_bundle "$missing_manifest"
expect_refusal missing-manifest "$missing_manifest" \
    'bundle member is missing: manifest-v1.tsv'

extra_manifest=$WORK/extra-manifest-bundle
copy_bundle "$extra_manifest"
chmod u+w "$extra_manifest/manifest-v1.tsv"
printf '%s\n' 'unknown\textra' >>"$extra_manifest/manifest-v1.tsv"
chmod 0444 "$extra_manifest/manifest-v1.tsv"
seal_bundle "$extra_manifest"
expect_refusal extra-manifest "$extra_manifest" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

profile_manifest=$WORK/profile-manifest-bundle
copy_bundle "$profile_manifest"
chmod u+w "$profile_manifest/manifest-v1.tsv"
sed 's/-std=c11|-O2|-g/-std=c11|-O0|-g/' \
    "$profile_manifest/manifest-v1.tsv" \
    >"$profile_manifest/.manifest-v1.tsv.new"
chmod 0444 "$profile_manifest/.manifest-v1.tsv.new"
mv -f "$profile_manifest/.manifest-v1.tsv.new" \
    "$profile_manifest/manifest-v1.tsv"
seal_bundle "$profile_manifest"
expect_refusal profile-manifest "$profile_manifest" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

o0_bundle=$WORK/o0-bundle
copy_bundle "$o0_bundle"
rm "$o0_bundle/semantic-producer-main.o"
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
rm "$swapped_bundle/.semantic-producer-main.o.saved"
chmod 0444 "$swapped_bundle/semantic-producer-main.o" \
    "$swapped_bundle/semantic-producer-library.o"
seal_bundle "$swapped_bundle"
expect_refusal swapped-role "$swapped_bundle" \
    'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'

# Cache provenance: append bytes that the ELF linker accepts, then restore the
# original mtimes.  The alternate bundle remains valid but must receive a new
# executable key; repeating one identity must reuse only its own executables.
alternate=$WORK/alternate-bundle
copy_bundle "$alternate"
for profile in semantic-producer-main.o semantic-producer-library.o; do
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
cp "$ROOT/bootstrap/stage2/verify-cc-wrapper.sh" \
    "$probe_root/bootstrap/stage2/verify-cc-wrapper.sh"
cp "$ROOT/bin/kofun-digest" "$probe_root/bin/kofun-digest"
chmod 0755 "$probe_root/bootstrap/stage2/verify-cc-wrapper.sh"
probe_digest_tool=$ROOT/build/digest/kofun-digest
assert_executable 'runner probe digest tool' "$probe_digest_tool"
kofun_stage2_semantic_source_paths |
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
    'PASS: task verify census enforces exact profiles, rejects mixed argv, and classifies sanitizer/PIC separately' \
    'PASS: helper-produced manifests bind the complete source closure and detect bundle drift or corruption' \
    'PASS: final executable identities bind complete inputs by content, independent of mtime and path escapes' \
    'PASS: semantic executable publication is collision-safe, signal-clean, and session-bounded' \
    'PASS: verify runners own symlink-safe disjoint cleanup and preserve an external compiler on exit or signal' \
    'PASS: sanitizer, analyzer, PIC, and standalone source profiles remain explicit'

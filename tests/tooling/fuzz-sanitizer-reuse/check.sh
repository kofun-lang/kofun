#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../../.." && pwd)
ASSERT_CONTEXT='fuzz sanitizer reuse'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"
. "$ROOT/bootstrap/stage2/fuzz-sanitizer-object.sh"

if test "${KOFUN_FUZZ_SANITIZER_REUSE_WORK+x}" = x; then
    WORK=$KOFUN_FUZZ_SANITIZER_REUSE_WORK
else
    mkdir -p "$ROOT/build"
    WORK=$(mktemp -d "$ROOT/build/fuzz-sanitizer-reuse.XXXXXX")
fi
case $WORK in
    */fuzz-sanitizer-reuse|*/fuzz-sanitizer-reuse.*) ;;
    *) assert_fail "work directory must end in fuzz-sanitizer-reuse[.suffix]: $WORK" ;;
esac

cleanup() {
    if test -e "$WORK" || test -L "$WORK"; then
        kofun_stage2_owned_tree_remove "$WORK" 2>/dev/null || true
    fi
}
trap cleanup 0 1 2 15
cleanup
mkdir -p "$WORK"

if test -n "${KOFUN_FUZZ_SANITIZER_TEST_REAL_CC:-}"; then
    real_cc=$KOFUN_FUZZ_SANITIZER_TEST_REAL_CC
elif test -n "${KOFUN_VERIFY_REAL_CC:-}"; then
    real_cc=$KOFUN_VERIFY_REAL_CC
else
    real_cc=$(command -v "${CC:-cc}") ||
        assert_fail 'a C11 compiler is required'
fi
assert_executable 'real C compiler' "$real_cc"
command -v nm >/dev/null 2>&1 || assert_fail 'nm is required'

wrapper=$ROOT/bootstrap/stage2/fuzz-sanitizer-cc-wrapper.sh
helper=$ROOT/bootstrap/stage2/fuzz-sanitizer-object.sh
runner=$ROOT/bootstrap/stage2/verify-runner.sh
assert_executable 'fixed fuzz sanitizer argv observer' "$wrapper"
assert_regular_file 'fixed fuzz sanitizer object helper' "$helper"

# Derive the exact repository dependency closure under the same profile as
# the reusable object.  The depfile decoder is the bounded parser already
# exercised by the ordinary semantic-object gate: it handles continuations,
# escaped spaces, and doubled dollars without eval or host-path publication.
record_fuzz_dependency_closure() {
    fuzz_dependency_root=$1
    fuzz_dependency_output=$2
    fuzz_dependency_cc=${3:-$real_cc}
    fuzz_dependency_root_physical=$(CDPATH= cd -P -- \
        "$fuzz_dependency_root" && pwd) ||
        assert_fail "cannot normalize fuzz dependency root: $fuzz_dependency_root"
    : >"$fuzz_dependency_output.unsorted"
    fuzz_dependency_depfile=$fuzz_dependency_output.depfile
    (
        CDPATH= cd -- "$fuzz_dependency_root" &&
        "$fuzz_dependency_cc" \
            -std=c11 -O1 -g -Wall -Wextra -Werror \
            -fsanitize=address,undefined -fno-omit-frame-pointer \
            -MM -MT fixed bootstrap/stage2/compiler.c \
            >"$fuzz_dependency_depfile"
    ) || assert_fail 'cannot derive fuzz sanitizer dependency closure'
    fuzz_dependency_paths=$(
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
            ' "$fuzz_dependency_depfile"
    ) || assert_fail 'cannot decode fuzz sanitizer dependency closure'
    while IFS= read -r fuzz_dependency_path; do
        test -n "$fuzz_dependency_path" || continue
        case $fuzz_dependency_path in
            /*)
                assert_fail \
                    "fuzz dependency is not checkout-relative: $fuzz_dependency_path"
                ;;
        esac
        fuzz_dependency_dir=$(dirname -- \
            "$fuzz_dependency_root/$fuzz_dependency_path")
        fuzz_dependency_base=$(basename -- "$fuzz_dependency_path")
        fuzz_dependency_dir=$(CDPATH= cd -P -- \
            "$fuzz_dependency_dir" && pwd) ||
            assert_fail "cannot normalize fuzz dependency: $fuzz_dependency_path"
        fuzz_dependency_absolute=$fuzz_dependency_dir/$fuzz_dependency_base
        case $fuzz_dependency_absolute in
            "$fuzz_dependency_root_physical"/*)
                printf '%s\n' \
                    "${fuzz_dependency_absolute#"$fuzz_dependency_root_physical"/}" \
                    >>"$fuzz_dependency_output.unsorted"
                ;;
            *)
                assert_fail \
                    "fuzz dependency escapes checkout: $fuzz_dependency_absolute"
                ;;
        esac
    done <<EOF_FUZZ_DEPENDENCIES
$fuzz_dependency_paths
EOF_FUZZ_DEPENDENCIES
    LC_ALL=C sort -u "$fuzz_dependency_output.unsorted" \
        >"$fuzz_dependency_output"
}

fuzz_dependency_actual=$WORK/fuzz-profile-dependencies.actual
fuzz_dependency_expected=$WORK/fuzz-profile-dependencies.expected
record_fuzz_dependency_closure "$ROOT" "$fuzz_dependency_actual"
kofun_stage2_fuzz_sanitizer_source_paths | LC_ALL=C sort -u \
    >"$fuzz_dependency_expected"
cmp "$fuzz_dependency_expected" "$fuzz_dependency_actual" ||
    assert_fail 'declared fuzz source closure differs from the exact compiler include graph'

fuzz_dependency_spaced_root=$WORK/'checkout path with spaces'
ln -s "$ROOT" "$fuzz_dependency_spaced_root"
record_fuzz_dependency_closure \
    "$fuzz_dependency_spaced_root" "$WORK/fuzz-profile-dependencies.spaced"
cmp "$fuzz_dependency_expected" "$WORK/fuzz-profile-dependencies.spaced" ||
    assert_fail 'fuzz dependency closure changes through a checkout path with spaces'

fuzz_dependency_new_leaf=$WORK/fuzz-profile-dependencies.new-leaf
{
    sed -n '1,$p' "$fuzz_dependency_expected"
    printf '%s\n' injected/new-leaf.h
} | LC_ALL=C sort -u >"$fuzz_dependency_new_leaf"
fuzz_dependency_new_leaf_status=0
cmp "$fuzz_dependency_expected" "$fuzz_dependency_new_leaf" \
    >"$WORK/dependency-new-leaf.stdout" \
    2>"$WORK/dependency-new-leaf.stderr" ||
    fuzz_dependency_new_leaf_status=$?
assert_num 'new include leaf arms exact dependency comparison' \
    "$fuzz_dependency_new_leaf_status" -ne 0

fuzz_dependency_replaced_leaf=$WORK/fuzz-profile-dependencies.replaced-leaf
sed 's#bootstrap/stage2/decimal_v1[.]h#bootstrap/stage2/replaced-leaf.h#' \
    "$fuzz_dependency_expected" >"$fuzz_dependency_replaced_leaf"
fuzz_dependency_replaced_leaf_status=0
cmp "$fuzz_dependency_expected" "$fuzz_dependency_replaced_leaf" \
    >"$WORK/dependency-replaced-leaf.stdout" \
    2>"$WORK/dependency-replaced-leaf.stderr" ||
    fuzz_dependency_replaced_leaf_status=$?
assert_num 'replaced include leaf arms exact dependency comparison' \
    "$fuzz_dependency_replaced_leaf_status" -ne 0

fuzz_dependency_escape_cc=$WORK/fuzz-dependency-escape-cc
cat >"$fuzz_dependency_escape_cc" <<'FAKE_DEPENDENCY_CC'
#!/bin/sh
printf '%s\n' 'fixed: bootstrap/stage2/compiler.c ../outside-checkout.h'
FAKE_DEPENDENCY_CC
chmod 0755 "$fuzz_dependency_escape_cc"
fuzz_dependency_escape_status=0
(
    record_fuzz_dependency_closure "$ROOT" \
        "$WORK/fuzz-profile-dependencies.escape" \
        "$fuzz_dependency_escape_cc"
) >"$WORK/dependency-escape.stdout" \
    2>"$WORK/dependency-escape.stderr" ||
    fuzz_dependency_escape_status=$?
assert_num 'dependency outside the checkout is refused' \
    "$fuzz_dependency_escape_status" -ne 0
assert_grep 'dependency escape refusal names the boundary' \
    -Fq 'fuzz dependency escapes checkout:' "$WORK/dependency-escape.stderr"

# The consumer list and its role spelling are closed.  A sixth source build or
# an unobserved consumer cannot hide behind a basename count.
for consumer_spec in \
    'tests/fuzz/value_if.sh|value-if' \
    'tests/fuzz/match_guard.sh|match-guard' \
    'tests/fuzz/match_value.sh|match-value' \
    'tests/fuzz/match_value_invalid.sh|match-value-invalid' \
    'tests/fuzz/enum_match.sh|enum-match'
do
    old_ifs=$IFS
    IFS='|'
    set -- $consumer_spec
    IFS=$old_ifs
    consumer=$1
    role=$2
    direct_source_count=$(awk \
        '/bootstrap\/stage2\/compiler[.]c/ { count++ } END { print count + 0 }' \
        "$ROOT/$consumer")
    assert_num "$consumer has no superseded direct compiler source build" \
        "$direct_source_count" -eq 0
    assert_grep "$consumer sources the fixed object helper" \
        -Fq 'bootstrap/stage2/fuzz-sanitizer-object.sh' "$ROOT/$consumer"
    assert_grep "$consumer has its exact census role" \
        -Fq "\"\$ROOT\" \"\$WORK/kofun-stage2-sanitized\" $role" \
        "$ROOT/$consumer"
done

for owned_fixture_removal in \
    '$missing/compiler-fuzz-asan-ubsan.o' \
    '$symlink/compiler-fuzz-asan-ubsan.o'
do
    assert_grep "owned readonly removal is noninteractive: $owned_fixture_removal" \
        -Fxq "rm -f -- \"$owned_fixture_removal\"" \
        "$ROOT/tests/tooling/fuzz-sanitizer-reuse/check.sh"
done

assert_grep 'verify runner builds the fixed object before consumers' \
    -Fq 'kofun_stage2_fuzz_sanitizer_objects_build' "$runner"
assert_grep 'verify runner exports the fixed object directory' \
    -Fq 'KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR=' "$runner"
assert_grep 'verify runner validates the completed fuzz census' \
    -Fq 'task fuzz-sanitizer-reuse' "$runner"
assert_grep 'Taskfile registers the focused gate' \
    -Fq '  fuzz-sanitizer-reuse:' "$ROOT/Taskfile.yml"
assert_grep 'task help classifies the focused gate' \
    -Fq "'fuzz-sanitizer-reuse'" "$ROOT/tooling/task-help.mjs"

embedded=0
if test "${KOFUN_FUZZ_SANITIZER_REUSE_BUNDLE+x}" = x; then
    embedded=1
    bundle=$KOFUN_FUZZ_SANITIZER_REUSE_BUNDLE
    census=${KOFUN_FUZZ_SANITIZER_REUSE_CENSUS:-}
    assert_nonempty 'embedded compiler census path' "$census"
else
    bundle=$WORK/objects
    census=$WORK/compiler-argv.tsv
    source_compiler=$WORK/kofun-stage2-source-sanitized

    # This one source-built compiler is the independent differential baseline.
    # It is deliberately outside the supplied-object census.
    "$real_cc" -std=c11 -O1 -g -Wall -Wextra -Werror \
        -fsanitize=address,undefined -fno-omit-frame-pointer \
        "$ROOT/bootstrap/stage2/compiler.c" \
        -o "$source_compiler"
    kofun_stage2_fuzz_sanitizer_objects_build \
        "$ROOT" "$bundle" "$census" "$real_cc"

    KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR=$bundle
    KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG=$census
    KOFUN_VERIFY_REAL_CC=$real_cc
    KOFUN_STAGE2_COMPILER=$source_compiler
    export KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR \
        KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG KOFUN_VERIFY_REAL_CC \
        KOFUN_STAGE2_COMPILER

    consumer_status=0
    CC=$real_cc \
    KOFUN_VALUE_IF_FUZZ_CASES=1 \
    KOFUN_VALUE_IF_FUZZ_WORK=$WORK/value-if \
        sh "$ROOT/tests/fuzz/value_if.sh" \
        >"$WORK/value-if.log" 2>&1 || consumer_status=$?
    assert_num 'value-if supplied-object corpus status' "$consumer_status" -eq 0

    consumer_status=0
    CC=$real_cc \
    KOFUN_MATCH_GUARD_FUZZ_CASES=1 \
    KOFUN_MATCH_GUARD_FUZZ_WORK=$WORK/match-guard \
        sh "$ROOT/tests/fuzz/match_guard.sh" \
        >"$WORK/match-guard.log" 2>&1 || consumer_status=$?
    assert_num 'match-guard supplied-object corpus status' \
        "$consumer_status" -eq 0

    consumer_status=0
    CC=$real_cc \
    KOFUN_MATCH_VALUE_FUZZ_CASES=1 \
    KOFUN_MATCH_VALUE_FUZZ_WORK=$WORK/match-value \
        sh "$ROOT/tests/fuzz/match_value.sh" \
        >"$WORK/match-value.log" 2>&1 || consumer_status=$?
    assert_num 'match-value supplied-object corpus status' \
        "$consumer_status" -eq 0

    consumer_status=0
    CC=$real_cc \
    KOFUN_MATCH_VALUE_INVALID_FUZZ_CASES=1 \
    KOFUN_MATCH_VALUE_INVALID_FUZZ_WORK=$WORK/match-value-invalid \
        sh "$ROOT/tests/fuzz/match_value_invalid.sh" \
        >"$WORK/match-value-invalid.log" 2>&1 || consumer_status=$?
    assert_num 'match-value-invalid supplied-object corpus status' \
        "$consumer_status" -eq 0

    consumer_status=0
    CC=$real_cc \
    KOFUN_ENUM_MATCH_FUZZ_CASES=1 \
    KOFUN_ENUM_MATCH_FUZZ_WORK=$WORK/enum-match \
        sh "$ROOT/tests/fuzz/enum_match.sh" \
        >"$WORK/enum-match.log" 2>&1 || consumer_status=$?
    assert_num 'enum-match supplied-object corpus status' \
        "$consumer_status" -eq 0
fi

# The unset compatibility path is a separate production branch from object
# reuse.  Observe it with a cheap compiler that accepts only the historical
# source-build argv, including its exact final output.  Five roles are
# exercised so the static consumer/role join above cannot hide an unobserved
# fallback caller or silently strengthen that compatibility contract.
unset_contract=$WORK/unset-source-contract
unset_observer=$unset_contract/fake-cc
unset_observer_log=$unset_contract/argv.tsv
mkdir -p "$unset_contract"
: >"$unset_observer_log"
cat >"$unset_observer" <<'UNSET_SOURCE_CC'
#!/bin/sh
set -eu

refuse_unset_argv() {
    printf '%s\n' "unset fuzz source compiler: refused argv: $*" >&2
    exit 2
}

: "${KOFUN_FUZZ_UNSET_EXPECTED_ROOT:?missing expected root}"
: "${KOFUN_FUZZ_UNSET_EXPECTED_OUTPUT:?missing expected output}"
: "${KOFUN_FUZZ_UNSET_EXPECTED_ROLE:?missing expected role}"
: "${KOFUN_FUZZ_UNSET_OBSERVER_LOG:?missing observer log}"
test "$#" -eq 11 || refuse_unset_argv "argc=$#"
test "$1" = -std=c11 || refuse_unset_argv language
test "$2" = -O1 || refuse_unset_argv optimization
test "$3" = -g || refuse_unset_argv debug
test "$4" = -Wall || refuse_unset_argv wall
test "$5" = -Wextra || refuse_unset_argv extra-warnings
test "$6" = -Werror || refuse_unset_argv warning-errors
test "$7" = -fsanitize=address,undefined || refuse_unset_argv sanitizers
test "$8" = -fno-omit-frame-pointer || refuse_unset_argv frame-pointer
test "$9" = "$KOFUN_FUZZ_UNSET_EXPECTED_ROOT/bootstrap/stage2/compiler.c" ||
    refuse_unset_argv source
test "${10}" = -o || refuse_unset_argv output-flag

unset_observed_output=${11}
test "$unset_observed_output" = "$KOFUN_FUZZ_UNSET_EXPECTED_OUTPUT" ||
    refuse_unset_argv final-output
test ! -e "$unset_observed_output" && test ! -L "$unset_observed_output" ||
    refuse_unset_argv preexisting-final-output

printf '%s\n' '#!/bin/sh' 'exit 0' >"$unset_observed_output"
chmod 0755 "$unset_observed_output"
printf 'source\trole=%s\tprofile=%s\toutput=final\n' \
    "$KOFUN_FUZZ_UNSET_EXPECTED_ROLE" \
    fuzz-stage2-asan-ubsan-v1 >>"$KOFUN_FUZZ_UNSET_OBSERVER_LOG"
UNSET_SOURCE_CC
chmod 0755 "$unset_observer"

(
    unset KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR \
        KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG KOFUN_VERIFY_REAL_CC
    CC=$unset_observer
    KOFUN_FUZZ_UNSET_EXPECTED_ROOT=$ROOT
    KOFUN_FUZZ_UNSET_OBSERVER_LOG=$unset_observer_log
    export CC KOFUN_FUZZ_UNSET_EXPECTED_ROOT \
        KOFUN_FUZZ_UNSET_OBSERVER_LOG
    for unset_role in \
        value-if match-guard match-value match-value-invalid enum-match
    do
        unset_role_dir=$unset_contract/$unset_role
        unset_role_output=$unset_role_dir/kofun-stage2-sanitized
        mkdir -p "$unset_role_dir"
        KOFUN_FUZZ_UNSET_EXPECTED_ROLE=$unset_role
        KOFUN_FUZZ_UNSET_EXPECTED_OUTPUT=$unset_role_output
        export KOFUN_FUZZ_UNSET_EXPECTED_ROLE \
            KOFUN_FUZZ_UNSET_EXPECTED_OUTPUT
        kofun_stage2_fuzz_sanitized_compiler \
            "$ROOT" "$unset_role_output" "$unset_role" ||
            assert_fail "$unset_role unset source compiler argv changed"
        assert_executable "$unset_role unset source compiler publication" \
            "$unset_role_output"
        unset_private_count=$(find "$unset_role_dir" \
            -mindepth 1 -maxdepth 1 \
            -name '.kofun-stage2-sanitized.*' -print |
            awk 'END { print NR + 0 }')
        assert_num "$unset_role leaves no private executable" \
            "$unset_private_count" -eq 0
    done
)

assert_num 'unset source compiler exact argv count' \
    "$(awk 'END { print NR + 0 }' "$unset_observer_log")" -eq 5
for unset_role in \
    value-if match-guard match-value match-value-invalid enum-match
do
    assert_num "$unset_role unset source compiler argv count" \
        "$(awk -F '\t' -v role="$unset_role" \
            '$2 == "role=" role { count++ } END { print count + 0 }' \
            "$unset_observer_log")" -eq 1
done

unset_mutation_dir=$unset_contract/mutations
mkdir -p "$unset_mutation_dir"
for unset_mutation_spec in \
    'address-only|-O1|-fsanitize=address' \
    'optimization|-O2|-fsanitize=address,undefined'
do
    old_ifs=$IFS
    IFS='|'
    set -- $unset_mutation_spec
    IFS=$old_ifs
    unset_mutation_label=$1
    unset_mutation_opt=$2
    unset_mutation_sanitizer=$3
    unset_mutation_final=$unset_mutation_dir/kofun-stage2-sanitized
    unset_mutation_status=0
    KOFUN_FUZZ_UNSET_EXPECTED_ROOT=$ROOT \
    KOFUN_FUZZ_UNSET_EXPECTED_OUTPUT=$unset_mutation_final \
    KOFUN_FUZZ_UNSET_EXPECTED_ROLE=value-if \
    KOFUN_FUZZ_UNSET_OBSERVER_LOG=$unset_observer_log \
        "$unset_observer" \
            -std=c11 "$unset_mutation_opt" -g -Wall -Wextra -Werror \
            "$unset_mutation_sanitizer" -fno-omit-frame-pointer \
            "$ROOT/bootstrap/stage2/compiler.c" \
            -o "$unset_mutation_final" \
            >"$WORK/unset-$unset_mutation_label.stdout" \
            2>"$WORK/unset-$unset_mutation_label.stderr" ||
        unset_mutation_status=$?
    assert_num "$unset_mutation_label unset argv refusal status" \
        "$unset_mutation_status" -eq 2
    assert_grep "$unset_mutation_label unset argv refusal diagnostic" \
        -Fq 'unset fuzz source compiler: refused argv:' \
        "$WORK/unset-$unset_mutation_label.stderr"
    assert_absent "$unset_mutation_label unset argv publishes no output" \
        "$unset_mutation_final"
done
assert_num 'unset source argv mutations append no observation' \
    "$(awk 'END { print NR + 0 }' "$unset_observer_log")" -eq 5

kofun_stage2_fuzz_sanitizer_objects_validate \
    "$ROOT" "$bundle" "$real_cc" ||
    assert_fail 'published fuzz sanitizer bundle did not validate'
kofun_stage2_fuzz_sanitizer_census_validate "$census" ||
    assert_fail 'completed one-compile/five-link census did not validate'

census_count() {
    awk -F '\t' -v wanted_kind="$2" -v wanted_role="$3" '
        {
            delete field
            for (column = 2; column <= NF; column++) {
                split($column, pair, "=")
                field[pair[1]] = pair[2]
            }
            if ((wanted_kind == "all" || field["kind"] == wanted_kind) &&
                (wanted_role == "all" || field["role"] == wanted_role)) count++
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

assert_num 'shared compiler object compile census' \
    "$(census_count "$census" compile all)" -eq 1
assert_num 'private executable link census' \
    "$(census_count "$census" link all)" -eq 5
for role in value-if match-guard match-value match-value-invalid enum-match
do
    assert_num "$role link census" \
        "$(census_count "$census" link "$role")" -eq 1
done
assert_num 'manifest transitive repository source closure' \
    "$(awk -F '\t' '$1 == "source" { count++ } END { print count + 0 }' \
        "$bundle/manifest-v1.tsv")" -eq 9
assert_not_grep 'manifest source rows contain no checkout-specific path' \
    -F "source	$ROOT/" "$bundle/manifest-v1.tsv"

if test "$embedded" -eq 0; then
    # Every linked binary must carry both sanitizer runtime families.
    for executable in \
        "$WORK/value-if/kofun-stage2-sanitized" \
        "$WORK/match-guard/kofun-stage2-sanitized" \
        "$WORK/match-value/kofun-stage2-sanitized" \
        "$WORK/match-value-invalid/kofun-stage2-sanitized" \
        "$WORK/enum-match/kofun-stage2-sanitized"
    do
        assert_executable 'object-linked fuzz compiler' "$executable"
        executable_name=$(basename -- "$(dirname -- "$executable")")
        nm -D "$executable" >"$WORK/$executable_name.nm"
        assert_grep "$executable_name carries the ASan runtime" \
            -Eq '[[:space:]]__asan_init(@|$)' "$WORK/$executable_name.nm"
        assert_grep "$executable_name carries the UBSan runtime" \
            -Eq '[[:space:]]__ubsan_handle_' "$WORK/$executable_name.nm"
    done

    run_observation() {
        observation_executable=$1
        observation_source=$2
        observation_prefix=$3
        observation_logical=$4
        rm -f -- "$observation_logical.c" "$observation_logical.ir" \
            "$observation_logical.tokens"
        observation_status=0
        ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
        UBSAN_OPTIONS=halt_on_error=1 \
            "$observation_executable" "$observation_source" \
                "$observation_logical.c" "$observation_logical.ir" \
                "$observation_logical.tokens" \
                >"$observation_prefix.stdout" \
                2>"$observation_prefix.stderr" || observation_status=$?
        printf '%s\n' "$observation_status" >"$observation_prefix.status"
        for observation_extension in c ir tokens
        do
            if test -e "$observation_logical.$observation_extension"; then
                cp "$observation_logical.$observation_extension" \
                    "$observation_prefix.$observation_extension"
            fi
        done
    }

    compare_optional_artifact() {
        comparison_left=$1
        comparison_right=$2
        comparison_label=$3
        if test -e "$comparison_left" || test -e "$comparison_right"; then
            assert_regular_file "$comparison_label source-built artifact" \
                "$comparison_left"
            assert_regular_file "$comparison_label object-linked artifact" \
                "$comparison_right"
            cmp "$comparison_left" "$comparison_right" ||
                assert_fail "$comparison_label bytes differ"
        fi
    }

    object_compiler=$WORK/value-if/kofun-stage2-sanitized
    for differential_spec in \
        'accepted|bootstrap/fixtures/answer.kofun|0' \
        'rejected|tests/diagnostics/stage2/e2s23_invalid_if_condition.kofun|1'
    do
        old_ifs=$IFS
        IFS='|'
        set -- $differential_spec
        IFS=$old_ifs
        differential_label=$1
        differential_source=$ROOT/$2
        differential_expected_status=$3
        differential_logical=$WORK/$differential_label-program
        run_observation "$source_compiler" "$differential_source" \
            "$WORK/$differential_label-source" "$differential_logical"
        run_observation "$object_compiler" "$differential_source" \
            "$WORK/$differential_label-object" "$differential_logical"
        source_status=$(sed -n '1p' \
            "$WORK/$differential_label-source.status")
        object_status=$(sed -n '1p' \
            "$WORK/$differential_label-object.status")
        assert_num "$differential_label source-built status" \
            "$source_status" -eq "$differential_expected_status"
        assert_eq "$differential_label source/object status" \
            "$object_status" "$source_status"
        cmp "$WORK/$differential_label-source.stdout" \
            "$WORK/$differential_label-object.stdout" ||
            assert_fail "$differential_label source/object stdout differs"
        cmp "$WORK/$differential_label-source.stderr" \
            "$WORK/$differential_label-object.stderr" ||
            assert_fail "$differential_label source/object stderr differs"
        for extension in c ir tokens
        do
            compare_optional_artifact \
                "$WORK/$differential_label-source.$extension" \
                "$WORK/$differential_label-object.$extension" \
                "$differential_label .$extension"
        done
    done
    assert_regular_file 'accepted source-built C artifact' \
        "$WORK/accepted-source.c"
    assert_absent 'rejected source-built C artifact' \
        "$WORK/rejected-source.c"
    comparison_name=source/object
else
    comparison_name=completed-run-corpus/object
fi

copy_mutation_bundle() {
    cp -R "$bundle" "$1"
    chmod u+w "$1"
    find "$1" -mindepth 1 -maxdepth 1 -type f \
        -exec chmod u+w -- {} +
}

seal_mutation_bundle() {
    find "$1" -mindepth 1 -maxdepth 1 -type f \
        -exec chmod 0444 -- {} +
    chmod 0555 "$1"
}

expect_invalid_bundle() {
    invalid_label=$1
    invalid_bundle=$2
    invalid_text=$3
    invalid_cc=${4:-$real_cc}
    invalid_status=0
    kofun_stage2_fuzz_sanitizer_objects_validate \
        "$ROOT" "$invalid_bundle" "$invalid_cc" \
        >"$WORK/$invalid_label.stdout" \
        2>"$WORK/$invalid_label.stderr" || invalid_status=$?
    assert_num "$invalid_label refusal status" "$invalid_status" -ne 0
    assert_grep "$invalid_label refusal diagnostic" \
        -Fq "$invalid_text" "$WORK/$invalid_label.stderr"
}

corrupt=$WORK/corrupt
copy_mutation_bundle "$corrupt"
printf '%s\n' corrupt >>"$corrupt/compiler-fuzz-asan-ubsan.o"
seal_mutation_bundle "$corrupt"
expect_invalid_bundle corrupt "$corrupt" \
    'bundle provenance does not match current compiler, profile, source closure, and object bytes'

missing=$WORK/missing
copy_mutation_bundle "$missing"
rm -f -- "$missing/compiler-fuzz-asan-ubsan.o"
seal_mutation_bundle "$missing"
expect_invalid_bundle missing "$missing" \
    'object bundle must contain exactly three members'

writable=$WORK/writable
copy_mutation_bundle "$writable"
seal_mutation_bundle "$writable"
chmod 0644 "$writable/compiler-fuzz-asan-ubsan.o"
expect_invalid_bundle writable "$writable" \
    'bundle member is mutable: compiler-fuzz-asan-ubsan.o'

unreadable=$WORK/unreadable
copy_mutation_bundle "$unreadable"
seal_mutation_bundle "$unreadable"
chmod 0000 "$unreadable/compiler-fuzz-asan-ubsan.o"
expect_invalid_bundle unreadable "$unreadable" \
    'bundle member is not readable: compiler-fuzz-asan-ubsan.o'

symlink=$WORK/symlink
copy_mutation_bundle "$symlink"
rm -f -- "$symlink/compiler-fuzz-asan-ubsan.o"
ln -s "$bundle/compiler-fuzz-asan-ubsan.o" \
    "$symlink/compiler-fuzz-asan-ubsan.o"
seal_mutation_bundle "$symlink"
expect_invalid_bundle symlink "$symlink" \
    'bundle member is missing or not regular: compiler-fuzz-asan-ubsan.o'

expect_invalid_bundle wrong-compiler "$bundle" \
    'bundle provenance does not match current compiler, profile, source closure, and object bytes' \
    /bin/false

root_symlink=$WORK/root-symlink
ln -s "$bundle" "$root_symlink"
expect_invalid_bundle root-symlink "$root_symlink" \
    'object bundle is not a directory:'

root_mode=$WORK/root-mode
copy_mutation_bundle "$root_mode"
find "$root_mode" -mindepth 1 -maxdepth 1 -type f \
    -exec chmod 0444 -- {} +
chmod 0755 "$root_mode"
expect_invalid_bundle root-mode "$root_mode" \
    'object bundle directory is mutable (mode must be 0555)'

# Content, not mtime, closes the source identity.  The probe carries the exact
# nine-file tree but changes compiler.c and restores its original timestamp.
source_probe=$WORK/source-probe
mkdir -p "$source_probe/bin"
printf '%s\n' '#!/bin/sh' \
    'exec "$KOFUN_FUZZ_SOURCE_PROBE_DIGEST" "$@"' \
    >"$source_probe/bin/kofun-digest"
chmod 0755 "$source_probe/bin/kofun-digest"
KOFUN_FUZZ_SOURCE_PROBE_DIGEST=$ROOT/bin/kofun-digest
export KOFUN_FUZZ_SOURCE_PROBE_DIGEST
for source_path in $(kofun_stage2_fuzz_sanitizer_source_paths)
do
    mkdir -p "$source_probe/$(dirname -- "$source_path")"
    cp -p "$ROOT/$source_path" "$source_probe/$source_path"
done
cp -p "$source_probe/bootstrap/stage2/compiler.c" \
    "$source_probe/compiler.reference"
printf '\n' >>"$source_probe/bootstrap/stage2/compiler.c"
touch -r "$source_probe/compiler.reference" \
    "$source_probe/bootstrap/stage2/compiler.c"
equal_mtime_status=0
kofun_stage2_fuzz_sanitizer_objects_validate \
    "$source_probe" "$bundle" "$real_cc" \
    >"$WORK/equal-mtime.stdout" \
    2>"$WORK/equal-mtime.stderr" || equal_mtime_status=$?
assert_num 'equal-mtime source mutation refusal status' \
    "$equal_mtime_status" -ne 0
assert_grep 'equal-mtime source mutation refusal diagnostic' \
    -Fq 'bundle provenance does not match current compiler, profile, source closure, and object bytes' \
    "$WORK/equal-mtime.stderr"

# Direct argv mutations use an always-success compiler.  Every one must refuse
# before that compiler is reached or a census row is appended.
mutation_log=$WORK/argv-mutations.tsv
: >"$mutation_log"
KOFUN_FUZZ_SANITIZER_REAL_CC=/bin/true
KOFUN_FUZZ_SANITIZER_CENSUS_LOG=$mutation_log
KOFUN_FUZZ_SANITIZER_ROOT=$ROOT
KOFUN_FUZZ_SANITIZER_OBJECT_DIR=$bundle
KOFUN_FUZZ_SANITIZER_LINK_ROLE=
KOFUN_FUZZ_SANITIZER_LINK_OUTPUT=
export KOFUN_FUZZ_SANITIZER_REAL_CC KOFUN_FUZZ_SANITIZER_CENSUS_LOG \
    KOFUN_FUZZ_SANITIZER_ROOT KOFUN_FUZZ_SANITIZER_OBJECT_DIR \
    KOFUN_FUZZ_SANITIZER_LINK_ROLE KOFUN_FUZZ_SANITIZER_LINK_OUTPUT

expect_argv_refusal() {
    argv_label=$1
    shift
    argv_status=0
    "$wrapper" "$@" >"$WORK/$argv_label.stdout" \
        2>"$WORK/$argv_label.stderr" || argv_status=$?
    assert_num "$argv_label argv refusal status" "$argv_status" -eq 2
    assert_grep "$argv_label argv refusal diagnostic" \
        -Fq 'fuzz sanitizer compiler: refused argv:' \
        "$WORK/$argv_label.stderr"
}

expect_argv_refusal o0 \
    -std=c11 -O0 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -c "$ROOT/bootstrap/stage2/compiler.c" \
    -o "$bundle/compiler-fuzz-asan-ubsan.o"
expect_argv_refusal o2 \
    -std=c11 -O2 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -c "$ROOT/bootstrap/stage2/compiler.c" \
    -o "$bundle/compiler-fuzz-asan-ubsan.o"
expect_argv_refusal missing-sanitizer \
    -std=c11 -O1 -g -Wall -Wextra -Werror \
    -fno-omit-frame-pointer -c "$ROOT/bootstrap/stage2/compiler.c" \
    -o "$bundle/compiler-fuzz-asan-ubsan.o"
expect_argv_refusal split-sanitizer \
    -std=c11 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address -fsanitize=undefined -fno-omit-frame-pointer \
    -c "$ROOT/bootstrap/stage2/compiler.c" \
    -o "$bundle/compiler-fuzz-asan-ubsan.o"
expect_argv_refusal pedantic \
    -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -c "$ROOT/bootstrap/stage2/compiler.c" \
    -o "$bundle/compiler-fuzz-asan-ubsan.o"
expect_argv_refusal extra-macro \
    -std=c11 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DUNEXPECTED=1 -c "$ROOT/bootstrap/stage2/compiler.c" \
    -o "$bundle/compiler-fuzz-asan-ubsan.o"
expect_argv_refusal extra-include \
    -std=c11 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I"$ROOT/bootstrap/stage2" -c "$ROOT/bootstrap/stage2/compiler.c" \
    -o "$bundle/compiler-fuzz-asan-ubsan.o"
expect_argv_refusal source-object-mix \
    -std=c11 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/stage2/compiler.c" \
    "$bundle/compiler-fuzz-asan-ubsan.o" \
    -o "$WORK/mixed-output"
assert_file_empty 'refused argv never reaches the census' "$mutation_log"

wrong_role_status=0
KOFUN_FUZZ_SANITIZER_LINK_ROLE=unknown \
KOFUN_FUZZ_SANITIZER_LINK_OUTPUT=$WORK/kofun-stage2-sanitized \
    "$wrapper" \
        -std=c11 -O1 -g -Wall -Wextra -Werror \
        -fsanitize=address,undefined -fno-omit-frame-pointer \
        "$bundle/compiler-fuzz-asan-ubsan.o" \
        -o "$WORK/.kofun-stage2-sanitized.ABC123" \
        >"$WORK/wrong-role.stdout" \
        2>"$WORK/wrong-role.stderr" || wrong_role_status=$?
assert_num 'wrong link role refusal status' "$wrong_role_status" -eq 2
assert_grep 'wrong link role refusal diagnostic' \
    -Fq 'fuzz sanitizer compiler: refused argv:' "$WORK/wrong-role.stderr"
assert_file_empty 'wrong link role reaches no census' "$mutation_log"

incomplete_census=$WORK/incomplete-census.tsv
sed '$d' "$census" >"$incomplete_census"
incomplete_status=0
kofun_stage2_fuzz_sanitizer_census_validate "$incomplete_census" \
    >"$WORK/incomplete-census.stdout" \
    2>"$WORK/incomplete-census.stderr" || incomplete_status=$?
assert_num 'incomplete census refusal status' "$incomplete_status" -ne 0
assert_grep 'incomplete census refusal diagnostic' \
    -Fq 'compiler argv census is incomplete or invalid' \
    "$WORK/incomplete-census.stderr"

failed_build=$WORK/failed-build-objects
failed_build_log=$WORK/failed-build.tsv
failed_build_status=0
kofun_stage2_fuzz_sanitizer_objects_build \
    "$ROOT" "$failed_build" "$failed_build_log" /bin/false \
    >"$WORK/failed-build.stdout" \
    2>"$WORK/failed-build.stderr" || failed_build_status=$?
assert_num 'failed compile refusal status' "$failed_build_status" -ne 0
assert_absent 'failed compile publishes no bundle' "$failed_build"
failed_build_temps=$(
    find "$WORK" -mindepth 1 -maxdepth 1 \
        -name '.failed-build-objects.*' -print | awk 'END { print NR + 0 }'
)
assert_num 'failed compile cleans its private staging tree' \
    "$failed_build_temps" -eq 0
assert_num 'failed compile records one attempted compile' \
    "$(awk 'END { print NR + 0 }' "$failed_build_log")" -eq 1
assert_grep 'failed compile census carries non-success status' \
    -Fq 'status=1' "$failed_build_log"

# A test-only manifest bound to /bin/false reaches the real link-failure path;
# this exercises publication cleanup without adding another expensive compile.
failed_link_bundle=$WORK/failed-link-bundle
copy_mutation_bundle "$failed_link_bundle"
kofun_stage2_fuzz_sanitizer_manifest_write \
    "$ROOT" "$failed_link_bundle" /bin/false \
    >"$failed_link_bundle/manifest-v1.tsv"
seal_mutation_bundle "$failed_link_bundle"
failed_link_census=$WORK/failed-link.tsv
: >"$failed_link_census"
failed_link_parent=$WORK/failed-link
mkdir -p "$failed_link_parent"
KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR=$failed_link_bundle
KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG=$failed_link_census
KOFUN_VERIFY_REAL_CC=/bin/false
export KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR \
    KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG KOFUN_VERIFY_REAL_CC
failed_link_status=0
kofun_stage2_fuzz_sanitized_compiler \
    "$ROOT" "$failed_link_parent/kofun-stage2-sanitized" value-if \
    >"$WORK/failed-link.stdout" \
    2>"$WORK/failed-link.stderr" || failed_link_status=$?
assert_num 'failed link refusal status' "$failed_link_status" -ne 0
assert_absent 'failed link publishes no executable' \
    "$failed_link_parent/kofun-stage2-sanitized"
failed_link_temps=$(
    find "$failed_link_parent" -mindepth 1 -maxdepth 1 \
        -name '.kofun-stage2-sanitized.*' -print |
        awk 'END { print NR + 0 }'
)
assert_num 'failed link cleans its private executable' \
    "$failed_link_temps" -eq 0
assert_num 'failed link records one attempted link' \
    "$(awk 'END { print NR + 0 }' "$failed_link_census")" -eq 1
assert_grep 'failed link census carries non-success status' \
    -Fq 'status=1' "$failed_link_census"

# Two runner-owned roots coexist.  The same physical cleanup primitive used by
# verify removes only the entry whose identity it captured.
private_one=$(mktemp -d "$WORK/verify.XXXXXX")
private_two=$(mktemp -d "$WORK/verify.XXXXXX")
assert_ne 'concurrent private verify roots' "$private_one" "$private_two"
printf '%s\n' keep >"$private_two/caller-owned-sentinel"
kofun_stage2_owned_tree_remove "$private_one"
assert_absent 'first private verify root is removed' "$private_one"
assert_file_nonempty 'second private verify root remains intact' \
    "$private_two/caller-owned-sentinel"

compile_wall_ns=$(census_wall_ns "$census" compile)
link_wall_ns=$(census_wall_ns "$census" link)
printf '%s\n' \
    "MEASURE: support_compiles=1 private_links=5 compile_wall_ns=$compile_wall_ns link_wall_ns=$link_wall_ns" \
    'PASS: one immutable fuzz sanitizer compiler object serves five consumers' \
    "PASS: $comparison_name status, stdout, stderr, artifacts, and corpus observations agree" \
    'PASS: provenance, argv, census, publication, and private-lifecycle mutations refuse'

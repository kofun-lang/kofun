#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CC=${CC:-cc}
WORK=${KOFUN_STAGE2_EVENTS_WORK:-"$ROOT/build/stage2-semantic-events"}
FIXTURE="$ROOT/tests/typed-sidecar/fixtures/stage2_events.kofun"
. "$ROOT/bootstrap/stage2/build.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"
. "$ROOT/tests/typed-sidecar/path-log.sh"
ASSERT_CONTEXT='stage2 events'
. "$ROOT/tests/assertions/assert.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
case $WORK in
    */stage2-semantic-events|*/stage2-semantic-events.*) ;;
    *) fail "work directory must end in stage2-semantic-events[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/plain" "$WORK/sanitized" "$WORK/analyzer"
kofun_path_log_init
kofun_path_log_record "$WORK" "$FIXTURE"

COMMON_SOURCES="
$ROOT/bootstrap/stage2/sha256.c
$ROOT/unicode/kofun_unicode.c
$ROOT/bootstrap/stage2/semantic_events.c
$ROOT/tests/typed-sidecar/stage2_events_test.c
"
# shellcheck disable=SC2086
kofun_path_log_record $COMMON_SOURCES

# shellcheck disable=SC2086
"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    $COMMON_SOURCES \
    -o "$WORK/plain/stage2-events-test"
"$WORK/plain/stage2-events-test" \
    events "$WORK/plain/output" "$FIXTURE"

# The production adapter directly invokes the audited Stage 2 lexer, parser,
# scope-HIR builder, and ownership checker in compiler.c, then emits through
# the public sink API.
kofun_stage2_semantic_inputs "$ROOT" main
# THE PRODUCER SOURCES ARE DELIBERATELY NOT RECORDED, and the reason is a
# constraint on instrumenting this file at all.
# tests/tooling/verify-object-reuse/check.sh counts, in this file's TEXT, two
# things as proxies for build stanzas: the literal producer source path, and the
# quoted producer-input variable, which it requires to appear a fixed number of
# times across its consumer set. Naming that source either way reads to it as
# one more build.
#
# This comment cannot spell either token out, which is not fastidiousness: the
# first draft said why the variable could not be mentioned, spelled it, and
# pushed the count from 13 to 14 by itself. `grep -Fc` does not strip comments.
# The forbidden-requirements reader has the same scar from the other side --
# #1428 wrote a task name into a comment explaining that nothing ran it, and was
# counted as a caller.
#
# Nothing is lost. Those sources live under $ROOT, so they are `repo` class:
# worktree-private by construction and therefore not candidates for the
# collision this log exists to find. Recording them would add rows to the class
# that already has a thousand and none to the class that has zero. (#1504)
"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_EVENTS_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_SHA256_INPUT" \
    -o "$WORK/plain/kofun-stage2-semantic-events"
kofun_stage2_semantic_inputs "$ROOT" library
"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_EVENTS_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_SHA256_INPUT" \
    "$ROOT/tests/typed-sidecar/stage2_producer_test.c" \
    -o "$WORK/plain/stage2-producer-test"
"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    "$ROOT/tests/typed-sidecar/stage2_event_validate.c" \
    -o "$WORK/plain/validate-events"

"$WORK/plain/kofun-stage2-semantic-events" \
    "$FIXTURE" src/main.kofun "$WORK/plain/producer-complete.kse" 42
"$WORK/plain/validate-events" "$WORK/plain/producer-complete.kse"
"$WORK/plain/kofun-stage2-semantic-events" \
    "$ROOT/tests/typed-sidecar/fixtures/stage2_observer_reallocation.kofun" \
    src/observer-reallocation.kofun \
    "$WORK/plain/producer-observer-reallocation.kse" 42
"$WORK/plain/validate-events" \
    "$WORK/plain/producer-observer-reallocation.kse"
"$WORK/plain/stage2-producer-test" \
    "$FIXTURE" \
    "$ROOT/bootstrap/stage2/function_unknown_error.kofun" \
    "$ROOT/tests/typed-sidecar/fixtures/stage2_parse_prefix_error.kofun" \
    "$ROOT/tests/typed-sidecar/fixtures/stage2_scope_prefix_error.kofun" \
    "$ROOT/bootstrap/stage2/fixtures/borrowed_move_text.kofun" \
    "$ROOT/tests/conformance/modules/shadowing/duplicate_parameter.kofun" \
    "$ROOT/tests/typed-sidecar/fixtures/stage2_type_error.kofun" \
    "$ROOT/tests/typed-sidecar/fixtures/stage2_dependency_events.kofun"
"$WORK/plain/kofun-stage2-semantic-events" \
    "$FIXTURE" src/main.kofun "$WORK/plain/producer-repeat.kse" 42
cmp "$WORK/plain/producer-complete.kse" "$WORK/plain/producer-repeat.kse"
mkdir -p "$WORK/plain/remap-a" "$WORK/plain/remap-b"
cp "$FIXTURE" "$WORK/plain/remap-a/input.kofun"
cp "$FIXTURE" "$WORK/plain/remap-b/input.kofun"
"$WORK/plain/kofun-stage2-semantic-events" \
    "$WORK/plain/remap-a/input.kofun" src/main.kofun \
    "$WORK/plain/remap-a/output.kse" 42
"$WORK/plain/kofun-stage2-semantic-events" \
    "$WORK/plain/remap-b/input.kofun" src/main.kofun \
    "$WORK/plain/remap-b/output.kse" 42
cmp "$WORK/plain/remap-a/output.kse" "$WORK/plain/remap-b/output.kse"

set +e
"$WORK/plain/kofun-stage2-semantic-events" \
    "$ROOT/bootstrap/stage2/function_unknown_error.kofun" \
    src/unknown.kofun "$WORK/plain/producer-unknown.kse" 43
producer_unknown_status=$?
"$WORK/plain/kofun-stage2-semantic-events" \
    "$ROOT/tests/typed-sidecar/fixtures/stage2_type_error.kofun" \
    src/type-error.kofun "$WORK/plain/producer-type-error.kse" 44
producer_type_status=$?
"$WORK/plain/kofun-stage2-semantic-events" \
    --check-ownership \
    "$ROOT/bootstrap/stage2/fixtures/borrowed_move_text.kofun" \
    src/borrowed.kofun "$WORK/plain/producer-ownership.kse" 45
producer_ownership_status=$?
# #946: the whole-binding move rule reaching the compiler a user runs. The
# records gate pins its public message; what matters here is the second span.
# A use-after-move that says only "you cannot use this" leaves the reader to
# find the line that took it, so the move site travels as a labelled related
# location — and it has to survive the codec to be worth emitting.
"$WORK/plain/kofun-stage2-semantic-events" \
    "$ROOT/tests/conformance/records/production_use_after_move.kofun" \
    src/use-after-move.kofun "$WORK/plain/producer-use-after-move.kse" 49
producer_use_after_move_status=$?
"$WORK/plain/kofun-stage2-semantic-events" \
    "$ROOT/bootstrap/stage2/malformed.kofun" \
    src/malformed.kofun "$WORK/plain/producer-recovery.kse" 46
producer_recovery_status=$?
"$WORK/plain/kofun-stage2-semantic-events" \
    --cancel-after-commit "$FIXTURE" src/main.kofun \
    "$WORK/plain/producer-cancelled.kse" 47
producer_cancelled_status=$?
"$WORK/plain/kofun-stage2-semantic-events" \
    "$ROOT/tests/unicode/non_nfc_identifier.kofun" \
    src/early-invalid.kofun "$WORK/plain/producer-early-invalid.kse" 48
producer_early_status=$?
set -e
assert_num "producer unknown status" "$producer_unknown_status" -eq 1
assert_num "producer type status" "$producer_type_status" -eq 1
assert_num "producer ownership status" "$producer_ownership_status" -eq 1
assert_num "producer use-after-move status" \
    "$producer_use_after_move_status" -eq 1
assert_num "producer recovery status" "$producer_recovery_status" -eq 1
assert_num "producer cancelled status" "$producer_cancelled_status" -eq 1
assert_num "producer early status" "$producer_early_status" -eq 1
assert_absent "plain/producer-early-invalid.kse" \
    "$WORK/plain/producer-early-invalid.kse"
for stream in \
    "$WORK/plain/producer-unknown.kse" \
    "$WORK/plain/producer-type-error.kse" \
    "$WORK/plain/producer-ownership.kse" \
    "$WORK/plain/producer-use-after-move.kse" \
    "$WORK/plain/producer-recovery.kse" \
    "$WORK/plain/producer-cancelled.kse"
do
    "$WORK/plain/validate-events" "$stream"
done
assert_grep "plain/producer-complete.kse" \
    -a -q 'stage2-semantic-v1' "$WORK/plain/producer-complete.kse"
assert_grep "plain/producer-unknown.kse" \
    -a -q 'E2S16' "$WORK/plain/producer-unknown.kse"
assert_grep "plain/producer-type-error.kse" \
    -a -q 'E2S15' "$WORK/plain/producer-type-error.kse"
assert_grep "plain/producer-ownership.kse" \
    -a -q 'E007' "$WORK/plain/producer-ownership.kse"
assert_grep "plain/producer-use-after-move.kse" \
    -a -q 'E2S123' "$WORK/plain/producer-use-after-move.kse"
# The related location, not just the code: the move site is the half of this
# diagnostic that a fallback string alone cannot deliver to an editor.
assert_grep "plain/producer-use-after-move.kse" \
    -a -qF 'moved by `take`' "$WORK/plain/producer-use-after-move.kse"
assert_grep "plain/producer-recovery.kse" \
    -a -q 'E2S03' "$WORK/plain/producer-recovery.kse"

if "$CC" -std=c11 -x c -fsanitize=address,undefined \
        -o "$WORK/sanitized/probe" - >/dev/null 2>&1 <<'EOF'
int main(void) { return 0; }
EOF
then
    # shellcheck disable=SC2086
    "$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -I"$ROOT/bootstrap/stage2" \
        $COMMON_SOURCES \
        -o "$WORK/sanitized/stage2-events-test"
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/sanitized/stage2-events-test" \
        events "$WORK/sanitized/output" "$FIXTURE"
    "$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/semantic_producer.c" \
        "$ROOT/bootstrap/stage2/semantic_events.c" \
        "$ROOT/bootstrap/stage2/sha256.c" \
        -o "$WORK/sanitized/kofun-stage2-semantic-events"
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/sanitized/kofun-stage2-semantic-events" \
        "$FIXTURE" src/main.kofun \
        "$WORK/sanitized/producer-complete.kse" 42
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/sanitized/kofun-stage2-semantic-events" \
        "$ROOT/tests/typed-sidecar/fixtures/stage2_observer_reallocation.kofun" \
        src/observer-reallocation.kofun \
        "$WORK/sanitized/producer-observer-reallocation.kse" 42
    set +e
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/sanitized/kofun-stage2-semantic-events" \
        --check-ownership \
        "$ROOT/bootstrap/stage2/fixtures/borrowed_move_text.kofun" \
        src/borrowed.kofun \
        "$WORK/sanitized/producer-ownership.kse" 45
    sanitized_ownership_status=$?
    set -e
    assert_num "sanitized ownership status" "$sanitized_ownership_status" -eq 1
else
    fail 'the C compiler must support ASan and UBSan for semantic events'
fi

if command -v clang >/dev/null 2>&1; then
    if ! clang --analyze -std=c11 -Wall -Wextra -Werror -pedantic \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/semantic_events.c" \
        "$ROOT/tests/typed-sidecar/stage2_events_test.c" \
        -Xanalyzer -analyzer-output=text \
        >"$WORK/analyzer/clang.stdout" \
        2>"$WORK/analyzer/clang.stderr"
    then
        sed -n '1,200p' "$WORK/analyzer/clang.stderr" >&2
        fail 'clang static analyzer failed'
    fi
    if grep -q 'warning:' "$WORK/analyzer/clang.stderr"; then
        sed -n '1,200p' "$WORK/analyzer/clang.stderr" >&2
        fail 'clang static analyzer reported a finding'
    fi
    if ! clang --analyze -std=c11 -Wall -Wextra -Werror -pedantic \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/semantic_producer.c" \
        -Xanalyzer -analyzer-output=text \
        >"$WORK/analyzer/producer-clang.stdout" \
        2>"$WORK/analyzer/producer-clang.stderr"
    then
        sed -n '1,200p' "$WORK/analyzer/producer-clang.stderr" >&2
        fail 'production semantic producer static analysis failed'
    fi
    if grep -q 'warning:' "$WORK/analyzer/producer-clang.stderr"; then
        sed -n '1,200p' "$WORK/analyzer/producer-clang.stderr" >&2
        fail 'production semantic producer analyzer reported a finding'
    fi
elif "$CC" -fanalyzer -x c -c -o "$WORK/analyzer/probe.o" - \
        >/dev/null 2>&1 <<'EOF'
int semantic_event_analyzer_probe(void) { return 0; }
EOF
then
    "$CC" -std=c11 -fanalyzer -Wall -Wextra -Werror -pedantic \
        -I"$ROOT/bootstrap/stage2" \
        -c "$ROOT/bootstrap/stage2/semantic_events.c" \
        -o "$WORK/analyzer/semantic-events.o"
    "$CC" -std=c11 -fanalyzer -Wall -Wextra -Werror -pedantic \
        -I"$ROOT/bootstrap/stage2" \
        -c "$ROOT/bootstrap/stage2/semantic_producer.c" \
        -o "$WORK/analyzer/semantic-producer.o"
else
    fail 'clang analyzer or GCC -fanalyzer is required'
fi

# No-sink Stage 2 behavior stays on the pre-existing command surface.
kofun_stage2_build "$ROOT" "$WORK/plain/kofun-stage2"

# Every checked-in Stage 2 must-fail case is compared against the exact
# compiler authority selected by its diagnostic-mode directive.  This keeps
# the semantic producer from accepting a rejected program or inventing a
# replacement code/span/fallback.
diagnostic_cases=0
for source in "$ROOT"/tests/diagnostics/stage2/*.kofun
do
    diagnostic_cases=$((diagnostic_cases + 1))
    case_name=$(basename "$source" .kofun)
    mode=$(sed -n 's/^# diagnostic-mode: //p' "$source")
    code=$(sed -n 's/^# expect-code: //p' "$source")
    span=$(sed -n 's/^# expect-span: //p' "$source")
    test -n "$mode" && test -n "$code" && test -n "$span" ||
        fail "missing diagnostic metadata: $source"
    authority_flag=
    set +e
    if test "$mode" = ownership; then
        "$WORK/plain/kofun-stage2" --check-ownership "$source" \
            >"$WORK/plain/$case_name.authority"
        authority_status=$?
        authority_flag=--check-ownership
    else
        "$WORK/plain/kofun-stage2" --compile-outcome \
            "$source" \
            "$WORK/plain/$case_name.c" \
            "$WORK/plain/$case_name.ir" \
            "$WORK/plain/$case_name.tokens" \
            >"$WORK/plain/$case_name.authority"
        authority_status=$?
    fi
    # shellcheck disable=SC2086
    "$WORK/plain/kofun-stage2-semantic-events" $authority_flag \
        "$source" "src/$case_name.kofun" \
        "$WORK/plain/$case_name.kse" 700 \
        >"$WORK/plain/$case_name.producer"
    producer_status=$?
    set -e
    test "$authority_status" -ne 0 ||
        fail "must-fail authority accepted $source"
    test "$producer_status" -eq "$authority_status" ||
        fail "$case_name exit: authority=$authority_status producer=$producer_status"
    cmp "$WORK/plain/$case_name.authority" \
        "$WORK/plain/$case_name.producer"
    cmp "${source%.kofun}.stderr" "$WORK/plain/$case_name.producer"
    assert_grep "plain/$case_name.producer" \
        -q "error\\[$code\\]" "$WORK/plain/$case_name.producer"
    case $code in
        E2S01|E2S98|EUNICODE*)
            assert_absent "plain/$case_name.kse" "$WORK/plain/$case_name.kse"
            ;;
        *)
            "$WORK/plain/validate-events" "$WORK/plain/$case_name.kse"
            assert_grep "plain/$case_name.kse" \
                -a -q "$code" "$WORK/plain/$case_name.kse"
            ;;
    esac
done
test "$diagnostic_cases" -eq 82 ||
    fail "expected all 82 Stage 2 diagnostic fixtures, saw $diagnostic_cases"

# Enumerate every checked-in Stage 2 language-error companion, including the
# conformance, bootstrap, ownership, and diagnostic corpora.  Some companions
# describe a narrower subsystem and therefore name a different expected code;
# the live Stage 2 authority remains the source of truth for producer parity.
find "$ROOT/tests" "$ROOT/bootstrap" -type f \
    \( -name '*.stdout' -o -name '*.stderr' \) \
    -exec grep -l '^error\[' {} + |
    sort >"$WORK/plain/repository-error-companions"
# THE CENSUS LIST IS THE EVIDENCE, so record it before anything filters it.
# `repository_error_cases` counts a subset -- companions with a `.kofun` beside
# them and a code in the E2S/E007/E3xx bands -- and the failure is that the
# count comes up one short. Logging the unfiltered list is what lets a diff name
# WHICH file one run saw and the other did not, instead of confirming that a
# number differs, which the assertion already said. (#1504)
if test -n "${KOFUN_STAGE2_EVENTS_PATH_LOG:-}"; then
    while IFS= read -r companion
    do
        kofun_path_log_record "$companion"
    done <"$WORK/plain/repository-error-companions"
fi
repository_error_cases=0
while IFS= read -r expected
do
    stem=${expected%.*}
    source=$stem.kofun
    test -f "$source" || continue
    kofun_path_log_record "$source"
    companion_code=$(
        sed -n 's/^error\[\([^]]*\)\].*/\1/p' "$expected" |
            sed -n '1p'
    )
    # The Stage 2 language-error bands. `E3xx` joined them when RFC-0005
    # allocated `E370` for the member scope; a band left out here drops
    # silently out of the census rather than failing, which is how a
    # companion could change code and take itself out of this check.
    case $companion_code in
        E2S*|E007|E3[0-9][0-9]) ;;
        *) continue ;;
    esac
    repository_error_cases=$((repository_error_cases + 1))
    case_name=repository-error-$repository_error_cases
    authority_flag=
    set +e
    case $companion_code in
        E007|E2S20|E2S21)
            authority_flag=--check-ownership
            "$WORK/plain/kofun-stage2" --check-ownership "$source" \
                >"$WORK/plain/$case_name.authority"
            authority_status=$?
            ;;
        *)
            "$WORK/plain/kofun-stage2" --compile-outcome \
                "$source" \
                "$WORK/plain/$case_name.c" \
                "$WORK/plain/$case_name.ir" \
                "$WORK/plain/$case_name.tokens" \
                >"$WORK/plain/$case_name.authority"
            authority_status=$?
            ;;
    esac
    # shellcheck disable=SC2086
    "$WORK/plain/kofun-stage2-semantic-events" $authority_flag \
        "$source" "src/$case_name.kofun" \
        "$WORK/plain/$case_name.kse" 702 \
        >"$WORK/plain/$case_name.producer"
    producer_status=$?
    set -e
    test "$authority_status" -ne 0 ||
        fail "repository language-error authority accepted $source"
    test "$producer_status" -eq "$authority_status" ||
        fail "$case_name exit: authority=$authority_status producer=$producer_status ($source)"
    cmp "$WORK/plain/$case_name.authority" \
        "$WORK/plain/$case_name.producer" ||
        fail "repository language result diverged: $source"
    authority_code=$(
        sed -n 's/^error\[\([^]]*\)\].*/\1/p' \
            "$WORK/plain/$case_name.authority" |
            sed -n '1p'
    )
    test -n "$authority_code" ||
        fail "repository authority omitted an error code: $source"
    case $authority_code in
        E2S01|E2S98|EUNICODE*)
            test ! -e "$WORK/plain/$case_name.kse" ||
                fail "pre-token diagnostic emitted a stream: $source"
            ;;
        *)
            test -s "$WORK/plain/$case_name.kse" ||
                fail "repository diagnostic omitted a stream: $source"
            "$WORK/plain/validate-events" \
                "$WORK/plain/$case_name.kse"
            grep -a -q "$authority_code" \
                "$WORK/plain/$case_name.kse" ||
                fail "stream omitted $authority_code: $source"
            ;;
    esac
done <"$WORK/plain/repository-error-companions"
# Every `.stdout`/`.stderr` companion under tests/ and bootstrap/ whose first
# line is an E2S*/E007 diagnostic, paired with a `.kofun` beside it. The count
# is the census, not a target: a new refusal fixture raises it, and a widening
# that makes a refusal executable lowers it. Both are expected edits — what
# this number refuses is a companion silently gaining or losing its stream,
# code, or exit status without anyone noticing.
test "$repository_error_cases" -eq 419 ||
    fail "expected all 419 repository error companions, saw $repository_error_cases"

# Project-owned valid Stage 2 profiles cover functions, value control, concrete
# enums, nested lexical scopes, and shadowing.  Producer and compiler must both
# classify every one as complete/exit 0.
valid_index=0
for source in \
    "$FIXTURE" \
    "$ROOT/bootstrap/stage2/functions_fixture.kofun" \
    "$ROOT/tests/conformance/syntax/issues_35_47/if_value.kofun" \
    "$ROOT/tests/conformance/syntax/issues_35_47/match_value.kofun" \
    "$ROOT/tests/conformance/syntax/issues_35_47/enum_match.kofun" \
    "$ROOT/tests/conformance/modules/shadowing/positive.kofun" \
    "$ROOT/tests/conformance/modules/lexical-scopes/positive.kofun" \
    "$ROOT/tests/conformance/records/record_functions.kofun"
do
    valid_index=$((valid_index + 1))
    "$WORK/plain/kofun-stage2" --compile-outcome \
        "$source" \
        "$WORK/plain/valid-$valid_index.c" \
        "$WORK/plain/valid-$valid_index.ir" \
        "$WORK/plain/valid-$valid_index.tokens" \
        >"$WORK/plain/valid-$valid_index.authority"
    "$WORK/plain/kofun-stage2-semantic-events" \
        "$source" "src/valid-$valid_index.kofun" \
        "$WORK/plain/valid-$valid_index.kse" 701
    "$WORK/plain/validate-events" "$WORK/plain/valid-$valid_index.kse"
done
assert_num "valid index" "$valid_index" -eq 8

set +e
"$WORK/plain/kofun-stage2" --compile-outcome \
    "$ROOT/bootstrap/stage2/functions_fixture.kofun" \
    "$WORK/plain/no-sink-before.c" \
    "$WORK/plain/no-sink-before.ir" \
    "$WORK/plain/no-sink-before.tokens" \
    >"$WORK/plain/no-sink-before.stdout" \
    2>"$WORK/plain/no-sink-before.stderr"
no_sink_valid_before_status=$?
set -e
assert_num "no sink valid before status" "$no_sink_valid_before_status" -eq 0
sed -n '1,9p' "$WORK/plain/no-sink-before.ir" \
    >"$WORK/plain/no-sink-before.function-ir"
cmp "$ROOT/tests/typed-sidecar/fixtures/stage2_function_ir.golden" \
    "$WORK/plain/no-sink-before.function-ir"
set +e
"$WORK/plain/kofun-stage2" --compile-outcome \
    "$ROOT/bootstrap/stage2/function_unknown_error.kofun" \
    "$WORK/plain/unknown-before.c" \
    "$WORK/plain/unknown-before.ir" \
    "$WORK/plain/unknown-before.tokens" \
    >"$WORK/plain/unknown-before.stdout" \
    2>"$WORK/plain/unknown-before.stderr"
no_sink_invalid_before_status=$?
set -e
assert_num "no sink invalid before status" \
    "$no_sink_invalid_before_status" -eq 1
"$WORK/plain/kofun-stage2-semantic-events" \
    "$FIXTURE" src/main.kofun "$WORK/plain/no-sink-middle.kse" 99
set +e
"$WORK/plain/kofun-stage2" --compile-outcome \
    "$ROOT/bootstrap/stage2/functions_fixture.kofun" \
    "$WORK/plain/no-sink-after.c" \
    "$WORK/plain/no-sink-after.ir" \
    "$WORK/plain/no-sink-after.tokens" \
    >"$WORK/plain/no-sink-after.stdout" \
    2>"$WORK/plain/no-sink-after.stderr"
no_sink_valid_after_status=$?
set -e
assert_num "no sink valid after status" "$no_sink_valid_after_status" -eq 0
assert_num "no sink valid before status" \
    "$no_sink_valid_before_status" -eq "$no_sink_valid_after_status"
cmp "$WORK/plain/no-sink-before.c" "$WORK/plain/no-sink-after.c"
cmp "$WORK/plain/no-sink-before.ir" "$WORK/plain/no-sink-after.ir"
cmp "$WORK/plain/no-sink-before.tokens" "$WORK/plain/no-sink-after.tokens"
sed \
    "s|$WORK/plain/no-sink-before.c|OUTPUT.c|" \
    "$WORK/plain/no-sink-before.stdout" \
    >"$WORK/plain/no-sink-before.normalized"
sed \
    "s|$WORK/plain/no-sink-after.c|OUTPUT.c|" \
    "$WORK/plain/no-sink-after.stdout" \
    >"$WORK/plain/no-sink-after.normalized"
cmp \
    "$WORK/plain/no-sink-before.normalized" \
    "$WORK/plain/no-sink-after.normalized"
cmp "$WORK/plain/no-sink-before.stderr" "$WORK/plain/no-sink-after.stderr"
set +e
"$WORK/plain/kofun-stage2" --compile-outcome \
    "$ROOT/bootstrap/stage2/function_unknown_error.kofun" \
    "$WORK/plain/unknown-after.c" \
    "$WORK/plain/unknown-after.ir" \
    "$WORK/plain/unknown-after.tokens" \
    >"$WORK/plain/unknown-after.stdout" \
    2>"$WORK/plain/unknown-after.stderr"
no_sink_invalid_after_status=$?
set -e
assert_num "no sink invalid after status" "$no_sink_invalid_after_status" -eq 1
assert_num "no sink invalid before status" \
    "$no_sink_invalid_before_status" -eq "$no_sink_invalid_after_status"
cmp "$WORK/plain/unknown-before.ir" "$WORK/plain/unknown-after.ir"
cmp "$WORK/plain/unknown-before.tokens" "$WORK/plain/unknown-after.tokens"
cmp "$WORK/plain/unknown-before.stdout" "$WORK/plain/unknown-after.stdout"
cmp "$WORK/plain/unknown-before.stderr" "$WORK/plain/unknown-after.stderr"
cmp \
    "$ROOT/bootstrap/stage2/function_unknown_error.stdout" \
    "$WORK/plain/unknown-after.stdout"
assert_file_empty "plain/unknown-after.stderr" \
    "$WORK/plain/unknown-after.stderr"
assert_absent "plain/unknown-before.c" "$WORK/plain/unknown-before.c"
assert_absent "plain/unknown-after.c" "$WORK/plain/unknown-after.c"

# The instrument has to prove it could have seen something before its silence
# means anything. An empty log, or one missing the companions this run just
# counted, reads exactly like "no shared paths" and is worth nothing -- that is
# the failure mode #1504 was filed about, one level up from the census itself.
if test -n "${KOFUN_STAGE2_EVENTS_PATH_LOG:-}"; then
    kofun_path_log_finish
    test -s "$KOFUN_STAGE2_EVENTS_PATH_LOG" ||
        fail "path log is empty: $KOFUN_STAGE2_EVENTS_PATH_LOG"
    logged_companions=$(grep -c '^repo	' "$KOFUN_STAGE2_EVENTS_PATH_LOG" || true)
    test "$logged_companions" -ge "$repository_error_cases" ||
        fail "path log holds $logged_companions repo paths but the census counted
      $repository_error_cases companions; the instrument saw less than the gate
      did, so its silence about shared paths would mean nothing"
    printf 'PASS: path log %s: %s paths (%s work, %s repo, %s outside)\n' \
        "$KOFUN_STAGE2_EVENTS_PATH_LOG" \
        "$(grep -c . "$KOFUN_STAGE2_EVENTS_PATH_LOG")" \
        "$(grep -c '^work	' "$KOFUN_STAGE2_EVENTS_PATH_LOG" || true)" \
        "$logged_companions" \
        "$(grep -c '^outside	' "$KOFUN_STAGE2_EVENTS_PATH_LOG" || true)"
fi

printf '%s\n' \
    'PASS: Stage 2 semantic sink, compatibility, ASan/UBSan, and analyzer'

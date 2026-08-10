#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/syntax/issues_35_47"
ADT_CASES="$ROOT/tests/conformance/adt"
SPEC="$ROOT/spec/syntax/FOUNDATIONS_AND_CONTROL.md"
MATCH_SPEC="$ROOT/spec/bool-match-exhaustiveness.md"
ENUM_MATCH_SPEC="$ROOT/spec/enum-match-exhaustiveness.md"
NAMING_SPEC="$ROOT/docs/NAMING.md"
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

command -v "$CC" >/dev/null 2>&1 || {
    printf '%s\n' "syntax issues #35-#47: a C11 compiler is required" >&2
    exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-syntax-35-47.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

expect_stage2_unsupported() {
    source=$1
    stem=$(basename "${source%.kofun}")
    set +e
    "$WORK/kofun-stage2" \
        "$source" \
        "$WORK/$stem.c" \
        "$WORK/$stem.ir" \
        "$WORK/$stem.tokens" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    status=$?
    set -e

    test "$status" -eq 1 ||
        fail "$stem: Stage 2 unexpectedly returned $status"
    test ! -e "$WORK/$stem.c" ||
        fail "$stem: Stage 2 emitted C for an unsupported feature"
    test ! -s "$WORK/$stem.stderr" ||
        fail "$stem: Stage 2 wrote an unexpected stderr diagnostic"
    grep '^error\[E2S' "$WORK/$stem.stdout" >/dev/null ||
        fail "$stem: missing explicit Stage 2 unsupported diagnostic"
    printf '%s\n' "PASS unsupported: $stem"
}

# The mirror of the above, for a subject that has crossed into the Core. A
# feature that stops being refused has to keep being *executed* by something,
# or its fixture would simply be deleted and the coverage line would quietly
# shrink.
expect_stage2_lowers() {
    source=$1
    stem=$(basename "${source%.kofun}")
    set +e
    "$WORK/kofun-stage2" \
        "$source" \
        "$WORK/$stem.c" \
        "$WORK/$stem.ir" \
        "$WORK/$stem.tokens" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    status=$?
    set -e

    test "$status" -eq 0 ||
        fail "$stem: Stage 2 returned $status for a Core feature"
    test -s "$WORK/$stem.c" ||
        fail "$stem: Stage 2 emitted no C for a Core feature"
    test ! -s "$WORK/$stem.stderr" ||
        fail "$stem: Stage 2 wrote an unexpected stderr diagnostic"
    grep '^error\[E2S' "$WORK/$stem.stdout" >/dev/null &&
        fail "$stem: Stage 2 reported a diagnostic for a Core feature"
    printf '%s\n' "PASS lowered: $stem"
}

expect_stage2_diagnostic() {
    source=$1
    expected=$2
    stem=$(basename "${source%.kofun}")
    set +e
    "$WORK/kofun-stage2" \
        "$source" \
        "$WORK/$stem.c" \
        "$WORK/$stem.ir" \
        "$WORK/$stem.tokens" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    status=$?
    set -e

    test "$status" -eq 1 ||
        fail "$stem: Stage 2 unexpectedly returned $status"
    test ! -e "$WORK/$stem.c" ||
        fail "$stem: Stage 2 emitted C after a compile error"
    test ! -s "$WORK/$stem.stderr" ||
        fail "$stem: Stage 2 wrote an unexpected stderr diagnostic"
    cmp "$expected" "$WORK/$stem.stdout" ||
        fail "$stem: Stage 2 diagnostic changed"
    printf '%s\n' "PASS diagnostic: $stem"
}

for issue in 35 36 37 38 39 40 41 42 43 44 45 46 47; do
    grep "^## #$issue — " "$SPEC" >/dev/null ||
        fail "normative section for issue #$issue is missing"
done
test "$(grep -c '^### Prior designs and tradeoffs$' "$SPEC")" -eq 13 ||
    fail "each issue must contain a prior-design review"
test "$(grep -c '^### User stories and non-goals$' "$SPEC")" -eq 13 ||
    fail "each issue must contain user stories and non-goals"
test "$(grep -c '^### Normative contract$' "$SPEC")" -eq 13 ||
    fail "each issue must contain a normative contract"
test "$(grep -c '^# valid' "$SPEC")" -eq 13 ||
    fail "each issue must contain a valid canonical example"
test "$(grep -c '^# invalid' "$SPEC")" -eq 13 ||
    fail "each issue must contain an invalid example"
printf '%s\n' "PASS specification shape: issues #35-#47"

stage1_output=$("$ROOT/bin/kofun" run "$CASES/stage1_foundations.kofun")
test "$stage1_output" = 42 ||
    fail "Stage 1 foundations fixture did not print 42"
printf '%s\n' "PASS executable Stage 1 foundations"

unicode_stage1_output=$(
    "$ROOT/bin/kofun" run "$CASES/unicode_identifiers.kofun"
)
test "$unicode_stage1_output" = 42 ||
    fail "Stage 1 Japanese/Hangul identifiers did not print 42"
printf '%s\n' "PASS executable: Unicode identifiers in Stage 1"

kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"

"$WORK/kofun-stage2" \
    "$CASES/stage2_mutable_surface.kofun" \
    "$WORK/mutable.c" \
    "$WORK/mutable.ir" \
    "$WORK/mutable.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/mutable.c" -o "$WORK/mutable"
mutable_output=$("$WORK/mutable")
test "$mutable_output" = 42 ||
    fail "Stage 2 mutable declaration fixture did not print 42"
grep '^function|main|0|' "$WORK/mutable.ir" >/dev/null ||
    fail "Stage 2 IR did not record fn main"
printf '%s\n' "PASS executable Stage 2 immutable/mutable declarations"

expect_stage2_diagnostic \
    "$CASES/immutable_assignment.kofun" \
    "$CASES/immutable_assignment.stdout"
expect_stage2_diagnostic \
    "$CASES/unknown_assignment.kofun" \
    "$CASES/unknown_assignment.stdout"

"$WORK/kofun-stage2" \
    "$CASES/if_statement.kofun" \
    "$WORK/if-statement.c" \
    "$WORK/if-statement.ir" \
    "$WORK/if-statement.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/if-statement.c" -o "$WORK/if-statement"
"$WORK/if-statement" \
    >"$WORK/if-statement.stdout" 2>"$WORK/if-statement.stderr"
cmp "$CASES/if_statement.stdout" "$WORK/if-statement.stdout" ||
    fail "Stage 2 assignment/if output differs"
test ! -s "$WORK/if-statement.stderr" ||
    fail "Stage 2 assignment/if wrote unexpected stderr"
printf '%s\n' "PASS executable Stage 2 assignment followed by if"

"$WORK/kofun-stage2" \
    "$CASES/if_outer_assignment.kofun" \
    "$WORK/if-outer-assignment.c" \
    "$WORK/if-outer-assignment.ir" \
    "$WORK/if-outer-assignment.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/if-outer-assignment.c" -o "$WORK/if-outer-assignment"
"$WORK/if-outer-assignment" \
    >"$WORK/if-outer-assignment.stdout" \
    2>"$WORK/if-outer-assignment.stderr"
cmp "$CASES/if_outer_assignment.stdout" \
    "$WORK/if-outer-assignment.stdout" ||
    fail "Stage 2 outer mutable assignment output differs"
test ! -s "$WORK/if-outer-assignment.stderr" ||
    fail "Stage 2 outer mutable assignment wrote unexpected stderr"
printf '%s\n' "PASS executable Stage 2 outer mutable assignment"

"$WORK/kofun-stage2" \
    "$CASES/if_value.kofun" \
    "$WORK/if-value.c" \
    "$WORK/if-value.ir" \
    "$WORK/if-value.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/if-value.c" -o "$WORK/if-value"
"$WORK/if-value" \
    >"$WORK/if-value.stdout" 2>"$WORK/if-value.stderr"
cmp "$CASES/if_value.stdout" "$WORK/if-value.stdout" ||
    fail "Stage 2 value-position if output differs"
test ! -s "$WORK/if-value.stderr" ||
    fail "Stage 2 value-position if wrote unexpected stderr"
KOFUN_BUILD_DIR="$WORK/cli-stage1" \
KOFUN_STAGE2_BUILD_DIR="$WORK/cli-stage2" \
    "$ROOT/bin/kofun" run "$CASES/if_value.kofun" \
    >"$WORK/if-value-cli.stdout" 2>"$WORK/if-value-cli.stderr"
cmp "$CASES/if_value.stdout" "$WORK/if-value-cli.stdout" ||
    fail "public kofun run value-position if output differs"
test ! -s "$WORK/if-value-cli.stderr" ||
    fail "public kofun run value-position if wrote stderr"
printf '%s\n' "PASS executable Stage 2 value-position if"

"$WORK/kofun-stage2" \
    "$CASES/if_value_selected_error.kofun" \
    "$WORK/if-value-error.c" \
    "$WORK/if-value-error.ir" \
    "$WORK/if-value-error.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/if-value-error.c" -o "$WORK/if-value-error"
set +e
"$WORK/if-value-error" \
    >"$WORK/if-value-error.stdout" 2>"$WORK/if-value-error.stderr"
if_value_error_status=$?
set -e
test "$if_value_error_status" -eq 1 ||
    fail "selected failing value-if branch returned $if_value_error_status"
test ! -s "$WORK/if-value-error.stdout" ||
    fail "selected failing value-if branch wrote stdout"
cmp \
    "$CASES/if_value_selected_error.stderr" \
    "$WORK/if-value-error.stderr" ||
    fail "selected failing value-if branch diagnostic differs"
printf '%s\n' "PASS selected-only Stage 2 value-position if evaluation"

expect_stage2_diagnostic \
    "$ROOT/tests/diagnostics/stage2/e2s27_value_if_else.kofun" \
    "$ROOT/tests/diagnostics/stage2/e2s27_value_if_else.stderr"
expect_stage2_diagnostic \
    "$ROOT/tests/diagnostics/stage2/e2s28_value_if_branch.kofun" \
    "$ROOT/tests/diagnostics/stage2/e2s28_value_if_branch.stderr"
expect_stage2_diagnostic \
    "$CASES/if_value_void_branch.kofun" \
    "$CASES/if_value_void_branch.stdout"

"$WORK/kofun-stage2" \
    "$CASES/match_bool.kofun" \
    "$WORK/match-bool.c" \
    "$WORK/match-bool.ir" \
    "$WORK/match-bool.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/match-bool.c" -o "$WORK/match-bool"
"$WORK/match-bool" \
    >"$WORK/match-bool.stdout" 2>"$WORK/match-bool.stderr"
cmp "$CASES/match_bool.stdout" "$WORK/match-bool.stdout" ||
    fail "Stage 2 Bool match output differs"
test ! -s "$WORK/match-bool.stderr" ||
    fail "Stage 2 Bool match wrote unexpected stderr"
printf '%s\n' "PASS executable Stage 2 exhaustive Bool match"

"$WORK/kofun-stage2" \
    "$CASES/match_guard.kofun" \
    "$WORK/match-guard.c" \
    "$WORK/match-guard.ir" \
    "$WORK/match-guard.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/match-guard.c" -o "$WORK/match-guard"
"$WORK/match-guard" \
    >"$WORK/match-guard.stdout" 2>"$WORK/match-guard.stderr"
cmp "$CASES/match_guard.stdout" "$WORK/match-guard.stdout" ||
    fail "Stage 2 guarded Bool match output differs"
test ! -s "$WORK/match-guard.stderr" ||
    fail "Stage 2 guarded Bool match wrote unexpected stderr"
KOFUN_BUILD_DIR="$WORK/guard-cli-stage1" \
KOFUN_STAGE2_BUILD_DIR="$WORK/guard-cli-stage2" \
    "$ROOT/bin/kofun" run "$CASES/match_guard.kofun" \
    >"$WORK/match-guard-cli.stdout" 2>"$WORK/match-guard-cli.stderr"
cmp "$CASES/match_guard.stdout" "$WORK/match-guard-cli.stdout" ||
    fail "public kofun run guarded Bool match output differs"
test ! -s "$WORK/match-guard-cli.stderr" ||
    fail "public kofun run guarded Bool match wrote stderr"
printf '%s\n' "PASS ordered Stage 2 Bool match guards"

"$WORK/kofun-stage2" \
    "$CASES/match_guard_error.kofun" \
    "$WORK/match-guard-error.c" \
    "$WORK/match-guard-error.ir" \
    "$WORK/match-guard-error.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/match-guard-error.c" -o "$WORK/match-guard-error"
set +e
"$WORK/match-guard-error" \
    >"$WORK/match-guard-error.stdout" \
    2>"$WORK/match-guard-error.stderr"
match_guard_error_status=$?
set -e
test "$match_guard_error_status" -eq 1 ||
    fail "selected failing match guard returned $match_guard_error_status"
test ! -s "$WORK/match-guard-error.stdout" ||
    fail "selected failing match guard wrote stdout"
cmp \
    "$CASES/match_guard_error.stderr" \
    "$WORK/match-guard-error.stderr" ||
    fail "selected failing match guard diagnostic differs"
printf '%s\n' "PASS selected-only Stage 2 match guard evaluation"

"$WORK/kofun-stage2" \
    "$CASES/match_value.kofun" \
    "$WORK/match-value.c" \
    "$WORK/match-value.ir" \
    "$WORK/match-value.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/match-value.c" -o "$WORK/match-value"
"$WORK/match-value" \
    >"$WORK/match-value.stdout" 2>"$WORK/match-value.stderr"
cmp "$CASES/match_value.stdout" "$WORK/match-value.stdout" ||
    fail "Stage 2 value-position Bool match output differs"
test ! -s "$WORK/match-value.stderr" ||
    fail "Stage 2 value-position Bool match wrote unexpected stderr"
KOFUN_BUILD_DIR="$WORK/match-value-cli-stage1" \
KOFUN_STAGE2_BUILD_DIR="$WORK/match-value-cli-stage2" \
    "$ROOT/bin/kofun" run "$CASES/match_value.kofun" \
    >"$WORK/match-value-cli.stdout" 2>"$WORK/match-value-cli.stderr"
cmp "$CASES/match_value.stdout" "$WORK/match-value-cli.stdout" ||
    fail "public kofun run value-position Bool match output differs"
test ! -s "$WORK/match-value-cli.stderr" ||
    fail "public kofun run value-position Bool match wrote stderr"
printf '%s\n' "PASS executable Stage 2 value-position Bool match"

"$WORK/kofun-stage2" \
    "$CASES/match_value_error.kofun" \
    "$WORK/match-value-error.c" \
    "$WORK/match-value-error.ir" \
    "$WORK/match-value-error.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/match-value-error.c" -o "$WORK/match-value-error"
set +e
"$WORK/match-value-error" \
    >"$WORK/match-value-error.stdout" \
    2>"$WORK/match-value-error.stderr"
match_value_error_status=$?
set -e
test "$match_value_error_status" -eq 1 ||
    fail "selected failing value-match arm returned $match_value_error_status"
test ! -s "$WORK/match-value-error.stdout" ||
    fail "selected failing value-match arm wrote stdout"
cmp \
    "$CASES/match_value_error.stderr" \
    "$WORK/match-value-error.stderr" ||
    fail "selected failing value-match arm diagnostic differs"
printf '%s\n' "PASS selected-only Stage 2 value-match arm evaluation"

"$WORK/kofun-stage2" \
    "$CASES/enum_match.kofun" \
    "$WORK/enum-match.c" \
    "$WORK/enum-match.ir" \
    "$WORK/enum-match.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/enum-match.c" -o "$WORK/enum-match"
"$WORK/enum-match" \
    >"$WORK/enum-match.stdout" 2>"$WORK/enum-match.stderr"
cmp "$CASES/enum_match.stdout" "$WORK/enum-match.stdout" ||
    fail "Stage 2 payload-free enum match output differs"
test ! -s "$WORK/enum-match.stderr" ||
    fail "Stage 2 payload-free enum match wrote unexpected stderr"
KOFUN_BUILD_DIR="$WORK/enum-match-cli-stage1" \
KOFUN_STAGE2_BUILD_DIR="$WORK/enum-match-cli-stage2" \
    "$ROOT/bin/kofun" run "$CASES/enum_match.kofun" \
    >"$WORK/enum-match-cli.stdout" 2>"$WORK/enum-match-cli.stderr"
cmp "$CASES/enum_match.stdout" "$WORK/enum-match-cli.stdout" ||
    fail "public kofun run payload-free enum match output differs"
test ! -s "$WORK/enum-match-cli.stderr" ||
    fail "public kofun run payload-free enum match wrote stderr"
grep '^type|Signal|3|' "$WORK/enum-match.ir" >/dev/null ||
    fail "Stage 2 IR omitted the Signal type record"
grep '^constructor|Red|Signal|0|' "$WORK/enum-match.ir" >/dev/null ||
    fail "Stage 2 IR omitted the Red constructor tag"
grep '^constructor|Green|Signal|1|' "$WORK/enum-match.ir" >/dev/null ||
    fail "Stage 2 IR omitted the Green constructor tag"
grep '^constructor|Blue|Signal|2|' "$WORK/enum-match.ir" >/dev/null ||
    fail "Stage 2 IR omitted the Blue constructor tag"
printf '%s\n' "PASS executable Stage 2 payload-free enum match"

# Issue #782. Every printed value below is read back out of the matched
# constructor, so a tag-only lowering cannot produce this output.
"$WORK/kofun-stage2" \
    "$CASES/enum_payload_match.kofun" \
    "$WORK/enum-payload.c" \
    "$WORK/enum-payload.ir" \
    "$WORK/enum-payload.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/enum-payload.c" -o "$WORK/enum-payload"
"$WORK/enum-payload" \
    >"$WORK/enum-payload.stdout" 2>"$WORK/enum-payload.stderr"
cmp "$CASES/enum_payload_match.stdout" "$WORK/enum-payload.stdout" ||
    fail "Stage 2 payload enum match output differs"
test ! -s "$WORK/enum-payload.stderr" ||
    fail "Stage 2 payload enum match wrote unexpected stderr"
KOFUN_BUILD_DIR="$WORK/enum-payload-cli-stage1" \
KOFUN_STAGE2_BUILD_DIR="$WORK/enum-payload-cli-stage2" \
    "$ROOT/bin/kofun" run "$CASES/enum_payload_match.kofun" \
    >"$WORK/enum-payload-cli.stdout" 2>"$WORK/enum-payload-cli.stderr"
cmp "$CASES/enum_payload_match.stdout" "$WORK/enum-payload-cli.stdout" ||
    fail "public kofun run payload enum match output differs"
test ! -s "$WORK/enum-payload-cli.stderr" ||
    fail "public kofun run payload enum match wrote stderr"
# `Failed` is declared after a payload-carrying constructor, so a walker that
# stopped at the payload parentheses would drop it from the constructor set and
# silently weaken exhaustiveness instead of failing.
grep '^type|Reply|3|' "$WORK/enum-payload.ir" >/dev/null ||
    fail "Stage 2 IR did not record all three Reply constructors"
grep '^constructor|Failed|Reply|2|' "$WORK/enum-payload.ir" >/dev/null ||
    fail "Stage 2 IR omitted a constructor declared after a payload"
printf '%s\n' "PASS executable Stage 2 payload enum match"

# Payload enum values also cross ordinary function boundaries.  This fixture
# constructs one directly in argument position, returns one from a function,
# stores that result in an explicitly typed binding, and re-matches the value
# held by a binding catch-all.
"$WORK/kofun-stage2" \
    "$ADT_CASES/enum_payload_functions.kofun" \
    "$WORK/enum-payload-functions.c" \
    "$WORK/enum-payload-functions.ir" \
    "$WORK/enum-payload-functions.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/enum-payload-functions.c" -o "$WORK/enum-payload-functions"
"$WORK/enum-payload-functions" \
    >"$WORK/enum-payload-functions.stdout" \
    2>"$WORK/enum-payload-functions.stderr"
cmp \
    "$ADT_CASES/enum_payload_functions.stdout" \
    "$WORK/enum-payload-functions.stdout" ||
    fail "Stage 2 payload enum function output differs"
test ! -s "$WORK/enum-payload-functions.stderr" ||
    fail "Stage 2 payload enum function wrote unexpected stderr"
grep '^static KofunEnumValue kofun_fn_make_reply' \
    "$WORK/enum-payload-functions.c" >/dev/null ||
    fail "Stage 2 did not lower the enum-returning function"
grep '^static int64_t kofun_fn_consume(KofunEnumValue ' \
    "$WORK/enum-payload-functions.c" >/dev/null ||
    fail "Stage 2 did not lower the enum parameter"
KOFUN_BUILD_DIR="$WORK/enum-payload-functions-cli-stage1" \
KOFUN_STAGE2_BUILD_DIR="$WORK/enum-payload-functions-cli-stage2" \
    "$ROOT/bin/kofun" run "$ADT_CASES/enum_payload_functions.kofun" \
    >"$WORK/enum-payload-functions-cli.stdout" \
    2>"$WORK/enum-payload-functions-cli.stderr"
cmp \
    "$ADT_CASES/enum_payload_functions.stdout" \
    "$WORK/enum-payload-functions-cli.stdout" ||
    fail "public kofun run payload enum function output differs"
test ! -s "$WORK/enum-payload-functions-cli.stderr" ||
    fail "public kofun run payload enum function wrote stderr"
printf '%s\n' "PASS executable Stage 2 payload enum function boundaries"

expect_stage2_diagnostic \
    "$CASES/enum_payload_pattern_arity.kofun" \
    "$CASES/enum_payload_pattern_arity.stdout"
expect_stage2_diagnostic \
    "$CASES/enum_payload_pattern_missing.kofun" \
    "$CASES/enum_payload_pattern_missing.stdout"
expect_stage2_diagnostic \
    "$CASES/enum_payload_initializer_arity.kofun" \
    "$CASES/enum_payload_initializer_arity.stdout"
expect_stage2_diagnostic \
    "$CASES/enum_payload_unsupported_field.kofun" \
    "$CASES/enum_payload_unsupported_field.stdout"
expect_stage2_diagnostic \
    "$CASES/enum_payload_multiple_fields.kofun" \
    "$CASES/enum_payload_multiple_fields.stdout"

expect_stage2_diagnostic \
    "$CASES/match_missing_false.kofun" \
    "$CASES/match_missing_false.stdout"
expect_stage2_diagnostic \
    "$CASES/match_missing_true.kofun" \
    "$CASES/match_missing_true.stdout"
expect_stage2_diagnostic \
    "$CASES/match_duplicate_true.kofun" \
    "$CASES/match_duplicate_true.stdout"
expect_stage2_diagnostic \
    "$CASES/match_after_catchall.kofun" \
    "$CASES/match_after_catchall.stdout"
expect_stage2_diagnostic \
    "$CASES/match_unreachable_catchall.kofun" \
    "$CASES/match_unreachable_catchall.stdout"
expect_stage2_diagnostic \
    "$CASES/match_guard_non_exhaustive.kofun" \
    "$CASES/match_guard_non_exhaustive.stdout"
expect_stage2_diagnostic \
    "$CASES/match_non_bool.kofun" \
    "$CASES/match_non_bool.stdout"
expect_stage2_diagnostic \
    "$ROOT/tests/diagnostics/stage2/e2s29_match_guard.kofun" \
    "$ROOT/tests/diagnostics/stage2/e2s29_match_guard.stderr"
expect_stage2_diagnostic \
    "$CASES/match_value_non_exhaustive.kofun" \
    "$CASES/match_value_non_exhaustive.stdout"
expect_stage2_diagnostic \
    "$CASES/match_value_duplicate.kofun" \
    "$CASES/match_value_duplicate.stdout"
expect_stage2_diagnostic \
    "$ROOT/tests/diagnostics/stage2/e2s30_match_value_arm.kofun" \
    "$ROOT/tests/diagnostics/stage2/e2s30_match_value_arm.stderr"
expect_stage2_diagnostic \
    "$CASES/enum_match_missing.kofun" \
    "$CASES/enum_match_missing.stdout"
expect_stage2_diagnostic \
    "$CASES/enum_match_duplicate.kofun" \
    "$CASES/enum_match_duplicate.stdout"
expect_stage2_diagnostic \
    "$CASES/enum_match_guard_non_exhaustive.kofun" \
    "$CASES/enum_match_guard_non_exhaustive.stdout"
expect_stage2_diagnostic \
    "$CASES/enum_match_constructor_mismatch.kofun" \
    "$CASES/enum_match_constructor_mismatch.stdout"
expect_stage2_diagnostic \
    "$CASES/enum_match_tag_escape.kofun" \
    "$CASES/enum_match_tag_escape.stdout"
expect_stage2_diagnostic \
    "$CASES/enum_constructor_escape.kofun" \
    "$CASES/enum_constructor_escape.stdout"
expect_stage2_diagnostic \
    "$ROOT/tests/diagnostics/stage2/e2s31_enum_duplicate_constructor.kofun" \
    "$ROOT/tests/diagnostics/stage2/e2s31_enum_duplicate_constructor.stderr"
expect_stage2_diagnostic \
    "$ROOT/tests/diagnostics/stage2/e2s32_enum_unknown_constructor.kofun" \
    "$ROOT/tests/diagnostics/stage2/e2s32_enum_unknown_constructor.stderr"

grep '^# Bounded Bool match exhaustiveness' "$MATCH_SPEC" >/dev/null ||
    fail "bounded Bool match specification is missing"
for code in E2S24 E2S25 E2S26 E2S29 E2S30; do
    grep "\`$code\`" "$MATCH_SPEC" >/dev/null ||
        fail "bounded Bool match specification omits $code"
done
printf '%s\n' "PASS bounded Bool match specification"

grep '^# Bounded concrete enum match exhaustiveness' \
    "$ENUM_MATCH_SPEC" >/dev/null ||
    fail "bounded concrete enum match specification is missing"
for code in E2S25 E2S26 E2S29 E2S31 E2S32; do
    grep "\`$code\`" "$ENUM_MATCH_SPEC" >/dev/null ||
        fail "bounded enum match specification omits $code"
done
grep 'at most 32 enum types' "$ENUM_MATCH_SPEC" >/dev/null ||
    fail "bounded enum match specification omits the type limit"
grep 'constructors in one enum' "$ENUM_MATCH_SPEC" >/dev/null ||
    fail "bounded enum match specification omits the constructor limit"
printf '%s\n' "PASS bounded concrete enum match specification"

"$WORK/kofun-stage2" \
    "$CASES/structural_surface.kofun" \
    "$WORK/structural.kofun" \
    "$WORK/structural.ir" \
    "$WORK/structural.tokens" >/dev/null
cmp "$CASES/structural_surface.kofun" "$WORK/structural.kofun" ||
    fail "Stage 2 structural projection changed source bytes"
grep '^function|classify|1|' "$WORK/structural.ir" >/dev/null ||
    fail "Stage 2 IR did not record classify arity"
grep '^function|future_surface|0|' "$WORK/structural.ir" >/dev/null ||
    fail "Stage 2 IR did not record future_surface arity"
grep '^function-count|2$' "$WORK/structural.ir" >/dev/null ||
    fail "Stage 2 IR function count differs"
printf '%s\n' "PASS structural-only Stage 2 surface projection"

"$WORK/kofun-stage2" \
    "$CASES/unicode_identifiers.kofun" \
    "$WORK/unicode.c" \
    "$WORK/unicode.ir" \
    "$WORK/unicode.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/unicode.c" -o "$WORK/unicode"
unicode_stage2_output=$("$WORK/unicode")
test "$unicode_stage2_output" = 42 ||
    fail "Stage 2 Japanese/Hangul identifiers did not print 42"
grep '^function|main|0|' "$WORK/unicode.ir" >/dev/null ||
    fail "Stage 2 Unicode IR did not record fn main"
printf '%s\n' "PASS executable: Unicode identifiers in Stage 2"

# Lambdas were one of this checkpoint's unsupported fixtures until #703 lifted
# them to top-level functions. The assertion moved with the capability: what is
# gated now is that the bound lambda runs, not that it is refused.
"$WORK/kofun-stage2" \
    "$CASES/lambda_binding.kofun" \
    "$WORK/lambda.c" \
    "$WORK/lambda.ir" \
    "$WORK/lambda.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/lambda.c" -o "$WORK/lambda"
lambda_stage2_output=$("$WORK/lambda")
# One line per shape #703 scopes: an annotated parameter read in the body, the
# two-parameter form, a capture of an enclosing binding, a lambda calling
# another lambda, and the bare single-parameter form `x => e`.
test "$lambda_stage2_output" = "$(printf '42\n42\n42\n12\n42')" ||
    fail "Stage 2 lambda bindings printed: $lambda_stage2_output"
grep 'kofun_lambda_' "$WORK/lambda.c" >/dev/null ||
    fail "Stage 2 lambda binding was not lifted to a top-level function"
printf '%s\n' "PASS executable: lambda bindings lifted, captured, and called"

# `IDENT => expr` is a bare lambda in expression position and a match arm in
# arm position. This case puts both in one function, and names a lambda binding
# after an enum constructor that is also matched, so a rule that decided by
# token shape rather than by position would fail here instead of silently
# changing what 81 shipped match arms mean.
"$WORK/kofun-stage2" \
    "$CASES/lambda_bare_and_match_arm.kofun" \
    "$WORK/bare-lambda.c" \
    "$WORK/bare-lambda.ir" \
    "$WORK/bare-lambda.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/bare-lambda.c" -o "$WORK/bare-lambda"
bare_lambda_output=$("$WORK/bare-lambda")
test "$bare_lambda_output" = "$(printf '42\n111\n7')" ||
    fail "bare lambda and match arm printed: $bare_lambda_output"
printf '%s\n' \
    "PASS executable: bare \`x => e\` and match arms coexist in one function"

# #703 criterion 3. The case computes each value twice — once through a named
# function passed as an argument, once through a lambda written at the call
# site — so identical observations are what is gated, not merely that a lambda
# argument compiles.
"$WORK/kofun-stage2" \
    "$CASES/lambda_argument.kofun" \
    "$WORK/lambda-argument.c" \
    "$WORK/lambda-argument.ir" \
    "$WORK/lambda-argument.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/lambda-argument.c" -o "$WORK/lambda-argument"
lambda_argument_output=$("$WORK/lambda-argument")
# One line per pair: `Int -> Int` by name then by lambda, `(Int, Int) -> Int`
# by name then by lambda, `() -> Int` by name, a `let`-bound lambda passed by
# name, and a lambda argument nested inside another call's argument.
test "$lambda_argument_output" = "$(printf '42\n42\n42\n42\n7\n42\n42')" ||
    fail "Stage 2 lambda arguments printed: $lambda_argument_output"
grep 'int64_t (\*k_b[0-9]*)(int64_t)' "$WORK/lambda-argument.c" >/dev/null ||
    fail "callable parameter did not lower to a C function pointer"
grep 'int64_t (\*k_b[0-9]*)(void)' "$WORK/lambda-argument.c" >/dev/null ||
    fail "\`() -> Int\` did not lower to a zero-argument function pointer"
printf '%s\n' \
    "PASS executable: lambda arguments observe as their named equivalents"

# #703 criterion 4: a shipped example using lambdas compiles and is run by a
# gate. It goes through the public `kofun run`, not the Stage 2 binary this
# script builds, because the claim being gated is that a reader who copies the
# example gets the output it shows.
KOFUN_BUILD_DIR="$WORK/example-stage1" \
KOFUN_STAGE2_BUILD_DIR="$WORK/example-stage2" \
    "$ROOT/bin/kofun" run "$ROOT/examples/lambdas.kofun" \
    >"$WORK/example-lambdas.stdout" 2>"$WORK/example-lambdas.stderr"
test "$(cat "$WORK/example-lambdas.stdout")" = \
    "$(printf '42\n42\n42\n42\n42\n42\n42')" ||
    fail "examples/lambdas.kofun printed: $(cat "$WORK/example-lambdas.stdout")"
test ! -s "$WORK/example-lambdas.stderr" ||
    fail "examples/lambdas.kofun wrote unexpected stderr"
printf '%s\n' "PASS executable: examples/lambdas.kofun runs through kofun run"

# A capturing lambda cannot be a function value here: lifting passes captures
# as trailing parameters, so its address is not the declared callable. #703
# puts closure conversion out of scope, so this must refuse explicitly rather
# than emit C whose observations would not match.
expect_stage2_diagnostic \
    "$ROOT/tests/diagnostics/stage2/e2s96_capturing_lambda_argument.kofun" \
    "$ROOT/tests/diagnostics/stage2/e2s96_capturing_lambda_argument.stderr"

# #552 removed `Fn[...]` and every normative document requires a targeted
# rewrite rather than a bare rejection, so the rewrite itself is gated.
expect_stage2_diagnostic \
    "$ROOT/tests/diagnostics/stage2/e2s97_removed_callable_notation.kofun" \
    "$ROOT/tests/diagnostics/stage2/e2s97_removed_callable_notation.stderr"
grep -- '-> Text' "$NAMING_SPEC" >/dev/null ||
    fail "callable type notation is missing from docs/NAMING.md"
grep -- 'no empirical answer' "$NAMING_SPEC" >/dev/null ||
    fail "docs/NAMING.md must record that the readability question is unmeasured"
if grep -l -- 'Fn\[' "$ROOT"/examples/*.kofun >/dev/null 2>&1; then
    fail "a shipped example still uses the removed \`Fn[...]\` notation"
fi
printf '%s\n' "PASS: one callable notation, its rejected alternatives, and its rewrite"

expect_stage2_unsupported "$CASES/unsupported_owned_binding.kofun"
expect_stage2_unsupported "$CASES/unsupported_else_if.kofun"
expect_stage2_unsupported "$CASES/unsupported_for.kofun"

# `while` was refused here until #1128 lowered it. The fixture changed sides
# rather than being deleted: a subject that reaches the Core still has to be
# executed by this gate, or nothing here would notice it regressing back out.
expect_stage2_lowers "$CASES/lowered_while.kofun"

# The block-body lambda, which `spec/syntax/call-arguments-v1.md` states as
# accepted design and `spec/grammar.ebnf` deliberately does not derive. Pinning
# it keeps those two surfaces and the compiler from drifting apart silently.
#
# It is not a #35-#47 subject and is deliberately absent from the coverage line
# below; it lives here because this is the gate that already builds Stage 2 and
# owns `expect_stage2_unsupported`. The `call-arguments` gate cannot host it:
# that one checks a JavaScript model and never runs the compiler, which is
# exactly why the disagreement survived.
#
# The exact diagnostic is asserted, not just that some `E2S` code fires,
# because the current one is wrong in an informative way: the parameter list is
# not recognised, so `value` never binds and the reader is told about a symbol
# they did not write. A named refusal would change this line, and it should.
expect_stage2_unsupported "$CASES/unsupported_block_lambda.kofun"
grep -Fq 'error[E2S35]: unknown lexical binding `value`' \
    "$WORK/unsupported_block_lambda.stdout" ||
    fail 'unsupported_block_lambda: the pinned misparse diagnostic changed; if a named block-body refusal landed, update this assertion and spec/grammar.ebnf together'
printf '%s\n' \
    'PASS unsupported: block-body lambda is refused, by misparse, and pinned'

set +e
"$WORK/kofun-stage2" \
    "$CASES/invalid_if_condition.kofun" \
    "$WORK/invalid-if.c" \
    "$WORK/invalid-if.ir" \
    "$WORK/invalid-if.tokens" \
    >"$WORK/invalid-if.stdout" 2>"$WORK/invalid-if.stderr"
invalid_if_status=$?
set -e
test "$invalid_if_status" -eq 1 ||
    fail "invalid if condition unexpectedly returned $invalid_if_status"
test ! -e "$WORK/invalid-if.c" ||
    fail "invalid if condition emitted C"
test ! -s "$WORK/invalid-if.stderr" ||
    fail "invalid if condition wrote unexpected stderr"
grep '^error\[E2S23\]: if condition must be Bool or an Int comparison at byte ' \
    "$WORK/invalid-if.stdout" >/dev/null ||
    fail "invalid if condition did not emit E2S23"
printf '%s\n' "PASS diagnostic: invalid if condition"

printf '%s\n' \
    "PASS: syntax issues #35-#47 bootstrap capability checkpoint" \
    "coverage: 13 subjects; 5 partial; 5 Core-implemented; 3 unsupported via 3 fixtures"

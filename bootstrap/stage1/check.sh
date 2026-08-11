#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SOURCE="$ROOT/bootstrap/stage1/compiler.kofun"
SEED="$ROOT/bootstrap/stage1/compiler.c"
FIXTURE="$ROOT/bootstrap/fixtures/answer.kofun"
FUNCTION_FIXTURE="$ROOT/bootstrap/selfhost/driver/corpus_function.kofun"
FUNCTION_C="$ROOT/bootstrap/selfhost/driver/corpus_function.c"
FUNCTION_STDOUT="$ROOT/bootstrap/selfhost/driver/corpus_function.stdout"
BOOL_FIXTURE="$ROOT/bootstrap/selfhost/driver/corpus_bool.kofun"
BOOL_C="$ROOT/bootstrap/selfhost/driver/corpus_bool.c"
BOOL_STDOUT="$ROOT/bootstrap/selfhost/driver/corpus_bool.stdout"
BRANCH_FIXTURE="$ROOT/bootstrap/selfhost/driver/corpus_branch.kofun"
BRANCH_C="$ROOT/bootstrap/selfhost/driver/corpus_branch.c"
BRANCH_STDOUT="$ROOT/bootstrap/selfhost/driver/corpus_branch.stdout"
LOOP_FIXTURE="$ROOT/bootstrap/selfhost/driver/corpus_loop.kofun"
LOOP_C="$ROOT/bootstrap/selfhost/driver/corpus_loop.c"
LOOP_STDOUT="$ROOT/bootstrap/selfhost/driver/corpus_loop.stdout"
TEXT_FIXTURE="$ROOT/bootstrap/selfhost/driver/corpus_text.kofun"
TEXT_C="$ROOT/bootstrap/selfhost/driver/corpus_text.c"
TEXT_STDOUT="$ROOT/bootstrap/selfhost/driver/corpus_text.stdout"
TEXT_EQUAL_FIXTURE="$ROOT/bootstrap/selfhost/driver/corpus_text_equality_only.kofun"
TEXT_EQUAL_C="$ROOT/bootstrap/selfhost/driver/corpus_text_equality_only.c"
TEXT_EQUAL_STDOUT="$ROOT/bootstrap/selfhost/driver/corpus_text_equality_only.stdout"
LIST_TEXT_FIXTURE="$ROOT/bootstrap/selfhost/driver/corpus_list_text.kofun"
LIST_TEXT_C="$ROOT/bootstrap/selfhost/driver/corpus_list_text.c"
LIST_TEXT_STDOUT="$ROOT/bootstrap/selfhost/driver/corpus_list_text.stdout"
BUILTINS_FIXTURE="$ROOT/bootstrap/selfhost/driver/corpus_builtins.kofun"
BUILTINS_C="$ROOT/bootstrap/selfhost/driver/corpus_builtins.c"
BUILTINS_INPUT="$ROOT/bootstrap/selfhost/driver/corpus_builtins.input"
BUILTINS_OUTPUT="$ROOT/bootstrap/selfhost/driver/corpus_builtins.output"
BUILTINS_STDOUT="$ROOT/bootstrap/selfhost/driver/corpus_builtins.stdout"
BUILTIN_REJECTS="$ROOT/bootstrap/selfhost/driver/corpus_builtin_rejects.tsv"
WORK="${KOFUN_STAGE1_WORK:-$ROOT/build/bootstrap-stage1}"
CC="${CC:-cc}"
ASSERT_CONTEXT=stage1
. "$ROOT/tests/assertions/assert.sh"

mkdir -p "$WORK"

(
    cd "$ROOT/bootstrap/stage1"
    "$ROOT/bin/kofun-digest" -c SHA256SUMS
)

"$CC" -std=c11 -O2 -Wall -Wextra -Werror "$SEED" -lm -o "$WORK/kofun-stage1"
"$WORK/kofun-stage1" "$FIXTURE" "$WORK/answer.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror "$WORK/answer.c" -o "$WORK/answer"
answer=$("$WORK/answer")
assert_eq "answer" "$answer" "42"

# Declaration profile: a non-main function with an explicit result type is
# accepted by the audited hand-port, emits the pinned C, and executes through
# an ordinary call from main.
"$WORK/kofun-stage1" "$FUNCTION_FIXTURE" "$WORK/function.c"
cmp "$FUNCTION_C" "$WORK/function.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/function.c" -o "$WORK/function"
"$WORK/function" >"$WORK/function.stdout"
cmp "$FUNCTION_STDOUT" "$WORK/function.stdout"

"$WORK/kofun-stage1" "$BOOL_FIXTURE" "$WORK/bool.c"
cmp "$BOOL_C" "$WORK/bool.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror "$WORK/bool.c" -o "$WORK/bool"
"$WORK/bool" >"$WORK/bool.stdout"
cmp "$BOOL_STDOUT" "$WORK/bool.stdout"

# Nested blocks: the emitted C keeps one brace per Kofun block, and executing
# it proves the skipped `else if` condition and the short-circuited `||`
# operand — both `1 // 0` — were never evaluated.
"$WORK/kofun-stage1" "$BRANCH_FIXTURE" "$WORK/branch.c"
cmp "$BRANCH_C" "$WORK/branch.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror "$WORK/branch.c" -o "$WORK/branch"
"$WORK/branch" >"$WORK/branch.stdout"
cmp "$BRANCH_STDOUT" "$WORK/branch.stdout"

# Loops: the emitted C keeps one brace pair per loop block, evaluates each
# range end once into the enclosing scope, and scopes the bound name to its
# own block. Executing it proves the bodies of a false `while` and of an empty
# range were never entered — each contains `1 // 0`.
"$WORK/kofun-stage1" "$LOOP_FIXTURE" "$WORK/loop.c"
cmp "$LOOP_C" "$WORK/loop.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror "$WORK/loop.c" -o "$WORK/loop"
"$WORK/loop" >"$WORK/loop.stdout"
cmp "$LOOP_STDOUT" "$WORK/loop.stdout"

# Text: literals and their three escapes survive as literals, while `+`,
# equality and print lower to the emitted program's bounded Text runtime. The
# scanner must ignore operator and parenthesis bytes inside a literal.
"$WORK/kofun-stage1" "$TEXT_FIXTURE" "$WORK/text.c"
cmp "$TEXT_C" "$WORK/text.c"
assert_not_grep "text.c" -F 'greeting + " " + "compiler"' "$WORK/text.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror "$WORK/text.c" -o "$WORK/text"
"$WORK/text" >"$WORK/text.stdout"
cmp "$TEXT_STDOUT" "$WORK/text.stdout"

# A comparison of two literals needs the Text equality runtime even though it
# emits no Text-typed local. Keep that conditional-emission boundary explicit.
"$WORK/kofun-stage1" "$TEXT_EQUAL_FIXTURE" "$WORK/text-equality-only.c"
cmp "$TEXT_EQUAL_C" "$WORK/text-equality-only.c"
assert_grep "text-equality-only.c" \
    -F 'static bool kofun_rt_text_equal' "$WORK/text-equality-only.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/text-equality-only.c" -o "$WORK/text-equality-only"
"$WORK/text-equality-only" >"$WORK/text-equality-only.stdout"
cmp "$TEXT_EQUAL_STDOUT" "$WORK/text-equality-only.stdout"

# List[Text]: `chars` constructs a byte-oriented list, `len` observes its
# length, and postfix indexing returns one-byte Text from both Text and lists.
# The UTF-8 fixture pins the Stage 2 profile's byte semantics.
"$WORK/kofun-stage1" "$LIST_TEXT_FIXTURE" "$WORK/list-text.c"
cmp "$LIST_TEXT_C" "$WORK/list-text.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/list-text.c" -o "$WORK/list-text"
"$WORK/list-text" >"$WORK/list-text.stdout"
cmp "$LIST_TEXT_STDOUT" "$WORK/list-text.stdout"

# All 15 Stage 2 profile builtins: argv and file I/O, Text/List length,
# character predicates, search/slice/trim, Unicode validation, and stdout.
# The fixture is deliberately ASCII at is_xid_continue, preserving the
# documented host-seed/source Unicode deviation while linking the real Unicode
# runtime used by Kofun-compiled source.
"$WORK/kofun-stage1" "$BUILTINS_FIXTURE" "$WORK/builtins.c"
cmp "$BUILTINS_C" "$WORK/builtins.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I "$ROOT/unicode" \
    "$WORK/builtins.c" -o "$WORK/builtins"
"$WORK/builtins" "$BUILTINS_INPUT" "$WORK/builtins.output" \
    >"$WORK/builtins.stdout"
cmp "$BUILTINS_STDOUT" "$WORK/builtins.stdout"
cmp "$BUILTINS_OUTPUT" "$WORK/builtins.output"
assert_eq "corpus_answer.c digest" \
    "$("$ROOT/bin/kofun-digest" "$ROOT/bootstrap/selfhost/driver/corpus_answer.c" | awk '{ print $1 }')" \
    673d6e62ad7947fc878420eea1dffb9e3f13e942adda71f1f972b31575616499

# A well-typed index may still fail at runtime. Both Text and List[Text] bounds
# traps must exit 1, write only the pinned R010 diagnostic, and produce no
# stdout.
runtime_trap_corpus() {
    stem=$1
    "$WORK/kofun-stage1" \
        "$ROOT/bootstrap/selfhost/driver/$stem.kofun" "$WORK/$stem.c"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror \
        "$WORK/$stem.c" -o "$WORK/$stem"
    set +e
    "$WORK/$stem" >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    status=$?
    set -e
    assert_num "exit status for $stem" "$status" -eq 1
    assert_file_empty "$stem.stdout" "$WORK/$stem.stdout"
    cmp "$ROOT/bootstrap/selfhost/driver/$stem.stderr" "$WORK/$stem.stderr"
}
runtime_trap_corpus corpus_trap_list_index
runtime_trap_corpus corpus_trap_text_index

# The refusal corpus is the set of files, not a list written beside it. Both
# this gate and check-compiler-driver.sh used to name all of them by hand, so a
# fixture added to one and forgotten in the other would have lowered coverage
# with nothing to say so. The count is asserted because a glob alone cannot tell
# "a fixture was deliberately removed" from "a fixture stopped being found":
# changing it is a reviewable edit, and REJECT_FIXTURE_COUNT is the one number
# both gates agree on.
REJECT_FIXTURE_COUNT=31
reject_checked=0
for fixture in "$ROOT"/bootstrap/selfhost/driver/corpus_reject_*.kofun
do
    output="$WORK/$(basename "$fixture" .kofun).c"
    rm -f "$output"
    set +e
    "$WORK/kofun-stage1" "$fixture" "$output" >"$output.stdout"
    status=$?
    set -e
    assert_num "refusal status for $fixture" "$status" -ne 0
    assert_absent "C11 output for $fixture" "$output"
    golden="${fixture%.kofun}.stdout"
    cmp "$golden" "$output.stdout"
    reject_checked=$((reject_checked + 1))
done
test "$reject_checked" -eq "$REJECT_FIXTURE_COUNT" || {
    printf 'FAIL: ran %s refusal fixtures, expected %s\n' \
        "$reject_checked" "$REJECT_FIXTURE_COUNT" >&2
    exit 1
}

# Exact builtin surface: every profile builtin has one wrong-arity and one
# wrong-type case. The cases live in one reviewable matrix but are expanded into
# full sources before the audited seed sees them.
BUILTIN_REJECT_COUNT=30
builtin_reject_checked=0
while IFS='|' read -r label statement
do
    fixture="$WORK/builtin-reject-$label.kofun"
    {
        printf '%s\n' 'fn main() {'
        printf '    %s\n' "$statement"
        printf '%s\n' '    print(0)' '}'
    } >"$fixture"
    output="$WORK/builtin-reject-$label.c"
    rm -f "$output"
    set +e
    "$WORK/kofun-stage1" "$fixture" "$output" >"$output.stdout"
    status=$?
    set -e
    assert_num "refusal status for builtin case $label" "$status" -ne 0
    assert_absent "C11 output for builtin case $label" "$output"
    cmp "$ROOT/bootstrap/selfhost/driver/goldens/builtin-$label.stdout" \
        "$output.stdout"
    builtin_reject_checked=$((builtin_reject_checked + 1))
done < "$BUILTIN_REJECTS"
test "$builtin_reject_checked" -eq "$BUILTIN_REJECT_COUNT" || {
    printf 'FAIL: ran %s builtin refusals, expected %s\n' \
        "$builtin_reject_checked" "$BUILTIN_REJECT_COUNT" >&2
    exit 1
}

printf '%s\n' \
    "PASS: Python-free Kofun Stage 1 built with $CC" \
    "PASS: compiled fixture returned $answer" \
    "PASS: Int/Bool Core accepts comparisons and refuses typed boundary crossings" \
    "PASS: nested if/else blocks scope their bindings and refuse a misplaced else" \
    "PASS: while and for-range loops nest, bound their range once, and scope their bound name" \
    "PASS: Text literals, concatenation, equality and printing use the bounded emitted runtime" \
    "PASS: List[Text] construction, length and Text/List indexing use byte semantics and bounded traps" \
    "PASS: all 15 profile builtins and all 30 arity/type refusals use audited runtime shims"

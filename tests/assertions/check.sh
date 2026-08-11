#!/bin/sh
set -eu

# Counts assertions that fail without saying anything, and holds every file to a
# recorded budget.
#
# A silent assertion is a `test`, `[`, or silenced `grep` command that
#
#   1. carries no `||` or `&&` handler;
#   2. is not the condition of an `if`; and
#   3. is not the last command of a function body, where a bare `test` is the
#      function's return value rather than an assertion.
#
# A grep counts when it is silenced — `-q`, or its output sent to /dev/null —
# and a leading `!` does not change that: `! grep -q X f` asserts that X is
# absent, and fails just as quietly. Those three forms are assertions with the
# message deliberately thrown away, and #838 counted 417 of them after #814
# finished with `test`.
#
# Rule 3 replaces a blunter one. #814 skipped every `test` inside a function,
# because some of them are predicates — `semantic_status_is_valid()` in
# tests/fuzz/semantic_protocol.sh is a range check and nothing else. That
# exclusion also hid 38 real assertions sitting mid-function, which #836
# counted and migrated. Being last is what makes a `test` a return value.
#
# Under `set -e` each one aborts its gate with an empty stderr. #814 sized the
# problem at 459 across 43 files and is driving the number to zero; this gate is
# what stops them coming back while that work is in flight.
#
# The budget is exact in both directions. A file over its budget has regressed.
# A file *under* its budget has been improved without the improvement being
# recorded, which leaves slack for the next regression to hide in — so that
# fails too, and the fix is to lower the number in the same change.
#
#   sh tests/assertions/check.sh            check every file against the budget
#   sh tests/assertions/check.sh --count    print the current counts, for
#                                           regenerating the budget file

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BUDGET="$ROOT/tests/assertions/budget.tsv"
ASSERT_CONTEXT="assertion budget"
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-assertions.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

# Counts one script. Continuation lines, `||`/`&&` at end of line, unclosed
# quotes and `$(`, heredoc bodies, and function bodies are all handled, because
# each of them otherwise turns into a wrong number. The `$(` case is not
# hypothetical: `test "$("$ROOT/bin/kofun-digest" f |` puts the pipeline on one line and the
# `|| fail` two lines later, and a counter that stops at the newline reports a
# handled assertion as a silent one.
count_file() {
    awk '
        # True while the accumulated text cannot end a command: inside a quoted
        # string, or inside an unclosed command substitution.
        function open_text(s,   i, c, sq, dq, depth) {
            sq = 0; dq = 0; depth = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (sq) { if (c == "'"'"'") sq = 0; continue }
                if (dq) {
                    if (c == "\\") { i++; continue }
                    if (c == "\"") { dq = 0; continue }
                    if (c == "$" && substr(s, i + 1, 1) == "(") { depth++; i++ }
                    else if (c == ")" && depth > 0) depth--
                    continue
                }
                if (c == "\\") { i++; continue }
                if (c == "'"'"'") { sq = 1; continue }
                if (c == "\"") { dq = 1; continue }
                if (c == "#" && depth == 0) return (depth > 0)
                if (c == "$" && substr(s, i + 1, 1) == "(") { depth++; i++ }
                else if (c == ")" && depth > 0) depth--
            }
            return (sq || dq || depth > 0)
        }
        # A candidate inside a function is held until the next meaningful
        # line says whether the function ended right after it.
        function settle(line,   t) {
            if (!pending) return
            t = line
            sub(/^[ \t]+/, "", t)
            if (t == "" || t ~ /^#/) return
            # `}` ends the function, and a bare `return` hands the status back
            # to the caller — in both cases the candidate was a return value,
            # not an assertion. spec/source-file-mapping/check.sh has the
            # second shape, and migrating it turned a predicate into a hard
            # failure until this rule existed.
            if (line ~ /^\}/ || t == "return") { pending = 0; return }
            n++
            pending = 0
        }
        function flush(  s) {
            if (buf == "") return
            s = buf
            sub(/^[ \t]+/, "", s)
            if ((s ~ /^(test|\[)[ \t]/ ||
                 s ~ /^!?[ \t]*grep[ \t]+(-[A-Za-z]+[ \t]+)*-[A-Za-z]*q/ ||
                 (s ~ /^!?[ \t]*grep[ \t]/ && s ~ />[ \t]*\/dev\/null/)) &&
                s !~ /\|\|/ &&
                s !~ /&&/ &&
                s !~ /;[ \t]*then/) {
                if (start_depth == 0) n++
                else pending = 1
            }
            buf = ""
        }
        {
            line = $0
            settle(line)
            if (heredoc != "") {
                t = line
                sub(/^[ \t]+/, "", t)
                sub(/[ \t]+$/, "", t)
                if (t == heredoc) heredoc = ""
                next
            }
            if (buf == "") start_depth = depth
            if (line ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\{/) depth++
            else if (line ~ /^\}/ && depth > 0) depth--

            t = line
            sub(/[ \t]+$/, "", t)
            buf = (buf == "") ? t : buf " " t

            if (buf ~ /\\$/) { sub(/\\$/, "", buf); next }
            if (buf ~ /(\|\||&&|\|)$/) next
            if (open_text(buf)) next

            if (line ~ /<<-?[ \t]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/) {
                tag = line
                sub(/^.*<<-?[ \t]*/, "", tag)
                sub(/[^A-Za-z0-9_'"'"'"].*$/, "", tag)
                gsub(/['"'"'"]/, "", tag)
                if (tag != "") heredoc = tag
            }
            flush()
        }
        # A file that ends inside a function is malformed; count the
        # candidate rather than silently dropping it.
        END { flush(); if (pending) n++; print n + 0 }
    ' "$1"
}

scripts() {
    git -C "$ROOT" ls-files '*.sh' |
        grep -v '^vendor/' |
        grep -v '^examples/rust-shim/'
}

scripts | while IFS= read -r f; do
    printf '%s\t%s\n' "$(count_file "$ROOT/$f")" "$f"
done >"$WORK/actual.tsv"

if test "${1:-}" = "--count"; then
    awk -F '\t' '$1 != 0' "$WORK/actual.tsv" | sort -k2,2
    exit 0
fi

assert_file_nonempty "the budget file" "$BUDGET"
grep -v '^#' "$BUDGET" | grep -v '^[[:space:]]*$' | sort -k2,2 >"$WORK/budget.tsv"
awk -F '\t' '$1 != 0' "$WORK/actual.tsv" | sort -k2,2 >"$WORK/actual-nonzero.tsv"

status=0
total=0
while IFS='	' read -r want file; do
    have=$(awk -F '\t' -v f="$file" '$2 == f { print $1 }' "$WORK/actual.tsv")
    if test -z "$have"; then
        printf 'FAIL: assertion budget: %s is in the budget but not in the tree\n' \
            "$file" >&2
        status=1
        continue
    fi
    if test "$have" -gt "$want"; then
        printf 'FAIL: assertion budget: %s has %s silent assertions, budget is %s — %s new one(s)\n' \
            "$file" "$have" "$want" "$((have - want))" >&2
        status=1
    elif test "$have" -lt "$want"; then
        printf 'FAIL: assertion budget: %s has %s silent assertions but its budget still says %s — lower the budget in the same change\n' \
            "$file" "$have" "$want" >&2
        status=1
    fi
    total=$((total + have))
done <"$WORK/budget.tsv"

while IFS='	' read -r have file; do
    if ! awk -F '\t' -v f="$file" '$2 == f { found = 1 } END { exit !found }' \
        "$WORK/budget.tsv"
    then
        printf 'FAIL: assertion budget: %s has %s silent assertions and no budget entry\n' \
            "$file" "$have" >&2
        status=1
    fi
done <"$WORK/actual-nonzero.tsv"

if test "$status" -ne 0; then
    printf '%s\n' \
        'The rule is #814: no gate may exit non-zero without naming the check, the expectation, and the observation. Use tests/assertions/assert.sh.' >&2
    exit 1
fi

printf 'PASS: every script is at its recorded silent-assertion budget (%s remaining, %s at zero)\n' \
    "$total" "$(awk -F '\t' '$1 == 0' "$WORK/budget.tsv" | wc -l | tr -d ' ')"

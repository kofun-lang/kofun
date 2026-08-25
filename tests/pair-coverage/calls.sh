#!/bin/sh
# Does every call in `bootstrap/stage2/compiler.kofun` name something that
# exists? (#1401, sibling of #1408's undefended-branch ledger)
#
# WHY THIS GATE EXISTS, AND WHY NOTHING ELSE COVERS IT. `compiler.kofun` and
# `compiler.c` are the same program written twice. The gates that compare them
# -- `selfhost-generations`, `selfhost-fixed-point` -- compare EMITTED C, and
# only the C half emits: `bootstrap/manifest.json` names
# `bootstrap/stage1/compiler.kofun` as the canonical source and
# `bootstrap/stage2/compiler.c` as the trusted seed. The stage 2 Kofun half is
# neither. `bootstrap/stage2/check.sh` round-trips it through `kofun-stage2`,
# byte-compares the identity projection, and asserts the IR is non-empty and
# carries a version header -- all of which a file with a call to a function
# that does not exist passes, because none of it resolves a name.
#
# `tests/pair-coverage/check.sh` states that hole in prose ("THE KOFUN HALF IS
# NEVER SEMANTICALLY COMPILED... A logic error that preserved all of those would
# be invisible to every gate in this repository"). This is the first gate that
# closes a piece of it: not the whole of semantic checking, one property --
# every called name resolves.
#
# WHAT IT FOUND ON THE DAY IT LANDED, which is why it is not a gate asserting a
# property it cannot fail on:
#
#   is_xid_start   compiler.kofun:15, in the file's own lexer. Nothing in the
#                  tree defines it -- not a `fn` here, not a builtin in the C
#                  half's tables, not the spec. The C half does not go through
#                  a builtin at all: `identifier_start_at` decodes a code point
#                  and tests `kofun_unicode_is_xid_start`.
#   ends_with      compiler.kofun:18143. The C half defines a static helper
#                  (`compiler.c`); the Kofun half never wrote one.
#
# Both are in `unresolved-calls.tsv` with the reasoning. The ledger fails in
# BOTH directions, like `tests/assertions/budget.tsv` and
# `tooling/gate-reachability/unreachable.tsv`: an unlisted unresolved call is
# new drift, and a listed one that now resolves is a fix nobody recorded.
#
# THE RESOLUTION SET IS DERIVED FROM THE C HALF'S OWN TABLES, never restated
# here. `builtin_arity`, `int_bit_method_arity` and `keyword_token` are read out
# of `compiler.c` at run time, so a builtin added there stops being reported the
# moment it is added, and a table that moves or is renamed makes this gate FAIL
# rather than silently resolve nothing.
#
#   sh tests/pair-coverage/calls.sh             check the ledger
#   sh tests/pair-coverage/calls.sh --count     print current unresolved names
#   sh tests/pair-coverage/calls.sh --prove     demonstrate it can refuse
#
# WHAT IT DOES NOT COVER, stated because a partial check read as a total one is
# worse than none:
#   - argument types, and arity for builtins and `.method(...)` forms. Arity is
#     checked only when the target is a function declared in this file. #1571
#     added that narrower check after `lower_body` called `validate_value_if`
#     with two of its three arguments; `builtin_arity` and
#     `int_bit_method_arity` remain outside the check.
#   - constructors and type names. Only lowercase-initial call targets are read,
#     which is what `fn` names and builtins are.
#   - a `fn` defined in the Kofun half that nothing calls. That is the reverse
#     direction and belongs to a different check.
#   - the C half. Its calls are resolved by the C compiler on every build, which
#     is exactly the asymmetry this gate narrows.
#
# THIS HARNESS IS SHELL, AND THAT IS RECORDED DEBT. Like its four neighbours it
# carries a `shell-build-driver` row in
# `tooling/forbidden-requirements/census.tsv`, which re-derives from the tree
# and fails in both directions. RFC-0018's direction is that this becomes Kofun;
# #1451 owns that work, and #1499 owns the missing piece it needs -- a compiled
# Kofun program cannot read a file today.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/pair-coverage"
C_HALF=${KOFUN_PAIR_CALLS_C_HALF:-$ROOT/bootstrap/stage2/compiler.c}

# The two seams, each ANNOUNCING itself on use for the reason check.sh gives:
# a gate silently reading a file other than the committed one reports on
# something nobody is looking at.
KOFUN_HALF=${KOFUN_PAIR_CALLS_SOURCE:-$ROOT/bootstrap/stage2/compiler.kofun}
LEDGER=${KOFUN_PAIR_CALLS_LEDGER:-$HERE/unresolved-calls.tsv}
if test "$KOFUN_HALF" != "$ROOT/bootstrap/stage2/compiler.kofun"; then
    printf 'NOTE: pair calls: reading %s, not the tree Kofun half.\n' \
        "$KOFUN_HALF" >&2
fi
if test "$LEDGER" != "$HERE/unresolved-calls.tsv"; then
    printf 'NOTE: pair calls: checking %s, not the committed ledger.\n' \
        "$LEDGER" >&2
fi
if test "$C_HALF" != "$ROOT/bootstrap/stage2/compiler.c"; then
    printf 'NOTE: pair calls: resolving against %s, not the tree C half.\n' \
        "$C_HALF" >&2
fi

# ---------------------------------------------------------------------------
# The proof. A gate nobody has watched fail is not evidence, and this one is
# green on a tree that contains two of the defects it hunts -- both are on the
# ledger -- so "it passes" says nothing on its own. Each case below mutates a
# COPY, runs this same script through the seams above, and requires the refusal
# to NAME the thing it was given. Requiring the name is the part that matters:
# #1408 measured for 105 minutes against a missing notes file, and the tool
# reported that as a coverage result rather than a missing input, so a proof
# that only asserted "it failed" would have passed on a gate that could not
# look.
#
#   sh tests/pair-coverage/calls.sh --prove
# ---------------------------------------------------------------------------
case ${1:-} in
    ""|--count) test "$#" -le 1 || { echo "usage: calls.sh [--count|--prove]" >&2; exit 2; } ;;
    --prove) test "$#" -eq 1 || { echo "usage: calls.sh [--count|--prove]" >&2; exit 2; } ;;
    *) echo "usage: calls.sh [--count|--prove]" >&2; exit 2 ;;
esac

# The outer proof sets this only on its extra-operand probe. If the arity guard
# is weakened to accept and ignore that operand, stop here instead of recursively
# entering another complete proof suite until processes or temporary space run
# out. Exit 98 is deliberately different from the required usage exit 2.
if test "${KOFUN_PAIR_PROOF_OPERAND_PROBE:-0}" = 1; then
    echo "calls.sh: operand probe reached proof setup" >&2
    exit 98
fi

if test "${1:-}" = "--prove"; then
    # `mktemp` is still validated below, but its output is never the cleanup
    # authority. Establish a private parent with mkdir's exclusive-create
    # success first, then clean only that exact parent. A broken `mktemp` that
    # returns an existing caller-owned directory therefore cannot nominate it
    # for deletion.
    PROVE_PARENT_PREFIX=${TMPDIR:-/tmp}/kofun-pair-calls-parent.$$.
    PROVE_PARENT=
    PROVE_PARENT_OWNED=0
    cleanup_prove() {
        if test "$PROVE_PARENT_OWNED" = 1; then
            case $PROVE_PARENT in
                "$PROVE_PARENT_PREFIX"[0-9]|"$PROVE_PARENT_PREFIX"[0-9][0-9])
                    PROVE_PARENT_OWNED=0
                    rm -rf "$PROVE_PARENT"
                    ;;
                *)
                    echo "calls.sh: refusing to clean an unvalidated proof parent" >&2
                    ;;
            esac
        fi
    }
    prove_parent_attempt=0
    while test "$prove_parent_attempt" -lt 100; do
        prove_parent_candidate=$PROVE_PARENT_PREFIX$prove_parent_attempt
        if (umask 077 && mkdir "$prove_parent_candidate") 2>/dev/null; then
            PROVE_PARENT=$prove_parent_candidate
            PROVE_PARENT_OWNED=1
            break
        fi
        prove_parent_attempt=$((prove_parent_attempt + 1))
    done
    test "$PROVE_PARENT_OWNED" = 1 || {
        echo "calls.sh: could not create private proof parent" >&2
        exit 1
    }
    trap cleanup_prove EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    PROVE_PREFIX=$PROVE_PARENT/proof.
    PROVE=$(mktemp -d "${PROVE_PREFIX}XXXXXX") || {
        echo "calls.sh: could not create private proof scratch" >&2
        exit 1
    }
    case $PROVE in
        "$PROVE_PREFIX"*) PROVE_SUFFIX=${PROVE#"$PROVE_PREFIX"} ;;
        *)
            echo "calls.sh: mktemp returned an unexpected proof path" >&2
            exit 1
            ;;
    esac
    case $PROVE_SUFFIX in
        ??????) ;;
        *)
            echo "calls.sh: mktemp returned an unexpected proof suffix" >&2
            exit 1
            ;;
    esac
    case $PROVE_SUFFIX in
        */*)
            echo "calls.sh: mktemp returned a non-child proof path" >&2
            exit 1
            ;;
    esac
    test -d "$PROVE" && test ! -L "$PROVE" || {
        echo "calls.sh: mktemp did not return a proof directory" >&2
        exit 1
    }

    # The outer suite sets this only for the injected first-write failure. Stop
    # at the first fixture mkdir so that the child cannot recursively run its
    # own complete proof suite under the fake mkdir.
    if test "${KOFUN_PAIR_PROOF_FIRST_WRITE_PROBE:-0}" = 1; then
        mkdir "$PROVE/caller-owned"
        echo "calls.sh: first-write probe unexpectedly succeeded" >&2
        exit 98
    fi

    # Exercise the argument refusal only against a sentinel inside the private
    # scratch. If this regresses, the proof cannot damage the checkout or any
    # caller-selected directory while demonstrating the failure.
    mkdir "$PROVE/caller-owned"
    printf 'must survive\n' >"$PROVE/expected-sentinel"
    cp "$PROVE/expected-sentinel" "$PROVE/caller-owned/sentinel"
    operand_exit=0
    KOFUN_PAIR_PROOF_OPERAND_PROBE=1 sh "$0" --prove "$PROVE/caller-owned" \
        >"$PROVE/caller-operand.out" 2>"$PROVE/caller-operand.err" || operand_exit=$?
    if test "$operand_exit" -ne 2 ||
       ! cmp -s "$PROVE/expected-sentinel" "$PROVE/caller-owned/sentinel"; then
        echo "FAIL: pair calls: --prove accepted or modified a caller-owned path" >&2
        exit 1
    fi
    printf '  prove caller-path-operand: refused and untouched\n'

    mkdir "$PROVE/fake-mktemp-fail"
    printf '%s\n' '#!/bin/sh' 'exit 73' >"$PROVE/fake-mktemp-fail/mktemp"
    chmod +x "$PROVE/fake-mktemp-fail/mktemp"
    setup_exit=0
    PATH="$PROVE/fake-mktemp-fail:$PATH" sh "$0" --prove \
        >"$PROVE/mktemp-fail.out" 2>"$PROVE/mktemp-fail.err" || setup_exit=$?
    test "$setup_exit" -eq 1 || {
        echo "FAIL: pair calls: mktemp failure did not refuse" >&2
        exit 1
    }
    printf '  prove mktemp-failure: refused\n'

    mkdir "$PROVE/fake-mktemp-path" "$PROVE/attack-tmp"
    attack_victim=$PROVE/attack-tmp/kofun-pair-calls-proof.ABCDEF
    mkdir "$attack_victim"
    cp "$PROVE/expected-sentinel" "$attack_victim/sentinel"
    printf '%s\n' '#!/bin/sh' \
        'printf "%s\n" "$KOFUN_FAKE_MKTEMP_RESULT"' \
        >"$PROVE/fake-mktemp-path/mktemp"
    chmod +x "$PROVE/fake-mktemp-path/mktemp"
    setup_exit=0
    KOFUN_FAKE_MKTEMP_RESULT="$attack_victim" \
    TMPDIR="$PROVE/attack-tmp" \
    PATH="$PROVE/fake-mktemp-path:$PATH" sh "$0" --prove \
        >"$PROVE/mktemp-path.out" 2>"$PROVE/mktemp-path.err" || setup_exit=$?
    if test "$setup_exit" -ne 1 ||
       ! test -d "$attack_victim" ||
       ! cmp -s "$PROVE/expected-sentinel" "$attack_victim/sentinel" ||
       test -e "$attack_victim/caller-owned"; then
        echo "FAIL: pair calls: existing mktemp path was accepted or cleaned" >&2
        exit 1
    fi
    printf '  prove existing-mktemp-path: refused and untouched\n'

    mkdir "$PROVE/fake-mktemp-slash" "$PROVE/slash-tmp"
    cp "$PROVE/expected-sentinel" "$PROVE/slash-tmp/sentinel"
    printf '%s\n' '#!/bin/sh' \
        'for arg do template=$arg; done' \
        'prefix=${template%XXXXXX}' \
        'mkdir "$prefix" || exit 76' \
        'printf "%s/../..\n" "$prefix"' \
        >"$PROVE/fake-mktemp-slash/mktemp"
    chmod +x "$PROVE/fake-mktemp-slash/mktemp"
    setup_exit=0
    TMPDIR="$PROVE/slash-tmp" PATH="$PROVE/fake-mktemp-slash:$PATH" \
        sh "$0" --prove >"$PROVE/mktemp-slash.out" \
        2>"$PROVE/mktemp-slash.err" || setup_exit=$?
    if test "$setup_exit" -ne 1 ||
       ! cmp -s "$PROVE/expected-sentinel" "$PROVE/slash-tmp/sentinel" ||
       test -e "$PROVE/slash-tmp/caller-owned"; then
        echo "FAIL: pair calls: slash-suffix mktemp path was accepted" >&2
        exit 1
    fi
    printf '  prove mktemp-slash-suffix: refused and untouched\n'

    mkdir "$PROVE/fake-mktemp-symlink" "$PROVE/symlink-victim"
    cp "$PROVE/expected-sentinel" "$PROVE/symlink-victim/sentinel"
    printf '%s\n' '#!/bin/sh' \
        'for arg do result=$arg; done' \
        'result=${result%XXXXXX}ABCDEF' \
        'ln -s "$KOFUN_FAKE_MKTEMP_TARGET" "$result" || exit 75' \
        'printf "%s\n" "$result"' \
        >"$PROVE/fake-mktemp-symlink/mktemp"
    chmod +x "$PROVE/fake-mktemp-symlink/mktemp"
    setup_exit=0
    KOFUN_FAKE_MKTEMP_TARGET="$PROVE/symlink-victim" \
    PATH="$PROVE/fake-mktemp-symlink:$PATH" sh "$0" --prove \
        >"$PROVE/mktemp-symlink.out" 2>"$PROVE/mktemp-symlink.err" || setup_exit=$?
    if test "$setup_exit" -ne 1 ||
       ! cmp -s "$PROVE/expected-sentinel" "$PROVE/symlink-victim/sentinel" ||
       test -e "$PROVE/symlink-victim/caller-owned"; then
        echo "FAIL: pair calls: mktemp symlink was accepted or followed" >&2
        exit 1
    fi
    printf '  prove mktemp-symlink: refused and untouched\n'

    mkdir "$PROVE/fake-first-write" "$PROVE/child-tmp"
    KOFUN_PAIR_REAL_MKDIR=$(command -v mkdir)
    export KOFUN_PAIR_REAL_MKDIR
    printf '%s\n' '#!/bin/sh' \
        'case ${1##*/} in' \
        '    kofun-pair-calls-parent.*) exec "$KOFUN_PAIR_REAL_MKDIR" "$@" ;;' \
        '    *) exit 74 ;;' \
        'esac' >"$PROVE/fake-first-write/mkdir"
    chmod +x "$PROVE/fake-first-write/mkdir"
    setup_exit=0
    KOFUN_PAIR_PROOF_FIRST_WRITE_PROBE=1 TMPDIR="$PROVE/child-tmp" \
    PATH="$PROVE/fake-first-write:$PATH" \
        sh "$0" --prove >"$PROVE/first-write.out" \
        2>"$PROVE/first-write.err" || setup_exit=$?
    first_write_leak=$(find "$PROVE/child-tmp" -mindepth 1 -print -quit)
    if test "$setup_exit" -ne 74 || test -n "$first_write_leak"; then
        printf 'FAIL: pair calls: first proof write exit %s; leftover %s\n' \
            "$setup_exit" "${first_write_leak:-none}" >&2
        exit 1
    fi
    printf '  prove first-write-failure: refused and cleaned\n'

    passed=0
    failed=0

    prove_case() {
        # prove_case NAME EXPECT_EXIT SOURCE LEDGER_FILE C_FILE NEEDLE
        case_name=$1
        want_exit=$2
        case_source=$3
        case_ledger=$4
        case_c=$5
        case_needle=$6
        got=0
        KOFUN_PAIR_CALLS_SOURCE="$case_source" \
        KOFUN_PAIR_CALLS_LEDGER="$case_ledger" \
        KOFUN_PAIR_CALLS_C_HALF="$case_c" \
            sh "$0" >"$PROVE/$case_name.out" 2>"$PROVE/$case_name.err" || got=$?
        if test "$got" -ne "$want_exit"; then
            printf 'FAIL: prove %s: exit %s, expected %s\n' \
                "$case_name" "$got" "$want_exit" >&2
            sed 's/^/      /' "$PROVE/$case_name.err" >&2
            failed=$((failed + 1))
            return
        fi
        if test -n "$case_needle"; then
            if ! grep -qF "$case_needle" "$PROVE/$case_name.err" &&
               ! grep -qF "$case_needle" "$PROVE/$case_name.out"; then
                printf 'FAIL: prove %s: the message never names %s\n' \
                    "$case_name" "$case_needle" >&2
                sed 's/^/      /' "$PROVE/$case_name.err" >&2
                failed=$((failed + 1))
                return
            fi
        fi
        printf '  prove %s: %s\n' "$case_name" \
            "$(test "$want_exit" -eq 0 && echo accepted || echo refused)"
        passed=$((passed + 1))
    }

    SRC="$ROOT/bootstrap/stage2/compiler.kofun"
    LED="$HERE/unresolved-calls.tsv"
    CC_SRC="$ROOT/bootstrap/stage2/compiler.c"

    # 1. The defect this gate exists for: a call that resolves to nothing.
    cp "$SRC" "$PROVE/unresolved.kofun"
    printf 'fn prove_caller_zz() -> Int {\n    return prove_absent_zz(1)\n}\n' \
        >>"$PROVE/unresolved.kofun"
    prove_case unresolved 1 "$PROVE/unresolved.kofun" "$LED" "$CC_SRC" \
        prove_absent_zz

    # 2. The other direction: a ledger row for a name that resolves.
    cp "$LED" "$PROVE/stale-ledger.tsv"
    printf 'prove_gone_zz\tmissing-helper\tA row for a call this tree does not make.\n' \
        >>"$PROVE/stale-ledger.tsv"
    prove_case stale-row 1 "$SRC" "$PROVE/stale-ledger.tsv" "$CC_SRC" \
        prove_gone_zz

    # 2b. A call to a function this file declares, with the wrong number of
    #     arguments. #1571 was exactly this and nothing in the tree could see
    #     it, because the name resolved.
    cp "$SRC" "$PROVE/bad-arity.kofun"
    printf 'fn prove_arity_zz(one: Text, two: Text) -> Text {\n    return one + two\n}\n\nfn prove_arity_caller_zz() -> Text {\n    return prove_arity_zz("x")\n}\n' \
        >>"$PROVE/bad-arity.kofun"
    prove_case bad-arity 1 "$PROVE/bad-arity.kofun" "$LED" "$CC_SRC" \
        prove_arity_zz

    # 3 and 4. The scanner's two assumptions, which are the difference between
    # this gate and the naive pattern that reports 90 findings and no real ones:
    # this file carries the whole emitted C runtime as string literals.
    cp "$SRC" "$PROVE/in-string.kofun"
    printf 'fn prove_text_zz() -> Text {\n    return "prove_absent_zz(1)"\n}\n' \
        >>"$PROVE/in-string.kofun"
    prove_case in-string 0 "$PROVE/in-string.kofun" "$LED" "$CC_SRC" ""

    cp "$SRC" "$PROVE/in-comment.kofun"
    printf '# prove_absent_zz(1) named in a comment is not a call\n' \
        >>"$PROVE/in-comment.kofun"
    prove_case in-comment 0 "$PROVE/in-comment.kofun" "$LED" "$CC_SRC" ""

    # 5. The assumption behind 3: a string does not span a line. If that stops
    # holding the scanner must say so rather than count what it guessed.
    cp "$SRC" "$PROVE/unterminated.kofun"
    printf 'fn prove_unterminated_zz() -> Text {\n    return "opened and never closed\n}\n' \
        >>"$PROVE/unterminated.kofun"
    prove_case unterminated 1 "$PROVE/unterminated.kofun" "$LED" "$CC_SRC" \
        "ends inside a string literal"

    # 6. The resolution set is derived, so a table that moves must make this
    # gate FAIL. Resolving nothing would report every call in the file as
    # unresolved; resolving nothing quietly is the failure that looks like a
    # result.
    sed 's/^static int64_t builtin_arity(/static int64_t builtin_arity_moved(/' \
        "$CC_SRC" >"$PROVE/moved-table.c"
    prove_case moved-table 1 "$SRC" "$LED" "$PROVE/moved-table.c" \
        "read no builtin names"

    printf '%s of %s proof cases behaved as required\n' \
        "$passed" "$((passed + failed))"
    test "$failed" -eq 0 || exit 1
    exit 0
fi

test -f "$KOFUN_HALF" || { echo "calls.sh: missing $KOFUN_HALF" >&2; exit 1; }
test -f "$C_HALF" || { echo "calls.sh: missing $C_HALF" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pair-calls.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# The call targets, read out of the Kofun half.
#
# The scanner is a character loop rather than a regular expression because the
# file is a compiler: it carries the whole emitted C runtime as string literals,
# so `strlen(`, `malloc(` and `kofun_rt_chars(` all appear in it. A pattern that
# does not know where a string ends reports 90 unresolved calls, none of them
# real. It also refuses an unterminated line rather than guessing, since that
# would mean the assumption "a Kofun string does not span a line" had stopped
# holding and every count after it would be wrong.
# ---------------------------------------------------------------------------
awk '
{
    line = $0
    out = ""
    in_string = 0
    i = 1
    n = length(line)
    while (i <= n) {
        ch = substr(line, i, 1)
        if (in_string) {
            if (ch == "\\") { i += 2; continue }
            if (ch == "\"") { in_string = 0 }
            i++
            continue
        }
        if (ch == "\"") { in_string = 1; i++; continue }
        if (ch == "#") break
        out = out ch
        i++
    }
    if (in_string) {
        printf "calls.sh: line %d ends inside a string literal.\n", NR \
            > "/dev/stderr"
        printf "  This scanner assumes a Kofun string does not span a line;\n" \
            > "/dev/stderr"
        printf "  refusing to report counts taken under an assumption that\n" \
            > "/dev/stderr"
        printf "  just stopped holding.\n" > "/dev/stderr"
        bad = 1
    }
    print out
}
END { if (bad) exit 1 }
' "$KOFUN_HALF" >"$WORK/code.txt"

# `name(` is a call; `.name(` is one of the Int bit methods, which the C half
# holds in its own table. Both are collected, and both are resolved below --
# skipping the method form would leave eight names unread and call it coverage.
awk '
{
    line = $0
    n = length(line)
    for (i = 1; i <= n; i++) {
        ch = substr(line, i, 1)
        if (ch !~ /[a-z_]/) continue
        if (i > 1) {
            before = substr(line, i - 1, 1)
            if (before ~ /[A-Za-z0-9_]/) continue
        }
        j = i
        while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_]/) j++
        name = substr(line, i, j - i)
        k = j
        while (k <= n && substr(line, k, 1) == " ") k++
        if (substr(line, k, 1) == "(") {
            dotted = (i > 1 && substr(line, i - 1, 1) == ".")
            print (dotted ? "method" : "plain") "\t" name
        }
        i = j - 1
    }
}
' "$WORK/code.txt" | sort -u >"$WORK/calls.tsv"

cut -f2 "$WORK/calls.tsv" | sort -u >"$WORK/called.txt"
test -s "$WORK/called.txt" || {
    echo "calls.sh: no call targets found in $KOFUN_HALF." >&2
    echo "  A compiler with no calls is a broken read, not a clean result." >&2
    exit 1
}

# ---------------------------------------------------------------------------
# The resolution set. Every part is derived from a table in the tree, and every
# part must be non-empty: a table that moved would otherwise resolve nothing and
# report the whole file as unresolved, or -- worse, if it were the ledger that
# emptied -- report a clean tree.
# ---------------------------------------------------------------------------
require_nonempty() {
    test -s "$2" || {
        printf 'calls.sh: read no %s out of the C half.\n' "$1" >&2
        printf '  The table it comes from moved or was renamed. Refusing to\n' >&2
        printf '  resolve names against a set the tree does not have.\n' >&2
        exit 1
    }
}

# `fn NAME(` in the Kofun half.
awk '/^fn [a-z_][A-Za-z0-9_]*\(/ { name = $2; sub(/\(.*/, "", name); print name }' \
    "$KOFUN_HALF" | sort -u >"$WORK/defined.txt"
require_nonempty "function definitions" "$WORK/defined.txt"

# `builtin_arity`'s table: the builtins a Kofun program may call.
awk '
/^static int64_t builtin_arity\(/ { inside = 1; next }
inside && /^}/ { inside = 0 }
inside && /\{"/ {
    line = $0
    while (match(line, /\{"[a-z_][A-Za-z0-9_]*"/)) {
        name = substr(line, RSTART + 2, RLENGTH - 3)
        print name
        line = substr(line, RSTART + RLENGTH)
    }
}
' "$C_HALF" | sort -u >"$WORK/builtins.txt"
require_nonempty "builtin names" "$WORK/builtins.txt"

# `int_bit_method_arity`'s table: the `.name(...)` methods on Int.
awk '
/^static int64_t int_bit_method_arity\(const char \*name\)/ { inside = 1; next }
inside && /^}/ { inside = 0 }
inside {
    line = $0
    while (match(line, /strcmp\(name, "[a-z_][A-Za-z0-9_]*"\)/)) {
        piece = substr(line, RSTART, RLENGTH)
        sub(/^strcmp\(name, "/, "", piece)
        sub(/"\)$/, "", piece)
        print piece
        line = substr(line, RSTART + RLENGTH)
    }
}
' "$C_HALF" | sort -u >"$WORK/bit-methods.txt"
require_nonempty "Int bit methods" "$WORK/bit-methods.txt"

# `keyword_token`'s table. `if (`, `while (` and `for (` are keywords followed by
# a parenthesised expression, not calls, and the extractor above cannot tell
# them apart -- the C half's own keyword list can.
awk '
/^static bool keyword_token\(/ { inside = 1; next }
inside && /^}/ { inside = 0 }
inside && /"/ {
    line = $0
    while (match(line, /"[a-z_][A-Za-z0-9_]*"/)) {
        print substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
    }
}
' "$C_HALF" | sort -u >"$WORK/keywords.txt"
require_nonempty "keywords" "$WORK/keywords.txt"

# `print` is neither: the C half parses it as a statement head, by token, in
# five places. Derived rather than listed, so that if `print` ever becomes an
# ordinary builtin this gate stops granting it a special case.
if grep -q 'token_equal(source, cursor, "print")' "$C_HALF"; then
    echo print >"$WORK/statement-forms.txt"
else
    echo "calls.sh: the C half no longer parses 'print' as a statement head." >&2
    echo "  It was granted a special case on the strength of that. Re-derive" >&2
    echo "  where it lives now instead of keeping the exemption." >&2
    exit 1
fi

sort -u "$WORK/defined.txt" "$WORK/builtins.txt" "$WORK/bit-methods.txt" \
    "$WORK/keywords.txt" "$WORK/statement-forms.txt" >"$WORK/resolved.txt"

comm -23 "$WORK/called.txt" "$WORK/resolved.txt" >"$WORK/unresolved.txt"

if test "${1:-}" = "--count"; then
    cat "$WORK/unresolved.txt"
    exit 0
fi

# ---------------------------------------------------------------------------
# The ledger, exact in both directions.
# ---------------------------------------------------------------------------
if test -f "$LEDGER"; then
    grep -v '^#' "$LEDGER" | grep -v '^[[:space:]]*$' | cut -f1 | sort -u \
        >"$WORK/recorded.txt"
else
    : >"$WORK/recorded.txt"
fi

bad=0
while IFS= read -r name; do
    test -n "$name" || continue
    if ! grep -qxF "$name" "$WORK/recorded.txt"; then
        if test "$bad" -eq 0; then
            echo "FAIL: pair calls: the Kofun half calls names that resolve to" >&2
            echo "  nothing, and are not recorded in" >&2
            echo "  tests/pair-coverage/unresolved-calls.tsv:" >&2
        fi
        printf '    %s\t%s\n' "$name" \
            "$(grep -n "[^A-Za-z0-9_.]$name *(" "$KOFUN_HALF" | head -1 | cut -d: -f1)" >&2
        bad=$((bad + 1))
    fi
done <"$WORK/unresolved.txt"

while IFS= read -r name; do
    test -n "$name" || continue
    if ! grep -qxF "$name" "$WORK/unresolved.txt"; then
        echo "FAIL: pair calls: unresolved-calls.tsv records '$name', which now" >&2
        echo "  resolves. Remove the row: a fix that stays on the ledger leaves" >&2
        echo "  slack for the next unresolved call to hide in." >&2
        bad=$((bad + 1))
    fi
done <"$WORK/recorded.txt"

test "$bad" -eq 0 || exit 1

# ---------------------------------------------------------------------------
# Arity, over the same stripped code.
#
# A name that resolves can still be called wrong, and one was: #1571. This
# reads the whole file as a single stream, because a signature or a call here
# routinely spans lines, and counts commas at depth one inside each argument
# list. `fn name(` is a declaration; anything else is a call.
#
# Only calls to functions THIS FILE declares are checked. Builtins are left to
# the C half's `builtin_arity`, and the `.method(...)` forms to
# `int_bit_method_arity`; both are readable and neither is read here, which is
# the next thing this gate could grow.
# ---------------------------------------------------------------------------
awk '
{ code = code $0 "\n" }
END {
    n = length(code)
    for (i = 1; i <= n; i++) {
        ch = substr(code, i, 1)
        if (ch !~ /[a-z_]/) continue
        if (i > 1) {
            before = substr(code, i - 1, 1)
            if (before ~ /[A-Za-z0-9_.]/) continue
        }
        j = i
        while (j <= n && substr(code, j, 1) ~ /[A-Za-z0-9_]/) j++
        name = substr(code, i, j - i)
        k = j
        while (k <= n && substr(code, k, 1) ~ /[ \t\n]/) k++
        if (substr(code, k, 1) != "(") { i = j - 1; continue }
        kind = "call"
        p = i - 1
        while (p > 0 && substr(code, p, 1) ~ /[ \t\n]/) p--
        if (p >= 2 && substr(code, p - 1, 2) == "fn") kind = "declaration"
        depth = 0
        commas = 0
        content = ""
        for (m = k; m <= n; m++) {
            c = substr(code, m, 1)
            if (c == "(") { depth++; if (depth == 1) continue }
            else if (c == ")") { depth--; if (depth == 0) break }
            else if (c == "," && depth == 1) { commas++; continue }
            if (depth >= 1) content = content c
        }
        count = commas + 1
        if (content ~ /^[ \t\n]*$/) count = 0
        printf "%s\t%s\t%d\n", kind, name, count
        i = j - 1
    }
}
' "$WORK/code.txt" >"$WORK/arities.tsv"

awk -F'\t' '
$1 == "declaration" { declared[$2] = $3; next }
$1 == "call" && ($2 in declared) {
    checked++
    if ($3 != declared[$2]) {
        printf "%s\t%d\t%d\n", $2, declared[$2], $3
        bad++
    }
}
END { printf "%d\t%d\n", checked + 0, bad + 0 >"/dev/stderr" }
' "$WORK/arities.tsv" 2>"$WORK/arity-counts.txt" >"$WORK/arity-bad.tsv"

if test -s "$WORK/arity-bad.tsv"; then
    echo "FAIL: pair calls: a call does not match the arity its declaration names:" >&2
    while IFS='	' read -r name want got; do
        printf '    %s: declared %s, called with %s\n' "$name" "$want" "$got" >&2
    done <"$WORK/arity-bad.tsv"
    echo "  A name that resolves can still be called wrong, and the Kofun half is" >&2
    echo "  never compiled, so nothing else in this repository would say so." >&2
    exit 1
fi

arity_checked=$(cut -f1 "$WORK/arity-counts.txt")

# Reach, not only hits: a count with no denominator cannot tell a rule that held
# from a rule that reached nothing. `docs/ISSUE_READINESS.md` says the same
# thing about the backlog gate's coverage lines.
called_count=$(grep -c . "$WORK/called.txt")
unresolved_count=$(grep -c . "$WORK/unresolved.txt" || true)
resolved_count=$((called_count - unresolved_count))
printf 'PASS: %d of %d call targets in %s resolve\n' \
    "$resolved_count" "$called_count" "$(basename "$KOFUN_HALF")"
printf '      %d calls to declared functions carry the declared argument count\n' \
    "$arity_checked"
printf '      %d recorded in unresolved-calls.tsv, %d definitions, %d builtins, %d Int bit methods\n' \
    "$unresolved_count" \
    "$(grep -c . "$WORK/defined.txt")" \
    "$(grep -c . "$WORK/builtins.txt")" \
    "$(grep -c . "$WORK/bit-methods.txt")"

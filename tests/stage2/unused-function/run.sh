#!/bin/sh
set -eu

# #1358. A function the program never calls.
#
# The whole defect was that `check` accepted the program and `cc` rejected it,
# so the assertion that matters is the **strict build** rather than the output:
# a golden alone would have passed on any host whose `cc` did not implement
# `-Wunused-function`, and would have kept passing if the fix regressed on a
# host that does.
#
# The flags below are the ones `bin/kofun` uses for emitted C, `-Werror`
# included, because the point is that the toolchain's own build succeeds.

root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
fixtures="$root/tests/stage2/unused-function"
work=${TMPDIR:-/tmp}/kofun-stage2-unused-function.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"
ASSERT_CONTEXT='stage2 unused function'
. "$root/tests/assertions/assert.sh"

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    echo "unused-function: a C11 compiler is required" >&2
    exit 1
fi

. "$root/bootstrap/stage2/build.sh"
kofun_stage2_build "$root" "$work/kofun-stage2"

builds() {
    stem=$1
    "$work/kofun-stage2" "$fixtures/$stem.kofun" \
        "$work/$stem.c" "$work/$stem.ir" "$work/$stem.tokens" \
        >"$work/$stem.compile" 2>"$work/$stem.compile.stderr" ||
        assert_fail "$stem did not compile: $(cat "$work/$stem.compile.stderr")"
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I "$root/unicode" "$work/$stem.c" -o "$work/$stem.bin" ||
        assert_fail "$stem emitted C that a strict C11 compiler rejects"
    "$work/$stem.bin" >"$work/$stem.stdout"
    cmp "$fixtures/$stem.stdout" "$work/$stem.stdout" ||
        assert_fail "$stem differs from its golden"
}

builds uncalled
builds all_called
builds unused_parameter

# The mechanism, not just the outcome. Each non-`main` function gets its own
# reference, so a fix that emitted one line for the first function would leave
# the second unbuildable on a host that reports the warning -- and this gate
# would otherwise agree with it.
for name in unused_first unused_second used k_u005408_u008A08; do
    assert_grep "the emitted C references $name" \
        -Fq -- "(void)kofun_fn_$name;" "$work/uncalled.c"
done

# The non-ASCII name is referenced by its escaped spelling and never by its
# raw one. That is the defect this fixture exists for: the first version of
# this fix wrote the raw name, and only `tests/unicode` caught it.
assert_not_grep 'no reference uses the raw non-ASCII identifier' \
    -Fq -- '(void)kofun_fn_合計;' "$work/uncalled.c"

# #1548. The same defect one level down: a parameter the body does not use.
# `check` accepted the program and `cc` rejected the emitted C with
# `-Werror=unused-parameter`, naming a `k_bN` the author never wrote.
#
# The strict build above is the assertion that matters, for the reason at the
# head of this file — a golden alone passes on a host that does not implement
# the warning. These pin the mechanism, so a fix that emitted one discard and
# stopped, or that walked the parameter list from the wrong end, is caught on a
# host that does not report it either.
#
# The discarded ids are read out of the emitted signature rather than written
# here, because a fixture that hard-codes `k_b1` starts testing the binding
# numbering instead of the rule.
for fn_name in first middle last none_used; do
    signature=$(
        grep -m1 "^static int64_t kofun_fn_$fn_name(" \
            "$work/unused_parameter.c" || true
    )
    test -n "$signature" ||
        assert_fail "unused_parameter emitted no signature for $fn_name"
    body=$(
        awk "/^static int64_t kofun_fn_$fn_name\\(.*\\) \\{\$/,/^\\}\$/" \
            "$work/unused_parameter.c"
    )
    discards=$(printf '%s\n' "$body" | grep -c '(void)k_b' || true)
    case $fn_name in
        none_used) want=2 ;;
        middle) want=1 ;;
        *) want=1 ;;
    esac
    test "$discards" -eq "$want" ||
        assert_fail "$fn_name discards $discards parameter(s), expected $want"
done

# A parameter the body *does* use must not be discarded. Without this the rule
# could be "discard every parameter", which compiles just as well and says
# nothing — and it would hide a later change that stopped detecting use at all.
#
# Stated as the property rather than as a pattern: the id that was discarded
# appears nowhere else in the body it was discarded in. An earlier version of
# this assertion looked for a literal `+` and failed, because the emitter
# lowers addition through `kofun_add` — which is exactly the kind of
# coincidence a pattern-matching assertion mistakes for the rule.
middle_body=$(
    awk '/^static int64_t kofun_fn_middle\(.*\) \{$/,/^\}$/' \
        "$work/unused_parameter.c"
)
discarded=$(
    printf '%s\n' "$middle_body" |
        sed -n 's/^ *(void)\(k_b[0-9]*\);$/\1/p'
)
test -n "$discarded" ||
    assert_fail 'middle discarded no parameter'
others=$(
    printf '%s\n' "$middle_body" |
        grep -v '(void)' |
        grep -c "\b$discarded\b" || true
)
test "$others" -eq 1 ||
    assert_fail "middle discarded $discarded, which its body uses $((others - 1)) time(s)"

# `main` is not referenced: it is the entry point, never `static`, and a
# `(void)kofun_fn_main;` would name a symbol that does not exist.
assert_not_grep 'the emitted C does not reference main as a function symbol' \
    -Fq -- '(void)kofun_fn_main;' "$work/uncalled.c"

# The references sit with the runtime helpers' own, which is where this
# emitter already solved the same problem for itself. A fix that invented a
# second mechanism somewhere else would pass everything above.
assert_grep 'the references sit in the same prologue as the runtime helpers' \
    -Fq -- '(void)kofun_bit_wrapping_add;' "$work/uncalled.c"

printf '%s\n' \
    'PASS: an uncalled function builds under the strict flags the toolchain uses, each non-main function is referenced once in the runtime prologue, and calling every function still builds' \
    'PASS: a parameter the body does not use is discarded in first, middle, last and every position, and a parameter that is used is not'

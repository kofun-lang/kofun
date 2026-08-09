#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

fail() {
    printf '%s\n' "FAIL: selfhost driver: $*" >&2
    exit 1
}

# This gate takes no options. It used to ignore whatever it was handed,
# so an invocation naming a phase this script never implemented — the
# `--phase` interface belongs to check-profile.sh — still reported PASS.
test "$#" -eq 0 ||
    fail "unexpected argument \`$1\`: this gate takes none (\`--phase\` belongs to check-profile.sh)"

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    fail "a C11 compiler is required"
fi

temporary=${TMPDIR:-/tmp}/kofun-selfhost-driver.$$
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary"

. "$repo_root/bootstrap/stage2/build.sh"
kofun_stage2_build "$repo_root" "$temporary/kofun-stage2" ||
    fail "the Stage 2 seed compiler did not build"

# The trusted seed compiles the frozen S as one ordinary source-to-C
# command with no hidden fallback, deterministically, byte-identical to
# the checked-in evidence.
profile_digest=$(awk -F '|' '$1 == "source_sha256" { print $2 }' \
    bootstrap/selfhost/profile.meta)
actual_digest=$(sha256sum bootstrap/stage1/compiler.kofun | awk '{ print $1 }')
test "$profile_digest" = "$actual_digest" ||
    fail "S digest differs from the frozen profile"

"$temporary/kofun-stage2" --selfhost-compile \
    bootstrap/stage1/compiler.kofun "$temporary/S.c" \
    "$profile_digest" >/dev/null
cmp bootstrap/selfhost/driver/S.c "$temporary/S.c" ||
    fail "compiled S differs from the checked-in evidence"
"$temporary/kofun-stage2" --selfhost-compile \
    bootstrap/stage1/compiler.kofun "$temporary/S.second.c" \
    "$profile_digest" >/dev/null
cmp "$temporary/S.c" "$temporary/S.second.c" ||
    fail "compiled S is not deterministic"

# The compiler produced from S is runnable, and its behavior matches the
# audited Stage 1 seed byte for byte on the Core corpus: same emitted C,
# same stdout, same exit status, and the emitted program executes to the
# pinned output.
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I unicode "$temporary/S.c" -o "$temporary/kofun-a1"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    bootstrap/stage1/compiler.c -o "$temporary/kofun-stage1"

# One accept corpus through both compiler paths. Every corpus asserts the same
# five things, so they are asserted in one place: a second copy of this sequence
# per corpus was how the loop slice's differential nearly shipped comparing the
# wrong pair. The two compilers run in separate directories with an identically
# named input, which is what keeps the emitted C free of the path it came from.
#
# This is deduplication of the harness, not of the evidence. The two compilers
# it compares stay independently derived — that pair is the differential, and
# collapsing it would delete the property this gate exists to prove.
differential_corpus() {
    stem=$1
    label=$2
    source=bootstrap/selfhost/driver/$stem.kofun
    left=$temporary/$stem-left
    right=$temporary/$stem-right

    mkdir -p "$left" "$right"
    cp "$source" "$left/input.kofun"
    cp "$source" "$right/input.kofun"
    (cd "$left" &&
        "$temporary/kofun-a1" input.kofun output.c >stdout.txt 2>stderr.txt)
    (cd "$right" &&
        "$temporary/kofun-stage1" input.kofun output.c >stdout.txt 2>stderr.txt)

    cmp "$left/output.c" "$right/output.c" ||
        fail "compiler-from-S and the audited seed emit different $label C"
    cmp "$left/stdout.txt" "$right/stdout.txt" ||
        fail "compiler-from-S and the audited seed differ on $label stdout"
    cmp "$left/stderr.txt" "$right/stderr.txt" ||
        fail "compiler-from-S and the audited seed differ on $label stderr"
    cmp "bootstrap/selfhost/driver/$stem.c" "$left/output.c" ||
        fail "$label corpus emission differs from the checked-in evidence"

    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
        "$left/output.c" -o "$temporary/$stem-program"
    "$temporary/$stem-program" >"$temporary/$stem.stdout"
    cmp "bootstrap/selfhost/driver/$stem.stdout" "$temporary/$stem.stdout" ||
        fail "$label corpus program output differs from the pinned golden"
}

differential_trap_corpus() {
    stem=$1
    label=$2
    checked_c=${3:-no}
    source=bootstrap/selfhost/driver/$stem.kofun
    left=$temporary/$stem-left
    right=$temporary/$stem-right

    mkdir -p "$left" "$right"
    cp "$source" "$left/input.kofun"
    cp "$source" "$right/input.kofun"
    (cd "$left" &&
        "$temporary/kofun-a1" input.kofun output.c >stdout.txt 2>stderr.txt)
    (cd "$right" &&
        "$temporary/kofun-stage1" input.kofun output.c >stdout.txt 2>stderr.txt)

    cmp "$left/output.c" "$right/output.c" ||
        fail "compiler-from-S and the audited seed emit different $label C"
    cmp "$left/stdout.txt" "$right/stdout.txt" ||
        fail "compiler-from-S and the audited seed differ on $label compile stdout"
    cmp "$left/stderr.txt" "$right/stderr.txt" ||
        fail "compiler-from-S and the audited seed differ on $label compile stderr"
    if test "$checked_c" = yes; then
        cmp "bootstrap/selfhost/driver/$stem.c" "$left/output.c" ||
            fail "$label corpus emission differs from the checked-in evidence"
    fi

    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -I unicode \
        "$left/output.c" -o "$temporary/$stem-program"
    set +e
    "$temporary/$stem-program" \
        >"$temporary/$stem.stdout" 2>"$temporary/$stem.stderr"
    status=$?
    set -e
    test "$status" -eq 1 ||
        fail "$label program must exit 1"
    if test "$checked_c" = yes; then
        cmp "bootstrap/selfhost/driver/$stem.stdout" \
            "$temporary/$stem.stdout" ||
            fail "$label stdout differs from the pinned golden"
    else
        test ! -s "$temporary/$stem.stdout" ||
            fail "$label program wrote unexpected stdout"
    fi
    cmp "bootstrap/selfhost/driver/$stem.stderr" "$temporary/$stem.stderr" ||
        fail "$label runtime diagnostic differs from the pinned golden"
}

# The arithmetic corpus is the baseline: same emitted C, stdout, stderr and exit
# status, and the emitted program reproduces the pinned output.
differential_corpus corpus_answer arithmetic

# Top-level declarations are part of S's profile now. A helper with an
# explicit result type must lower identically through the generated compiler
# and the audited hand-port, then execute with its pinned result.
differential_corpus corpus_function function-declaration

# One compact fixture closes four source-profile gaps: a parameterized Void
# helper owns a mutable local, assigns it, and exits through a bare return.
# Both independently-derived compilers must emit the reviewed bytes and the
# program must reproduce its pinned output.
differential_corpus corpus_profile_complete profile-completion

# The Bool/comparison slice: all six comparisons, Bool literals and bindings,
# `!`, precedence, and the nested left-associative `&&`/`||` shape. Executing it
# proves real short circuiting — both skipped right operands contain `1 // 0`.
differential_corpus corpus_bool Bool

# The nested-block slice: one C brace per Kofun block, `else if` chains that do
# not accumulate braces, and block-local bindings that leave scope at their `}`
# — the fixture rebinds a freed name afterwards. Executing it proves the skipped
# `else if` condition and the short-circuited `||` operand, both `1 // 0`,
# stayed unevaluated.
differential_corpus corpus_branch nested-block

# The loop slice: one brace pair per loop block, a range whose ends are
# evaluated once into the enclosing scope, a bound name scoped to its own block
# and rebindable after it, and loops nested in each other and in branches.
# Executing it proves the body of a false `while` and of an empty range stayed
# unentered — both hold `1 // 0`.
differential_corpus corpus_loop loop

# Text literals, concatenation, equality and printing pass through both
# independently-derived compilers. The literal containing `(+ || ==)` pins that
# operator and parenthesis bytes inside quotes are never parsed as syntax.
differential_corpus corpus_text Text
! grep -F 'greeting + " " + "compiler"' \
    "$temporary/corpus_text-left/output.c" >/dev/null ||
    fail "Text emission retained the user's expression source"
differential_corpus corpus_text_equality_only Text-equality-only
grep -F 'static bool kofun_rt_text_equal' \
    "$temporary/corpus_text_equality_only-left/output.c" >/dev/null ||
    fail "literal-only Text equality omitted its conditional runtime"

# List[Text] construction, length and indexing must agree between the
# independently-derived compilers. `k字n` pins the Stage 2 profile's
# byte-oriented Text/list semantics.
differential_corpus corpus_list_text List-Text
grep -F 'static KofunTextList kofun_rt_chars' \
    "$temporary/corpus_list_text-left/output.c" >/dev/null ||
    fail "List[Text] emission omitted its conditional runtime"
grep -F 'static const char *kofun_rt_text_index' \
    "$temporary/corpus_list_text-left/output.c" >/dev/null ||
    fail "Text indexing omitted its conditional runtime"

# All 15 profile builtins run through one file/argv corpus. The emitted shim
# deliberately uses the audited Unicode implementation, so this corpus stays on
# ASCII for the documented seed/source is_xid_continue deviation while still
# proving the real Unicode validation path is linked.
stem=corpus_builtins
left=$temporary/$stem-left
right=$temporary/$stem-right
mkdir -p "$left" "$right"
cp bootstrap/selfhost/driver/$stem.kofun "$left/input.kofun"
cp bootstrap/selfhost/driver/$stem.kofun "$right/input.kofun"
(cd "$left" &&
    "$temporary/kofun-a1" input.kofun output.c >stdout.txt 2>stderr.txt)
(cd "$right" &&
    "$temporary/kofun-stage1" input.kofun output.c >stdout.txt 2>stderr.txt)
cmp "$left/output.c" "$right/output.c" ||
    fail "compiler-from-S and the audited seed emit different builtin C"
cmp "$left/stdout.txt" "$right/stdout.txt" ||
    fail "compiler-from-S and the audited seed differ on builtin stdout"
cmp "$left/stderr.txt" "$right/stderr.txt" ||
    fail "compiler-from-S and the audited seed differ on builtin stderr"
cmp bootstrap/selfhost/driver/$stem.c "$left/output.c" ||
    fail "builtin corpus emission differs from the checked-in evidence"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -I unicode \
    "$left/output.c" -o "$temporary/$stem-program"
"$temporary/$stem-program" \
    bootstrap/selfhost/driver/$stem.input "$temporary/$stem.output" \
    >"$temporary/$stem.stdout"
cmp bootstrap/selfhost/driver/$stem.stdout "$temporary/$stem.stdout" ||
    fail "builtin corpus stdout differs from the pinned golden"
cmp bootstrap/selfhost/driver/$stem.output "$temporary/$stem.output" ||
    fail "builtin corpus file output differs from the pinned golden"
test "$(sha256sum bootstrap/selfhost/driver/corpus_answer.c |
    awk '{ print $1 }')" = \
    673d6e62ad7947fc878420eea1dffb9e3f13e942adda71f1f972b31575616499 ||
    fail "the frozen arithmetic corpus changed in the builtin slice"

# Bounds checks are runtime failures, not frontend refusals. Pin both receiver
# kinds to exit 1 with one exact R010 diagnostic and no stdout.
differential_trap_corpus corpus_trap_list_index List-Text-index-trap
differential_trap_corpus corpus_trap_text_index Text-index-trap

# `fail()` is accepted and lowered like an ordinary zero-arity Void builtin,
# then terminates at runtime with exit 1 and no output. Unlike the older bounds
# traps, this fixture also supplies reviewed C because it closes a profile row.
differential_trap_corpus corpus_trap_fail fail-builtin-trap yes

# Path remapping: compiling the same relative input from two different
# directories produces byte-identical C — no absolute-path leakage.
mkdir -p "$temporary/remap-a/nested" "$temporary/remap-b"
cp bootstrap/selfhost/driver/corpus_answer.kofun \
    "$temporary/remap-a/nested/program.kofun"
cp bootstrap/selfhost/driver/corpus_answer.kofun \
    "$temporary/remap-b/program.kofun"
(cd "$temporary/remap-a/nested" &&
    "$temporary/kofun-a1" program.kofun remapped.c >/dev/null)
(cd "$temporary/remap-b" &&
    "$temporary/kofun-a1" program.kofun remapped.c >/dev/null)
cmp "$temporary/remap-a/nested/remapped.c" "$temporary/remap-b/remapped.c" ||
    fail "emitted C depends on the compilation directory"

# The self-compile gate for #751: A1 must compile the exact canonical S bytes
# into a nonempty C2 in ordinary source-to-C mode. Two runs from distinct
# directories and source names pin determinism and path independence; the
# audited hand-port is a third, independently derived byte differential.
# Finally, C2 must satisfy the repository's strict C11 host boundary.
selfhost_vmem_kib=${KOFUN_SELFHOST_VMEM_KIB:-1572864}
selfhost_timeout_seconds=${KOFUN_SELFHOST_TIMEOUT:-120}
case "$selfhost_vmem_kib" in
    ''|*[!0-9]*) fail "KOFUN_SELFHOST_VMEM_KIB must be a positive integer" ;;
    0) fail "KOFUN_SELFHOST_VMEM_KIB must be a positive integer" ;;
esac
case "$selfhost_timeout_seconds" in
    ''|*[!0-9]*) fail "KOFUN_SELFHOST_TIMEOUT must be a positive integer" ;;
    0) fail "KOFUN_SELFHOST_TIMEOUT must be a positive integer" ;;
esac

selfhost_compile() {
    directory=$1
    compiler_path=$2
    source_name=$3
    (
        # Linux and the CI shell support this bound. Other POSIX shells may
        # not expose -v; they still run the proof, but never turn a portable
        # shell feature check into a product failure.
        if ulimit -v "$selfhost_vmem_kib" 2>/dev/null; then :; fi
        cd "$directory"
        if command -v timeout >/dev/null 2>&1; then
            timeout "${selfhost_timeout_seconds}s" \
                "$compiler_path" "$source_name" C2.c \
                >stdout.txt 2>stderr.txt
        else
            "$compiler_path" "$source_name" C2.c \
                >stdout.txt 2>stderr.txt
        fi
    )
}

mkdir -p "$temporary/self-a" "$temporary/self-b" "$temporary/self-seed"
cp bootstrap/stage1/compiler.kofun "$temporary/self-a/source-left.kofun"
cp bootstrap/stage1/compiler.kofun "$temporary/self-b/source-right.kofun"
cp bootstrap/stage1/compiler.kofun "$temporary/self-seed/source-seed.kofun"
cmp bootstrap/stage1/compiler.kofun "$temporary/self-a/source-left.kofun" ||
    fail "self-compile input differs from canonical S"
cmp bootstrap/stage1/compiler.kofun "$temporary/self-b/source-right.kofun" ||
    fail "repeated self-compile input differs from canonical S"
cmp bootstrap/stage1/compiler.kofun "$temporary/self-seed/source-seed.kofun" ||
    fail "audited hand-port input differs from canonical S"

selfhost_compile "$temporary/self-a" "$temporary/kofun-a1" \
    source-left.kofun || fail "A1 could not compile S"
selfhost_compile "$temporary/self-b" "$temporary/kofun-a1" \
    source-right.kofun || fail "A1 repeat could not compile S"
selfhost_compile "$temporary/self-seed" "$temporary/kofun-stage1" \
    source-seed.kofun || fail "the audited hand-port could not compile S"

test -s "$temporary/self-a/C2.c" || fail "A1 produced an empty C2"
cmp "$temporary/self-a/C2.c" "$temporary/self-b/C2.c" ||
    fail "A1(S) is not deterministic and path-independent"
cmp "$temporary/self-a/C2.c" "$temporary/self-seed/C2.c" ||
    fail "A1 and the audited hand-port emit different C2 bytes"
cmp "$temporary/self-a/stdout.txt" "$temporary/self-b/stdout.txt" ||
    fail "A1(S) stdout is not deterministic and path-independent"
cmp "$temporary/self-a/stderr.txt" "$temporary/self-b/stderr.txt" ||
    fail "A1(S) stderr is not deterministic and path-independent"
cmp "$temporary/self-a/stdout.txt" "$temporary/self-seed/stdout.txt" ||
    fail "A1 and the audited hand-port differ on S stdout"
cmp "$temporary/self-a/stderr.txt" "$temporary/self-seed/stderr.txt" ||
    fail "A1 and the audited hand-port differ on S stderr"

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -I unicode \
    "$temporary/self-a/C2.c" -o "$temporary/kofun-a2"

# Failure corpus: an out-of-Core source is refused with the seed's exact
# diagnostic and writes nothing; the seed agrees byte for byte.
set +e
"$temporary/kofun-a1" bootstrap/selfhost/driver/corpus_reject.kofun \
    "$temporary/reject.c" >"$temporary/reject.stdout" 2>"$temporary/reject.stderr"
reject_status=$?
"$temporary/kofun-stage1" bootstrap/selfhost/driver/corpus_reject.kofun \
    "$temporary/reject-seed.c" >"$temporary/reject-seed.stdout" 2>/dev/null
reject_seed_status=$?
set -e
test "$reject_status" -eq "$reject_seed_status" ||
    fail "reject corpus exit status diverges from the audited seed"
# Agreement alone is not the criterion: both seeds returned 0 here for as
# long as `main` discarded `compile_file`'s Bool, so this gate reported
# PASS while every refused compile still exited successfully.
test "$reject_status" -ne 0 ||
    fail "an unsupported source must exit nonzero"
cmp bootstrap/selfhost/driver/corpus_reject.stdout \
    "$temporary/reject.stdout" ||
    fail "reject corpus diagnostic differs from the pinned golden"
cmp "$temporary/reject.stdout" "$temporary/reject-seed.stdout" ||
    fail "reject corpus diagnostic diverges from the audited seed"
test ! -e "$temporary/reject.c" ||
    fail "a rejected corpus input must not produce C"
test ! -s "$temporary/reject.stderr" ||
    fail "the reject corpus wrote unexpected stderr"

# Type boundaries introduced with Bool are rejected identically by both
# compilers, exit nonzero, and never leave a partial output artifact.
# The fixture set is the glob, for the reason bootstrap/stage1/check.sh gives:
# both gates must run the same refusals, and a hand-written list in each is how
# they silently stop doing so. REJECT_FIXTURE_COUNT is asserted in both, so the
# two lists cannot drift apart without a reviewable edit to the same number.
REJECT_FIXTURE_COUNT=31
reject_checked=0
for fixture in bootstrap/selfhost/driver/corpus_reject_*.kofun
do
    stem=$(basename "$fixture" .kofun)
    set +e
    "$temporary/kofun-a1" "$fixture" \
        "$temporary/$stem.c" >"$temporary/$stem.stdout" 2>"$temporary/$stem.stderr"
    a1_status=$?
    "$temporary/kofun-stage1" "$fixture" \
        "$temporary/$stem-seed.c" >"$temporary/$stem-seed.stdout" \
        2>"$temporary/$stem-seed.stderr"
    seed_status=$?
    set -e
    test "$a1_status" -eq "$seed_status" ||
        fail "$stem status diverges from the audited seed"
    test "$a1_status" -ne 0 ||
        fail "$stem must exit nonzero"
    cmp "bootstrap/selfhost/driver/$stem.stdout" \
        "$temporary/$stem.stdout" ||
        fail "$stem diagnostic differs from the pinned refusal"
    cmp "$temporary/$stem.stdout" "$temporary/$stem-seed.stdout" ||
        fail "$stem diagnostic diverges from the audited seed"
    cmp "$temporary/$stem.stderr" "$temporary/$stem-seed.stderr" ||
        fail "$stem stderr diverges from the audited seed"
    test ! -e "$temporary/$stem.c" ||
        fail "$stem produced C through the compiler from S"
    test ! -e "$temporary/$stem-seed.c" ||
        fail "$stem produced C through the audited seed"
    reject_checked=$((reject_checked + 1))
done
test "$reject_checked" -eq "$REJECT_FIXTURE_COUNT" ||
    fail "ran $reject_checked refusal fixtures, expected $REJECT_FIXTURE_COUNT"

# Every profile builtin has one wrong-arity and one wrong-type refusal. Keeping
# the cases in one reviewable matrix avoids 30 near-identical source files while
# both independently-derived compilers still see exactly the same full source.
BUILTIN_REJECT_COUNT=30
builtin_reject_checked=0
while IFS='|' read -r label statement
do
    fixture="$temporary/builtin-reject-$label.kofun"
    {
        printf '%s\n' 'fn main() {'
        printf '    %s\n' "$statement"
        printf '%s\n' '    print(0)' '}'
    } >"$fixture"
    set +e
    "$temporary/kofun-a1" "$fixture" \
        "$temporary/builtin-reject-$label.c" \
        >"$temporary/builtin-reject-$label.stdout" \
        2>"$temporary/builtin-reject-$label.stderr"
    a1_status=$?
    "$temporary/kofun-stage1" "$fixture" \
        "$temporary/builtin-reject-$label-seed.c" \
        >"$temporary/builtin-reject-$label-seed.stdout" \
        2>"$temporary/builtin-reject-$label-seed.stderr"
    seed_status=$?
    set -e
    test "$a1_status" -eq "$seed_status" ||
        fail "$label builtin refusal status diverges from the audited seed"
    test "$a1_status" -ne 0 ||
        fail "$label builtin refusal must exit nonzero"
    cmp "bootstrap/selfhost/driver/goldens/builtin-$label.stdout" \
        "$temporary/builtin-reject-$label.stdout" ||
        fail "$label builtin refusal diagnostic differs from the pinned refusal"
    cmp "$temporary/builtin-reject-$label.stdout" \
        "$temporary/builtin-reject-$label-seed.stdout" ||
        fail "$label builtin refusal diagnostic diverges from the audited seed"
    cmp "$temporary/builtin-reject-$label.stderr" \
        "$temporary/builtin-reject-$label-seed.stderr" ||
        fail "$label builtin refusal stderr diverges from the audited seed"
    test ! -e "$temporary/builtin-reject-$label.c" ||
        fail "$label builtin refusal produced C through the compiler from S"
    test ! -e "$temporary/builtin-reject-$label-seed.c" ||
        fail "$label builtin refusal produced C through the audited seed"
    builtin_reject_checked=$((builtin_reject_checked + 1))
done < bootstrap/selfhost/driver/corpus_builtin_rejects.tsv
test "$builtin_reject_checked" -eq "$BUILTIN_REJECT_COUNT" ||
    fail "ran $builtin_reject_checked builtin refusals, expected $BUILTIN_REJECT_COUNT"

# I/O failure: a missing input panics with the runtime's bounded message,
# exits 1, and preserves the previous output bytes.
printf 'previous output\n' > "$temporary/preserved.c"
set +e
"$temporary/kofun-a1" "$temporary/does-not-exist.kofun" \
    "$temporary/preserved.c" >"$temporary/io.stdout" 2>"$temporary/io.stderr"
io_status=$?
set -e
test "$io_status" -eq 1 || fail "missing input must exit 1"
grep -F 'Kofun runtime error: cannot open input file' \
    "$temporary/io.stderr" >/dev/null ||
    fail "missing input must report the bounded runtime diagnostic"
printf 'previous output\n' | cmp - "$temporary/preserved.c" ||
    fail "a failed compile must preserve the previous output"

# UTF-8 failure: the corpus above proves the audited Unicode validator is
# *linked*; nothing proved it *refuses*. `EUNICODE001` is registered for the
# native backend only (tests/diagnostics/registry.tsv), so this is the one
# place the self-host boundary pins it, and the whole diagnostic is compared
# rather than grepped so the line, column and byte offset are pinned too — a
# span that silently became 0 would still contain the code.
#
# The bytes use octal escapes because POSIX printf specifies `\ooo` and does
# not specify `\xHH`. Under a shell whose printf lacks `\x` the fixture would
# become the literal characters, stop being invalid UTF-8, compile fine, and
# the case would pass while testing nothing.
printf 'fn main() {\n    print(0) // \377\376 bad\n}\n' \
    >"$temporary/invalid-utf8.kofun"
printf 'previous output\n' >"$temporary/utf8-preserved.c"
set +e
"$temporary/kofun-a1" "$temporary/invalid-utf8.kofun" \
    "$temporary/utf8-preserved.c" \
    >"$temporary/utf8.stdout" 2>"$temporary/utf8.stderr"
utf8_status=$?
"$temporary/kofun-stage1" "$temporary/invalid-utf8.kofun" \
    "$temporary/utf8-seed.c" \
    >"$temporary/utf8-seed.stdout" 2>"$temporary/utf8-seed.stderr"
utf8_seed_status=$?
set -e
test "$utf8_status" -eq 1 || fail "invalid UTF-8 input must exit 1"
printf 'error[EUNICODE001] at line 2, column 17 (byte 28): invalid UTF-8\n' |
    cmp - "$temporary/utf8.stdout" ||
    fail "the invalid-UTF-8 refusal differs from its pinned diagnostic"
test ! -s "$temporary/utf8.stderr" ||
    fail "the invalid-UTF-8 refusal wrote unexpected stderr"
printf 'previous output\n' | cmp - "$temporary/utf8-preserved.c" ||
    fail "an invalid-UTF-8 refusal must preserve the previous output"

# The audited seed refuses the same bytes with the same 65-byte message on the
# *other* stream: the compiler from S writes it to stdout, the seed to stderr.
# Every other refusal in this gate agrees on both streams and is asserted
# equal; asserting equality here would fail. The divergence is real, predates
# this gate, and is invisible precisely because no case covered this path, so
# each side is pinned separately instead — either one moving is a failure, and
# the day they agree this block is what says so.
test "$utf8_seed_status" -eq 1 ||
    fail "the audited seed must also exit 1 on invalid UTF-8"
cmp "$temporary/utf8.stdout" "$temporary/utf8-seed.stderr" ||
    fail "the two compilers no longer agree on the invalid-UTF-8 message text"
test ! -s "$temporary/utf8-seed.stdout" ||
    fail "the audited seed's invalid-UTF-8 refusal moved to stdout"
test ! -e "$temporary/utf8-seed.c" ||
    fail "an invalid-UTF-8 refusal must not produce C through the audited seed"

# Write failure: an output path that cannot be opened fails before any compile
# output exists, so there is nothing to preserve here — what must hold is the
# bounded runtime diagnostic and a nonzero exit rather than a silent success
# that reports a file it never wrote.
set +e
"$temporary/kofun-a1" bootstrap/selfhost/driver/corpus_answer.kofun \
    "$temporary/no-such-directory/out.c" \
    >"$temporary/unwritable.stdout" 2>"$temporary/unwritable.stderr"
unwritable_status=$?
set -e
test "$unwritable_status" -eq 1 ||
    fail "an unwritable output path must exit 1"
printf 'Kofun runtime error: cannot open output file\n' |
    cmp - "$temporary/unwritable.stderr" ||
    fail "the unwritable-output diagnostic differs from its pinned golden"
test ! -s "$temporary/unwritable.stdout" ||
    fail "the unwritable-output refusal wrote unexpected stdout"

# The driver never falls back: an out-of-profile source is rejected by
# the frontend before any lowering, with exit 1 and no C written.
set +e
"$temporary/kofun-stage2" --selfhost-compile \
    bootstrap/selfhost/frontend/reject_unsupported_match.kofun \
    "$temporary/no-fallback.c" \
    "$(sha256sum bootstrap/selfhost/frontend/reject_unsupported_match.kofun |
        awk '{ print $1 }')" >"$temporary/no-fallback.stdout"
no_fallback_status=$?
set -e
test "$no_fallback_status" -eq 1 ||
    fail "an out-of-profile source must exit 1"
grep '^error\[E2S10\]' "$temporary/no-fallback.stdout" >/dev/null ||
    fail "the driver must surface the frontend diagnostic"
test ! -e "$temporary/no-fallback.c" ||
    fail "a rejected source must not produce C"

# The A1 host boundary under AddressSanitizer and UndefinedBehaviorSanitizer.
#
# S.c carries the one hand-written C surface in the self-host chain — argv
# decoding, file bytes and allocation — and every run above is uninstrumented.
# An out-of-bounds read in that shim, or a signed overflow in the generated
# body, emits the right C2 bytes and exits 0, so all ten PASS lines below
# would still print. `grep -ril fsanitize bootstrap/ tests/ Taskfile.yml`
# named no selfhost file before this block existed.
#
# detect_leaks is deliberately OFF, which is the opposite of the choice
# tests/interop/bindgen-c/check-sanitizers.sh makes, for the opposite reason.
# That fixture's contract is client-owned handles, so a leak is the defect
# there. A1's runtime has no reclamation path at all by design — kofun_rt_alloc
# never frees, and reclamation is an open design item rather than a regression
# this gate owns — so LeakSanitizer reports the intended behavior as a failure.
# The memory-error and undefined-behavior arms stay on, and each is proven
# armed by its own probe below.

# That reason is a claim about S.c, so it is asserted rather than assumed. A
# reason nobody rechecks outlives its truth silently: if a deallocation path is
# ever added, `detect_leaks=0` stops being a description of the design and
# becomes a suppression, and the run below would keep passing while covering
# less. Failing here forces that conversation instead.
#
# The check is for a deallocation *entry point*, not for the token `free(`.
# `grep -c 'free(' bootstrap/selfhost/driver/S.c` returns 2 on a correct tree,
# because both occurrences sit inside string literals A1 emits into the
# programs it compiles — the compiled output frees, the compiler does not.
for deallocator in kofun_rt_free kofun_rt_dealloc kofun_rt_release
do
    ! grep -qE "^[a-zA-Z].*$deallocator" bootstrap/selfhost/driver/S.c ||
        fail "S.c defines $deallocator, so A1 no longer never-frees; re-enable detect_leaks rather than keeping this gate's justification"
done
grep -q '^void \*kofun_rt_alloc(' bootstrap/selfhost/driver/S.c ||
    fail "S.c no longer defines kofun_rt_alloc; the allocation model this gate reasons about has changed"

# Clang is tried first, but it can only link the sanitizer runtimes when
# compiler-rt is installed beside it, which is a packaging choice of the host.
# So the gate probes for a compiler that can actually link the arms and names
# the one it used. An environment where none can is a failure, not a skip.
printf 'int main(void) { return 0; }\n' >"$temporary/link-probe.c"
sanitizer_cc=
for candidate in ${KOFUN_SANITIZER_CC:-} clang gcc cc
do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -std=c11 -O1 -Wall -Wextra -Werror \
        -fsanitize=address,undefined -fno-sanitize-recover=all \
        "$temporary/link-probe.c" -o "$temporary/link-probe" \
        >"$temporary/link-probe.log" 2>&1
    then
        sanitizer_cc=$candidate
        break
    fi
done
test -n "$sanitizer_cc" ||
    fail "no available C compiler can link -fsanitize=address,undefined; last attempt said: $(cat "$temporary/link-probe.log")"

# One definition of the arms, so a probe cannot drift from the binary it is
# supposed to vouch for. Written as a function rather than a variable because
# unquoted expansion of a flag string is how a flag silently stops applying.
sanitized_compile() {
    "$sanitizer_cc" -std=c11 -O1 -Wall -Wextra -Werror \
        -fsanitize=address,undefined -fno-sanitize-recover=all \
        -fno-omit-frame-pointer -g "$@"
}

command -v readelf >/dev/null 2>&1 ||
    fail "readelf is required to prove the sanitized binary is instrumented"

sanitized_compile -I unicode "$temporary/S.c" -o "$temporary/kofun-a1-san" \
    2>"$temporary/a1-san.build.err" ||
    fail "A1 did not compile under sanitizers: $(cat "$temporary/a1-san.build.err")"

# A green run from an uninstrumented binary proves nothing, and the build above
# succeeding does not prove the arms were linked. Both symbol tables are read
# because -static-libasan leaves .dynsym empty while a stripped binary leaves
# .symtab empty; requiring either one alone turns a packaging choice into a
# false failure or a false pass.
readelf --wide --syms --dyn-syms "$temporary/kofun-a1-san" \
    >"$temporary/a1-san.syms" 2>/dev/null
grep -F '__asan_' "$temporary/a1-san.syms" >/dev/null ||
    fail "the sanitized A1 carries no AddressSanitizer instrumentation"

ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:detect_stack_use_after_return=1:strict_string_checks=1
UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1
export ASAN_OPTIONS UBSAN_OPTIONS

# The corpus first: every accept fixture through the instrumented boundary.
# These are the inputs that exercise argv, read_text, write_text and the
# allocator, which is the surface this block exists to cover.
for fixture in bootstrap/selfhost/driver/corpus_answer.kofun \
    bootstrap/selfhost/driver/corpus_function.kofun \
    bootstrap/selfhost/driver/corpus_profile_complete.kofun \
    bootstrap/selfhost/driver/corpus_bool.kofun \
    bootstrap/selfhost/driver/corpus_branch.kofun \
    bootstrap/selfhost/driver/corpus_loop.kofun \
    bootstrap/selfhost/driver/corpus_text.kofun \
    bootstrap/selfhost/driver/corpus_list_text.kofun \
    bootstrap/selfhost/driver/corpus_builtins.kofun
do
    stem=$(basename "$fixture" .kofun)
    set +e
    "$temporary/kofun-a1-san" "$fixture" "$temporary/$stem-san.c" \
        >"$temporary/$stem-san.stdout" 2>"$temporary/$stem-san.stderr"
    san_status=$?
    set -e
    test "$san_status" -eq 0 ||
        fail "sanitized A1 exited $san_status on $stem: $(head -c 2048 "$temporary/$stem-san.stderr")"
    test ! -s "$temporary/$stem-san.stderr" ||
        fail "sanitized A1 produced a diagnostic on $stem: $(head -c 2048 "$temporary/$stem-san.stderr")"
    cmp "bootstrap/selfhost/driver/$stem.c" "$temporary/$stem-san.c" ||
        fail "sanitized A1 emitted different C for $stem"
done

# The refusal paths, instrumented. The corpus above only walks inputs that
# succeed, and an accept-only corpus cannot reach the shape that matters here:
# a refusal abandons an allocation mid-flight, on a path that unwinds rather
# than runs to completion. Both cases exit 1 by design, so the assertion is not
# "exited 0" — it is that stdout still matches byte for byte and stderr is
# still empty, because on these two paths the diagnostic goes to stdout and
# anything on stderr is therefore a sanitizer report.
sanitized_refusal() {
    label=$1
    source_path=$2
    expected_stdout=$3

    set +e
    "$temporary/kofun-a1-san" "$source_path" "$temporary/$label-san.c" \
        >"$temporary/$label-san.stdout" 2>"$temporary/$label-san.stderr"
    refusal_status=$?
    set -e
    test "$refusal_status" -eq 1 ||
        fail "sanitized A1 exited $refusal_status on the $label refusal, expected 1: $(head -c 2048 "$temporary/$label-san.stderr")"
    test ! -s "$temporary/$label-san.stderr" ||
        fail "sanitized A1 produced a diagnostic on the $label refusal: $(head -c 2048 "$temporary/$label-san.stderr")"
    cmp "$expected_stdout" "$temporary/$label-san.stdout" ||
        fail "sanitized A1 changed the $label refusal diagnostic"
    test ! -e "$temporary/$label-san.c" ||
        fail "the sanitized $label refusal produced C"
}

sanitized_refusal invalid-utf8 "$temporary/invalid-utf8.kofun" \
    "$temporary/utf8.stdout"
sanitized_refusal reject bootstrap/selfhost/driver/corpus_reject.kofun \
    bootstrap/selfhost/driver/corpus_reject.stdout

# Then the real load: A1(S) -> C2, the run that exercises the boundary hardest
# and the only one that reaches every path S.c has. The virtual-memory ceiling
# the unsanitized self-compile applies is deliberately NOT applied here —
# AddressSanitizer reserves a shadow mapping far larger than that bound, so
# `ulimit -v` would abort the run before it began and the failure would look
# like a memory-safety fault instead of a harness mistake.
mkdir -p "$temporary/self-san"
cp bootstrap/stage1/compiler.kofun "$temporary/self-san/source-san.kofun"
set +e
(
    cd "$temporary/self-san"
    if command -v timeout >/dev/null 2>&1; then
        timeout "${selfhost_timeout_seconds}s" \
            "$temporary/kofun-a1-san" source-san.kofun C2.c \
            >stdout.txt 2>stderr.txt
    else
        "$temporary/kofun-a1-san" source-san.kofun C2.c \
            >stdout.txt 2>stderr.txt
    fi
)
self_san_status=$?
set -e
test "$self_san_status" -eq 0 ||
    fail "sanitized A1(S) exited $self_san_status: $(head -c 2048 "$temporary/self-san/stderr.txt")"
test ! -s "$temporary/self-san/stderr.txt" ||
    fail "sanitized A1(S) produced a diagnostic: $(head -c 2048 "$temporary/self-san/stderr.txt")"

# Instrumentation must not change the answer. If the sanitized and ordinary
# builds emitted different C2, one of them is wrong and a clean sanitizer run
# would be vouching for a binary that is not the one shipped.
cmp "$temporary/self-a/C2.c" "$temporary/self-san/C2.c" ||
    fail "sanitized A1 emits different C2 bytes than the ordinary build"

# Each arm gets one isolated fault, built with the exact flags used above. A
# clean run cannot tell an armed sanitizer from a missing one, and both arms
# have a way to be silently absent: UBSan without -fno-sanitize-recover=all
# prints and still exits 0, and a compiler that accepts -fsanitize=address
# without linking its runtime produces a binary that never reports.
sanitizer_arm_probe() {
    probe_name=$1
    probe_source=$2
    expected_diagnostic=$3

    sanitized_compile "$probe_source" -o "$temporary/$probe_name" \
        2>"$temporary/$probe_name.build.err" ||
        fail "the $probe_name probe did not compile: $(cat "$temporary/$probe_name.build.err")"
    set +e
    "$temporary/$probe_name" >"$temporary/$probe_name.out" \
        2>"$temporary/$probe_name.err"
    probe_status=$?
    set -e
    test "$probe_status" -ne 0 ||
        fail "the $probe_name probe exited zero; its arm is not armed and every clean run above proves nothing"
    grep -F "$expected_diagnostic" "$temporary/$probe_name.err" >/dev/null ||
        fail "the $probe_name probe failed without its arm-specific diagnostic: $(head -c 2048 "$temporary/$probe_name.err")"
}

# The volatile on `block` is load-bearing, and it is the *pointer* that has to
# be volatile — not the size. `-fsanitize=undefined` includes an object-size
# check that reports a heap overflow before ASan's redzone is consulted
# whenever it can trace the allocation through the pointer. The probe still
# fails, but on the wrong arm: it would vouch for AddressSanitizer while
# proving only that UBSan works, which is the exact substitution the isolation
# checks below exist to catch.
#
# Measured with these flags, because the intuitive fix is the one that does not
# work:
#
#   volatile size, plain pointer  -> 0 heap-buffer-overflow, 1 UBSan report
#   plain size, volatile pointer  -> 2 heap-buffer-overflow, 0 UBSan reports
#
# Hiding the size changes nothing; the check resolves the object through the
# pointer, so the pointer is what must lose its provenance. Anyone
# "simplifying" the volatile off `block` reverts this probe to proving the
# wrong arm, and the isolation assertions below are what would catch it.
#
# argc keeps the index out of reach of constant folding, so -Werror does not
# reject the probe at compile time instead of the sanitizer catching it at run
# time.
cat >"$temporary/asan-probe.c" <<'PROBE'
#include <stdlib.h>
int main(int argc, char **argv) {
    volatile size_t size = 8;
    char *volatile block = malloc(size);
    (void)argv;
    if (block == NULL) return 2;
    block[size + (size_t)argc + 7] = 'x';
    return (int)block[0];
}
PROBE
sanitizer_arm_probe asan-probe "$temporary/asan-probe.c" \
    'heap-buffer-overflow'
grep -F 'AddressSanitizer' "$temporary/asan-probe.err" >/dev/null ||
    fail "the AddressSanitizer probe faulted without an AddressSanitizer report"

cat >"$temporary/ubsan-probe.c" <<'PROBE'
#include <limits.h>
int main(int argc, char **argv) {
    volatile int large = INT_MAX;
    (void)argv;
    return (int)(large + argc);
}
PROBE
sanitizer_arm_probe ubsan-probe "$temporary/ubsan-probe.c" \
    'runtime error: signed integer overflow'

# Each probe must prove its own arm, not borrow the other's. Without this a
# single working arm would satisfy both checks above.
! grep -F 'runtime error:' "$temporary/asan-probe.err" >/dev/null ||
    fail "the AddressSanitizer probe also triggered UndefinedBehaviorSanitizer"
! grep -F 'ERROR: AddressSanitizer' "$temporary/ubsan-probe.err" >/dev/null ||
    fail "the UndefinedBehaviorSanitizer probe also triggered AddressSanitizer"

printf '%s\n' \
    "PASS: the trusted seed compiles the frozen S into a runnable compiler" \
    "PASS: the compiler from S matches the audited Stage 1 seed byte for byte on the corpus" \
    "PASS: Int/Bool typing, comparisons, and short-circuiting agree across both seeds" \
    "PASS: nested blocks, else-if chains, and block scoping agree across both seeds" \
    "PASS: while and for-range loops, their bound scope and range evaluation agree across both seeds" \
    "PASS: Text parsing, typing, runtime emission and typed refusals agree across both seeds" \
    "PASS: List[Text] construction, length, indexing and bounds traps agree across both seeds" \
    "PASS: all 15 profile builtins and all 30 arity/type refusals agree across both seeds" \
    "PASS: emission is deterministic, path-independent, and failure-preserving" \
    "PASS: A1 compiles canonical S into deterministic C2 that matches the hand-port and compiles as strict C11" \
    "PASS: invalid UTF-8 and an unwritable output are refused at their pinned diagnostics, preserving prior output" \
    "PASS: S.c still defines kofun_rt_alloc and no deallocation entry point, so detect_leaks=0 describes the design rather than suppressing a defect" \
    "PASS: the binary that ran carries __asan_ instrumentation ($sanitizer_cc)" \
    "PASS: each sanitizer arm is proven armed by an isolated fault that trips it and not the other" \
    "PASS: the A1 host boundary runs the corpus, both refusal paths, and A1(S) clean under AddressSanitizer and UndefinedBehaviorSanitizer"

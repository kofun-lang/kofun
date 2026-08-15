#!/usr/bin/env sh
set -eu

# The `pure fn` boundary (#1245): the source-level assertion that a function's
# already-inferred effect summary stays `pure`.
#
# `tests/conformance/effects/pure-io/run.sh` owns the inference this asserts.
# This gate owns the assertion: which programs it refuses, which it must leave
# exactly as they were, what the refusal names, and — in the last section —
# that each of those rules is load-bearing rather than decorative.

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/effects/pure-boundary"
CC=${CC:-cc}
WORK=${KOFUN_PURE_BOUNDARY_WORK:-"$ROOT/build/pure-boundary"}
SOURCE="$ROOT/bootstrap/stage2/compiler.c"
. "$ROOT/bootstrap/stage2/build.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"
ASSERT_CONTEXT='pure boundary'
. "$ROOT/tests/assertions/assert.sh"

fail() {
    printf '%s\n' "FAIL: pure boundary: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'Node.js is required'
case $WORK in
    */pure-boundary|*/pure-boundary.*) ;;
    *) fail "work directory must end in pure-boundary[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/remap"

kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"

# COMPILE STEM [OUTPUT-PREFIX] — the compile the CLI performs, into C. Leaves
# the diagnostic in $WORK/<prefix>.actual and the status in $compile_status.
compile() {
    compile_stem=$1
    compile_prefix=${2:-$1}
    compile_source=${3:-$CASES/$compile_stem.kofun}
    set +e
    "$WORK/kofun-stage2" \
        "$compile_source" \
        "$WORK/$compile_prefix.c" \
        "$WORK/$compile_prefix.ir" \
        "$WORK/$compile_prefix.tokens" \
        >"$WORK/$compile_prefix.actual" 2>"$WORK/$compile_prefix.internal"
    compile_status=$?
    set -e
    test ! -s "$WORK/$compile_prefix.internal" ||
        fail "$compile_stem wrote internal stderr"
}

# ------------------------------------------------------------------ positives
#
# The two programs the boundary must not touch: one that keeps its promise, and
# one that never made it.

for stem in accept identifier; do
    compile "$stem"
    assert_num "$stem exit" "$compile_status" -eq 0
    assert_file_nonempty "$stem C output" "$WORK/$stem.c"
done

# `pure` outside a declaration is the identifier it always was. Running the
# program, rather than only compiling it, is what proves the call still calls
# the function and the binding still holds the value.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror "$WORK/identifier.c" \
    -o "$WORK/identifier"
identifier_output=$("$WORK/identifier")
assert_eq 'pure as an identifier still computes' "$identifier_output" 42

# ------------------------------------------------------------------ negatives
#
# Each case names the shape it pins. The goldens carry the whole message
# because the callee it names is the part a reader acts on, and a message that
# said only "this is io" would pass a check for the code alone.
#
# The last five are precedence, position, and spelling rather than
# reachability: a violated boundary must not answer for a fault that is
# diagnosed earlier, the annotation must not be accepted where an effect cannot
# be asserted, and `io` in the same position stays the unknown modifier it was.

negatives='
direct:E2S176
one_hop:E2S176
multi_hop:E2S176
back_edge:E2S176
self_recursive:E2S176
mutual:E2S176
unknown_call:E2S16
authority_precedence:E353
annotated_type:E2S33
annotated_parameter:E2S164
annotated_expression:E2S35
io_annotation:E2S33
'

previous_ifs=$IFS
IFS='
'
for entry in $negatives; do
    test -n "$entry" || continue
    IFS=$previous_ifs
    stem=${entry%%:*}
    code=${entry#*:}
    compile "$stem"
    assert_num "$stem exit" "$compile_status" -eq 1
    cmp "$CASES/$stem.stderr" "$WORK/$stem.actual" ||
        fail "$stem: diagnostic differs from its golden"
    assert_grep "$stem code" -F "error[$code]:" "$WORK/$stem.actual"
    assert_absent "$stem C output" "$WORK/$stem.c"
    IFS='
'
done
IFS=$previous_ifs

# ---------------------------------------------------------------- determinism
#
# Reordering declarations moves the annotated function, so its byte offset
# moves with it; nothing else about the refusal may. Comparing the two
# messages with the offset removed is what distinguishes "the same answer in a
# different place" from "a different answer".

compile order_a
assert_num 'order_a exit' "$compile_status" -eq 1
compile order_b
assert_num 'order_b exit' "$compile_status" -eq 1
sed 's/ at byte [0-9]*$//' "$WORK/order_a.actual" >"$WORK/order_a.normalized"
sed 's/ at byte [0-9]*$//' "$WORK/order_b.actual" >"$WORK/order_b.normalized"
cmp "$WORK/order_a.normalized" "$WORK/order_b.normalized" ||
    fail 'reordering the declarations changed the refusal'
assert_grep 'reordered refusal still names the callee' \
    -F 'reaches `print` through `first`' "$WORK/order_a.normalized"

# The same source under a different absolute path, and the same source twice.
cp "$CASES/one_hop.kofun" "$WORK/remap/input.kofun"
compile one_hop remapped "$WORK/remap/input.kofun"
assert_num 'remapped exit' "$compile_status" -eq 1
cmp "$WORK/one_hop.actual" "$WORK/remapped.actual" ||
    fail 'the refusal depends on the checkout path'
compile one_hop repeated
cmp "$WORK/one_hop.actual" "$WORK/repeated.actual" ||
    fail 'the refusal is not reproducible'

# O0 and O2 are the same compiler; a boundary that answered differently under
# one of them would be reading uninitialized state rather than the program.
"$CC" -std=c11 -O0 -w "$SOURCE" -o "$WORK/kofun-stage2-O0"
set +e
"$WORK/kofun-stage2-O0" "$CASES/one_hop.kofun" \
    "$WORK/o0.c" "$WORK/o0.ir" "$WORK/o0.tokens" >"$WORK/o0.actual" 2>&1
o0_status=$?
set -e
assert_num 'O0 exit' "$o0_status" -eq 1
cmp "$WORK/one_hop.actual" "$WORK/o0.actual" ||
    fail 'the refusal depends on the optimization level'

# --------------------------------------------------------- the inferred facts
#
# What an accepted program publishes, unchanged. `total` is annotated and
# `pure`, `logger` reaches the root and is inferred `io` without being refused,
# and every function carries exactly one effect fact — criteria 1 and 3.
#
# There is no published *boundary* fact, and that is a scope reduction rather
# than an omission. #1245 asks for one; typed-sidecar v1 cannot carry it. A
# fact kind, a public reason, and a node kind each live in
# `bootstrap/stage2/semantic_events.h`, the v1 schema, or
# `semantic-events-v1.md` — all three frozen by
# `spec/concurrency/scoped-captures-v1/v1.sha256`, whose contract states that
# no v1 file is extended in place. The query below is the interface a consumer
# uses instead, and the fact belongs to a typed-sidecar version bump.

kofun_stage2_semantic_inputs "$ROOT" main
"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_EVENTS_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_SHA256_INPUT" \
    -o "$WORK/kofun-stage2-semantic-events"

"$WORK/kofun-stage2-semantic-events" \
    "$CASES/accept.kofun" src/accept.kofun "$WORK/accept.kse" 1
node "$ROOT/tooling/typed-sidecar/emit-stage2.mjs" \
    "$WORK/accept.kse" "$WORK/accept.json" "$CASES/accept.kofun"
node "$ROOT/spec/typed-sidecar/validate.mjs" validate "$WORK/accept.json" \
    >/dev/null
node "$CASES/report.mjs" "$WORK/accept.json" "$CASES/accept.kofun" \
    >"$WORK/accept.report"
cmp "$CASES/accept.expected" "$WORK/accept.report" ||
    fail 'the published effect facts changed'

# The same program through the other compile pipeline. `semantic_producer.c`
# calls `stage2_compile_outcome`, the copy of the pipeline behind
# `KOFUN_STAGE2_AUTHORITY_API` that the CLI never takes, so a boundary wired
# into one and not the other would make `kofun run` and `kofun check
# --emit-typed-sidecar` answer differently about one source. Byte equality
# with the CLI's golden is what refuses that.
set +e
"$WORK/kofun-stage2-semantic-events" \
    "$CASES/one_hop.kofun" src/one_hop.kofun "$WORK/one_hop.kse" 1 \
    >"$WORK/one_hop.producer" 2>"$WORK/one_hop.producer.internal"
producer_status=$?
set -e
assert_num 'producer exit for a refused boundary' "$producer_status" -eq 1
cmp "$CASES/one_hop.stderr" "$WORK/one_hop.producer" ||
    fail 'the two compile pipelines disagree about the boundary'
# And a refused program fabricates no effect facts, which is the existing
# "inference runs only after a successful compilation" rule holding.
if grep -a 'effect-io-' "$WORK/one_hop.kse" >/dev/null 2>&1; then
    fail 'a refused program published an effect fact'
fi

# ------------------------------------------------------------------ mutations
#
# The rules above, proved by removing them. Each mutation rebuilds the compiler
# with one behaviour changed and requires a named fixture to stop answering the
# way its golden says. A gate that only reads the good path cannot tell whether
# the bad one is still refused, and every one of these has a plausible-looking
# wrong version.

mutate() {
    mutate_label=$1
    mutate_expression=$2
    sed "$mutate_expression" "$SOURCE" >"$WORK/mutant-$mutate_label.mutated"
    if cmp -s "$SOURCE" "$WORK/mutant-$mutate_label.mutated"; then
        assert_fail "mutation $mutate_label changed nothing"
    fi
    # The seed includes two neighbours by paths relative to its own directory.
    # A mutant compiled out of the work directory has to be told where they
    # are: `-I` answers the sibling, and the one parent-relative path is
    # rewritten. Both are done after the comparison above, so neither can stand
    # in for a mutation that changed nothing.
    sed 's|"\.\./\.\./unicode/|"'"$ROOT"'/unicode/|' \
        "$WORK/mutant-$mutate_label.mutated" >"$WORK/mutant-$mutate_label.c"
    "$CC" -std=c11 -O0 -w -I"$ROOT/bootstrap/stage2" \
        "$WORK/mutant-$mutate_label.c" -o "$WORK/mutant-$mutate_label"
}

# The mutant must stop answering the way the golden says for one named fixture.
mutant_disagrees() {
    mutant_label=$1
    mutant_stem=$2
    set +e
    "$WORK/mutant-$mutant_label" "$CASES/$mutant_stem.kofun" \
        "$WORK/mutant-$mutant_label-$mutant_stem.c" \
        "$WORK/mutant-$mutant_label-$mutant_stem.ir" \
        "$WORK/mutant-$mutant_label-$mutant_stem.tokens" \
        >"$WORK/mutant-$mutant_label-$mutant_stem.actual" 2>&1
    mutant_status=$?
    set -e
    if test -f "$CASES/$mutant_stem.stderr"; then
        if cmp -s "$CASES/$mutant_stem.stderr" \
            "$WORK/mutant-$mutant_label-$mutant_stem.actual"
        then
            assert_fail \
                "mutation $mutant_label left $mutant_stem answering identically"
        fi
    elif test "$mutant_status" -eq 0; then
        assert_fail "mutation $mutant_label left $mutant_stem accepted"
    fi
}

# The mutant must still answer exactly as the golden says for one named
# fixture. Paired with the line above it, this separates "the rule fires" from
# "the rule fires on everything".
mutant_agrees() {
    agree_label=$1
    agree_stem=$2
    set +e
    "$WORK/mutant-$agree_label" "$CASES/$agree_stem.kofun" \
        "$WORK/agree-$agree_label-$agree_stem.c" \
        "$WORK/agree-$agree_label-$agree_stem.ir" \
        "$WORK/agree-$agree_label-$agree_stem.tokens" \
        >"$WORK/agree-$agree_label-$agree_stem.actual" 2>&1
    agree_status=$?
    set -e
    if test -f "$CASES/$agree_stem.stderr"; then
        cmp -s "$CASES/$agree_stem.stderr" \
            "$WORK/agree-$agree_label-$agree_stem.actual" ||
            assert_fail \
                "mutation $agree_label also changed $agree_stem"
    else
        test "$agree_status" -eq 0 ||
            assert_fail "mutation $agree_label also refused $agree_stem"
    fi
}

# Enforcement itself. Returning `ok` unconditionally is the shape this slice
# started as -- an annotation that parses and is never checked -- and every
# refusal below it disappears.
mutate no-enforcement \
    's/^    return pure_boundary_violation(source, "print", "E2S176");$/    (void)source; return owned_text("ok");/'
mutant_disagrees no-enforcement direct
mutant_disagrees no-enforcement one_hop

# The annotation test. Treating every declaration as annotated refuses the
# programs that never made the promise, which is the widening that would break
# every existing source.
mutate annotation-ignored \
    's/^        if (annotated_here \&\& strstr(io_set, key.data) != NULL) {$/        if (strstr(io_set, key.data) != NULL) {/'
mutant_disagrees annotation-ignored accept
mutant_agrees annotation-ignored direct

# The io root. Without it nothing is io, so a `pure` function that prints is
# accepted -- the mutation that makes the analysis run and mean nothing.
mutate no-root \
    's/^                source, parameters_close, function_close, root);$/                source, parameters_close, function_close, "");/'
mutant_disagrees no-root direct

# Transitivity. One round of the io set settles a program whose callees are
# declared before their callers; `back_edge` declares them after, so a single
# round leaves the annotated function looking pure.
mutate single-round \
    's/^    for (rounds = 0; rounds <= bound \&\& !settled; ++rounds) {$/    for (rounds = 0; rounds < 1 \&\& !settled; ++rounds) {/'
mutant_disagrees single-round back_edge
mutant_agrees single-round one_hop

# Precedence. Running the boundary before the authority check answers with the
# effect for a program whose carrier misuse is diagnosed first.
mutate boundary-first \
    's/^        char \*authority_check = validate_authority_uses(source);$/        char *authority_check = validate_pure_annotations(source);/'
mutant_disagrees boundary-first authority_precedence

printf '%s\n' \
    'PASS: direct, one-hop, multi-hop, back-edge, self- and mutually recursive boundaries are refused' \
    'PASS: unannotated, unresolved, and identifier uses of `pure` are unchanged' \
    'PASS: the refusal survives reordering, remapping, repetition, and O0/O2' \
    'PASS: an accepted program keeps its inferred effect facts and both pipelines agree' \
    'PASS: five mutations of the boundary are each caught by a named fixture'

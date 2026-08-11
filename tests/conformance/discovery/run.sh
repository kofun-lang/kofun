#!/usr/bin/env sh
set -eu

# Developer discovery v1 contract layer (#637), against
# docs/DEVELOPER_DISCOVERY.md.
#
# What this gate is for. The discovery contract is almost entirely a set of
# rules about which shapes are *refused*, and those are the rules an
# implementation drifts away from silently: a parser that tolerates a reordered
# key, an emitter that fills in a reason the status forbids, or an offset check
# that accepts the middle of a code point. Each section below observes one of
# those refusals, so a regression shows up as a changed observation rather than
# as a result that merely looks plausible.

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/discovery"
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

command -v "$CC" >/dev/null 2>&1 || {
    printf '%s\n' "discovery: a C11 compiler is required" >&2
    exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-discovery.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/discovery_v1.c" \
    "$CASES/discovery_v1_test.c" \
    -o "$WORK/discovery-test"

"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/discovery_v1.c" \
    "$ROOT/bootstrap/stage2/discovery_provider.c" \
    "$CASES/discovery_provider_test.c" \
    -o "$WORK/discovery-provider-test"

"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    "$ROOT/bootstrap/stage2/discovery_v1.c" \
    "$ROOT/bootstrap/stage2/discovery_provider.c" \
    "$ROOT/bootstrap/stage2/discovery_query.c" \
    "$CASES/live_query_test.c" \
    -o "$WORK/live-query-test"

"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    "$ROOT/bootstrap/stage2/discovery_v1.c" \
    "$ROOT/bootstrap/stage2/discovery_provider.c" \
    "$ROOT/bootstrap/stage2/discovery_query.c" \
    "$CASES/nominal_typeid_test.c" \
    -o "$WORK/nominal-typeid-test"

"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    "$ROOT/bootstrap/stage2/discovery_v1.c" \
    "$ROOT/bootstrap/stage2/discovery_provider.c" \
    "$ROOT/bootstrap/stage2/discovery_query.c" \
    "$CASES/bounded_typeid_test.c" \
    -o "$WORK/bounded-typeid-test"

"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    "$ROOT/bootstrap/stage2/discovery_v1.c" \
    "$ROOT/bootstrap/stage2/discovery_provider.c" \
    "$ROOT/bootstrap/stage2/discovery_query.c" \
    "$CASES/closure_test.c" \
    -o "$WORK/closure-test"

# One process per fixture: an identity that only holds inside a single
# analysis process is not an identity, and the compiler's per-pass caches are
# keyed on the source address a second analysis could reuse.
bounded_typeid() {
    binary=$1
    output=$2
    : >"$output"
    for fixture in live_list_text bounded_type_other_module \
        bounded_type_shadowed
    do
        case $fixture in
        live_list_text) fixture_generation=19 ;;
        bounded_type_other_module) fixture_generation=31 ;;
        *) fixture_generation=37 ;;
        esac
        ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
        UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
            "$binary" "$CASES/$fixture.kofun" \
            "tests/conformance/discovery/$fixture.kofun" \
            "$fixture_generation" >>"$output"
    done
}

# The equalities the golden displays are also asserted, so a future golden
# refresh cannot quietly accept an identity that stopped being one.
bounded_typeid_properties() {
    output=$1
    id_of() {
        sed -n "s/^$1: identity=\\([0-9a-f]*\\) .*/\\1/p" "$output" | sed -n "$2p"
    }
    first=$(id_of 'List\[Text\]' 1)
    second=$(id_of 'List\[Text\]' 2)
    list_int=$(id_of 'List\[Int\]' 1)
    int_id=$(id_of Int 1)
    text_id=$(id_of Text 1)
    [ -n "$first" ] && [ "$first" = "$second" ] ||
        fail "constructed List[Text] identity differs across modules"
    [ "$(id_of Int 1)" = "$(id_of Int 2)" ] ||
        fail "builtin Int identity differs across modules"
    for other in "$list_int" "$int_id" "$text_id"; do
        [ -n "$other" ] && [ "$first" != "$other" ] ||
            fail "distinct bounded type references share one identity"
    done
    [ "$list_int" != "$int_id" ] && [ "$int_id" != "$text_id" ] ||
        fail "distinct builtin type references share one identity"
    grep -q '^List\[Choice\]: identity=null display=List\[Choice\]' "$output" ||
        fail "current-file declaration was answered by the builtin catalog"
}

golden() {
    name=$1
    shift
    "$WORK/discovery-test" "$@" >"$WORK/$name.observed" 2>&1
    cmp "$CASES/$name.golden" "$WORK/$name.observed" ||
        fail "$name observation changed"
    printf '%s\n' "PASS: $name"
}

provider_golden() {
    name=$1
    shift
    "$WORK/discovery-provider-test" "$@" >"$WORK/$name.observed" 2>&1
    cmp "$CASES/$name.golden" "$WORK/$name.observed" ||
        fail "$name observation changed"
    printf '%s\n' "PASS: $name"
}

# Request admissibility: canonical bytes are accepted, and every documented
# deviation is refused with the reason the contract names for it.
golden parse parse

# Result shape: the statuses that carry no facts emit canonical bytes, and the
# combinations the contract forbids are refused rather than emitted.
golden emit emit

# UTF-8 code-point boundaries, which the position rule requires of all three
# offsets.
golden boundaries boundaries

# Facts: the validated `List[Text]` answer, the receiver-mode disclosure rule,
# provisional types, omission ordering, and canonical operation order.
golden facts facts

# The shape invariants a fact-bearing result must satisfy. Each case here is a
# result the contract forbids, and the emitter must refuse it rather than
# produce bytes a client would believe.
golden facts-refused facts-refused

# The provider boundary: #608 semantic records projected into contract facts.
# The analysis key is derived rather than trusted, and an absent interface
# digest fails closed instead of matching by accident.
provider_golden analysis-key analysis-key

# Staleness axes, including a request that mismatches on every axis at once —
# the reported reason must be the most fundamental one, since that is what
# tells a client whether to re-target, upgrade, or re-analyze.
provider_golden staleness staleness

# Expression selection: the narrowest *expression* wins over the declaration
# and scope that also contain the offset, and a client span that is not the
# parsed occurrence is refused rather than answered about a different node.
provider_golden select select

# Type projection: a validated type needs both a validated fact and a
# validated TypeId, an absent type is unavailable with no display, and the
# service never invents `Any`.
provider_golden type type

# Candidate operations. The disclosure rule is the part with consequences: a
# hidden candidate never becomes a row in any status, because even an
# "unavailable" row names it. Two hidden candidates still yield one omission,
# so an omission cannot be read as a count of what was withheld.
provider_golden operations operations

# The live boundary: one real Stage 2 ownership analysis over a List[Text]
# occurrence, followed by the same provider projection used above.  The
# current producer has no committed TypeId for that recovery-profile
# occurrence, so the pinned answer carries a provisional `List[Text]` display
# rather than inventing a validated identity. Direct function/constructor rows
# still carry the producer's stable SymbolIds. The exact unary `Int`
# constructor row is validated from committed compiler IR; unrelated
# signature/effect-incomplete functions remain provisional, and the private
# function becomes only an aggregate omission.
"$WORK/live-query-test" "$CASES/live_list_text.kofun" \
    >"$WORK/live_query.observed" 2>&1
cmp "$CASES/live_query.golden" "$WORK/live_query.observed" ||
    fail "live Stage 2 discovery observation changed"
printf '%s\n' "PASS: live-query"

"$WORK/nominal-typeid-test" "$CASES/live_nominal_type.kofun" \
    "$CASES/live_nominal_type_unrelated_edit.kofun" \
    >"$WORK/nominal_typeid.observed" 2>&1
cmp "$CASES/nominal_typeid.golden" "$WORK/nominal_typeid.observed" ||
    fail "nominal TypeId observation changed"
printf '%s\n' "PASS: nominal-typeid"

# The bounded builtin/constructed identity owner. A source spelling is not an
# identity authority, so the properties that separate the two are the ones
# checked: one identity per constructed reference across files, modules, and
# generations; distinct identities for distinct components; and a refusal —
# not a fabricated identity — when a current-file declaration owns the name.
bounded_typeid "$WORK/bounded-typeid-test" "$WORK/bounded_typeid.observed"
cmp "$CASES/bounded_typeid.golden" "$WORK/bounded_typeid.observed" ||
    fail "bounded type identity observation changed"
bounded_typeid_properties "$WORK/bounded_typeid.observed"
printf '%s\n' "PASS: bounded-typeid"

# The two ways a row can claim a closure it does not have. Both produce a
# well-formed result, so neither is visible from the shape of the answer: a
# result type appears in no dependency list and so escapes a check that walks
# one, and a record this build cannot read is withheld correctly but was
# counted as a completed analysis. Each is observed as a status.
"$WORK/closure-test" "$CASES/unidentified_result.kofun" \
    >"$WORK/closure.observed" 2>&1
cmp "$CASES/closure.golden" "$WORK/closure.observed" ||
    fail "candidate closure observation changed"
printf '%s\n' "PASS: closure"

# Discovery is a tooling-only library.  The release Stage 2 sources must still
# match their pinned pre-adapter bytes, and enabling a no-op discovery-disabled
# build flag must produce the exact same compiler artifact.
(
    cd "$ROOT"
    "$ROOT/bin/kofun-digest" -c bootstrap/stage2/SHA256SUMS >/dev/null
)
kofun_stage2_build "$ROOT" "$WORK/stage2-release"
# stage2-build-reuse: specialized macro-variant build; keep independent.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    -DKOFUN_DISCOVERY_DISABLED=1 \
    "$ROOT/bootstrap/stage2/compiler.c" -o "$WORK/stage2-release-disabled"
cmp "$WORK/stage2-release" "$WORK/stage2-release-disabled" ||
    fail "discovery-disabled Stage 2 artifact changed"
printf '%s\n' "PASS: discovery-disabled-artifact"

# Every rejection path above walks the parser over deliberately malformed
# bytes, which is exactly where an off-by-one reads past the end. Run the same
# cases under the sanitizers so a refusal that is "correct" but reads out of
# bounds still fails.
if printf 'int main(void){return 0;}\n' >"$WORK/probe.c" &&
    "$CC" -std=c11 -fsanitize=address,undefined "$WORK/probe.c" \
        -o "$WORK/probe" 2>/dev/null
then
    "$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/discovery_v1.c" \
        "$CASES/discovery_v1_test.c" \
        -o "$WORK/discovery-test-sanitized"
    for mode in parse emit boundaries facts facts-refused; do
        ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
        UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
            "$WORK/discovery-test-sanitized" "$mode" >/dev/null
    done
    "$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/discovery_v1.c" \
        "$ROOT/bootstrap/stage2/discovery_provider.c" \
        "$CASES/discovery_provider_test.c" \
        -o "$WORK/discovery-provider-sanitized"
    for mode in analysis-key staleness select type operations; do
        ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
        UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
            "$WORK/discovery-provider-sanitized" "$mode" >/dev/null
    done
    "$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/semantic_producer.c" \
        "$ROOT/bootstrap/stage2/semantic_events.c" \
        "$ROOT/bootstrap/stage2/sha256.c" \
        "$ROOT/bootstrap/stage2/discovery_v1.c" \
        "$ROOT/bootstrap/stage2/discovery_provider.c" \
        "$ROOT/bootstrap/stage2/discovery_query.c" \
        "$CASES/live_query_test.c" \
        -o "$WORK/live-query-sanitized"
    "$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/semantic_producer.c" \
        "$ROOT/bootstrap/stage2/semantic_events.c" \
        "$ROOT/bootstrap/stage2/sha256.c" \
        "$ROOT/bootstrap/stage2/discovery_v1.c" \
        "$ROOT/bootstrap/stage2/discovery_provider.c" \
        "$ROOT/bootstrap/stage2/discovery_query.c" \
        "$CASES/nominal_typeid_test.c" \
        -o "$WORK/nominal-typeid-sanitized"
    "$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/semantic_producer.c" \
        "$ROOT/bootstrap/stage2/semantic_events.c" \
        "$ROOT/bootstrap/stage2/sha256.c" \
        "$ROOT/bootstrap/stage2/discovery_v1.c" \
        "$ROOT/bootstrap/stage2/discovery_provider.c" \
        "$ROOT/bootstrap/stage2/discovery_query.c" \
        "$CASES/bounded_typeid_test.c" \
        -o "$WORK/bounded-typeid-sanitized"
    "$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/semantic_producer.c" \
        "$ROOT/bootstrap/stage2/semantic_events.c" \
        "$ROOT/bootstrap/stage2/sha256.c" \
        "$ROOT/bootstrap/stage2/discovery_v1.c" \
        "$ROOT/bootstrap/stage2/discovery_provider.c" \
        "$ROOT/bootstrap/stage2/discovery_query.c" \
        "$CASES/closure_test.c" \
        -o "$WORK/closure-sanitized"
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/live-query-sanitized" "$CASES/live_list_text.kofun" \
        >"$WORK/live_query.sanitized" 2>&1
    cmp "$CASES/live_query.golden" "$WORK/live_query.sanitized" ||
        fail "sanitized live Stage 2 discovery observation changed"
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/nominal-typeid-sanitized" \
        "$CASES/live_nominal_type.kofun" \
        "$CASES/live_nominal_type_unrelated_edit.kofun" \
        >"$WORK/nominal_typeid.sanitized" 2>&1
    cmp "$CASES/nominal_typeid.golden" \
        "$WORK/nominal_typeid.sanitized" ||
        fail "sanitized nominal TypeId observation changed"
    bounded_typeid "$WORK/bounded-typeid-sanitized" \
        "$WORK/bounded_typeid.sanitized"
    cmp "$CASES/bounded_typeid.golden" \
        "$WORK/bounded_typeid.sanitized" ||
        fail "sanitized bounded type identity observation changed"
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/closure-sanitized" "$CASES/unidentified_result.kofun" \
        >"$WORK/closure.sanitized" 2>&1
    cmp "$CASES/closure.golden" "$WORK/closure.sanitized" ||
        fail "sanitized candidate closure observation changed"
    printf '%s\n' "PASS: AddressSanitizer and UndefinedBehaviorSanitizer"
else
    printf '%s\n' "SKIP: sanitizers unavailable"
fi

# The emitted bytes are pinned byte-for-byte by emit.golden above, which is
# what makes the canonical-encoding rules checkable at all: key order,
# two-space indentation, the single space after ':', and the closing LF are all
# visible in the golden rather than asserted about. A reviewer reads the
# canonical form directly, and any drift shows up as a diff.
#
# Deliberately no second validator here. Re-checking these bytes with a JSON
# library would mean adding an interpreter this repository does not otherwise
# use in its gates, and `task repository-check` exists to keep that out.

printf '%s\n' "discovery: OK"

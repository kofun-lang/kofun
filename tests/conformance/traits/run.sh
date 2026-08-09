#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/traits"
CC=${CC:-cc}
ANALYZER_CC=${ANALYZER_CC:-gcc}
WORK=${KOFUN_TRAITS_FRONTEND_WORK:-"$ROOT/build/traits-frontend"}

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v "$ANALYZER_CC" >/dev/null 2>&1 ||
    fail 'GCC is required for the static analyzer gate'
case $WORK in
    */traits-frontend|*/traits-frontend.*) ;;
    *) fail "work directory must end in traits-frontend[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/remapped"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/traits_frontend.c" \
    -o "$WORK/kofun-traits-frontend"
"$ANALYZER_CC" -std=c11 -O0 -g -Wall -Wextra -Werror -pedantic \
    -fanalyzer "$ROOT/bootstrap/stage2/traits_frontend.c" \
    -o "$WORK/kofun-traits-analyzer"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/stage2/traits_frontend.c" \
    -o "$WORK/kofun-traits-sanitize"

cp "$CASES/positive.kofun" "$WORK/remapped/positive.kofun"
for suffix in first second remapped; do
    source="$CASES/positive.kofun"
    test "$suffix" = remapped && source="$WORK/remapped/positive.kofun"
    "$WORK/kofun-traits-frontend" "$source" \
        "$WORK/positive.$suffix.ir" "$WORK/positive.$suffix.tokens" \
        >"$WORK/positive.$suffix.stdout" \
        2>"$WORK/positive.$suffix.stderr"
    test ! -s "$WORK/positive.$suffix.stdout" ||
        fail "$suffix positive run wrote stdout"
    test ! -s "$WORK/positive.$suffix.stderr" ||
        fail "$suffix positive run wrote stderr"
done
cmp "$WORK/positive.first.ir" "$WORK/positive.second.ir" ||
    fail 'repeated trait IR differs'
cmp "$WORK/positive.first.tokens" "$WORK/positive.second.tokens" ||
    fail 'repeated trait token tape differs'
cmp "$WORK/positive.first.ir" "$WORK/positive.remapped.ir" ||
    fail 'trait IR depends on the host source path'
cmp "$WORK/positive.first.tokens" "$WORK/positive.remapped.tokens" ||
    fail 'trait token tape depends on the host source path'
cmp "$CASES/positive.ir" "$WORK/positive.first.ir" ||
    fail 'positive trait typed IR differs from its golden'

# Stable identities: TraitId carries provenance, MethodId carries the
# declaration-order slot, and ImplementationId carries the ABI schema version,
# the package, the trait, the normalized concrete arguments, the outer nominal
# self-type, and the implementation declaration.
grep -F 'trait-id=trait:local:Equal' "$WORK/positive.first.ir" >/dev/null ||
    fail 'local TraitId is missing'
grep -F 'trait-id=trait:foreign:Display' "$WORK/positive.first.ir" >/dev/null ||
    fail 'foreign TraitId is missing'
grep -F 'method-id=method:trait:local:Equal:0' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'MethodId slot is missing'
grep -F 'implementation-id=impl:abi1/package:local/trait:local:Equal/args=builtin:Int/self=builtin:Int/decl=0' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'ImplementationId does not carry every identity component'

# The #403 orphan rule admits a foreign trait for a local type and a local
# trait for a foreign type; only both-foreign is refused.
grep -F 'implementation-id=impl:abi1/package:local/trait:foreign:Display/args=nominal:local:Money/self=nominal:local:Money' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'foreign trait over a local type was not admitted'
grep -F 'implementation-id=impl:abi1/package:local/trait:local:Equal/args=nominal:foreign:Duration/self=nominal:foreign:Duration' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'local trait over a foreign type was not admitted'

# The bound is recorded, the method call resolves through it, and each explicit
# call selects exactly one implementation.
grep -F 'bound|owner=function:same|type-parameter=type-parameter:function:same:0|trait=trait:local:Equal' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'the declared bound is missing'
grep -F 'method-call|caller=function:same|method=method:trait:local:Equal:0|via-bound=type-parameter:function:same:0' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'the method call did not resolve through the bound'
selected=$(grep -c 'selected-implementation=impl:' "$WORK/positive.first.ir")
test "$selected" -eq 3 ||
    fail "expected 3 resolved calls, found $selected"
test "$(grep -c 'selected-implementation=none' "$WORK/positive.first.ir")" -eq 0 ||
    fail 'a bounded call left its implementation unresolved'

# Dictionary elaboration (#923). The descriptor is a trait's static dictionary
# layout, the dictionary value is what one admissible implementation produces,
# the dictionary parameter is what a declared bound becomes, and the dictionary
# argument is what a bounded call passes.
grep -F 'kofun-traits-ir/v2' "$WORK/positive.first.ir" >/dev/null ||
    fail 'the IR header version does not record the dictionary records'
grep -F 'dictionary-descriptor|descriptor-id=dictionary-descriptor:abi1/trait:local:Equal|trait=trait:local:Equal|abi=abi1|slots=1|slot-methods=method:trait:local:Equal:0' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'the Equal dictionary descriptor is missing its ordered slot table'
descriptors=$(grep -c '^dictionary-descriptor|' "$WORK/positive.first.ir")
traits=$(grep -c '^trait|' "$WORK/positive.first.ir")
test "$descriptors" -eq "$traits" ||
    fail "expected one descriptor per trait, found $descriptors for $traits"
dictionaries=$(grep -c '^dictionary|' "$WORK/positive.first.ir")
implementations=$(grep -c '^implementation|' "$WORK/positive.first.ir")
test "$dictionaries" -eq "$implementations" ||
    fail "expected one dictionary per implementation, found $dictionaries for $implementations"
entries=$(grep -c '^dictionary-entry|' "$WORK/positive.first.ir")
slots=$(sed -n 's/^dictionary|.*|slots=\([0-9][0-9]*\)|.*/\1/p' \
    "$WORK/positive.first.ir" | awk '{ total += $1 } END { print total + 0 }')
test "$entries" -eq "$slots" ||
    fail "expected one slot entry per declared slot, found $entries for $slots"

# A trait may declare more than one member. The implementation writes them in
# the opposite order, so matching by name rather than by position is what the
# slot table has to prove: slot 0 holds the first declared member whichever
# order it was implemented in, and the second member is reachable through the
# same dictionary parameter as the first.
"$WORK/kofun-traits-frontend" "$CASES/two_members.kofun" \
    "$WORK/two_members.ir" "$WORK/two_members.tokens" ||
    fail 'a trait with two members was refused'
grep -F 'slots=2|slot-methods=method:trait:local:Ordered:0,method:trait:local:Ordered:1' \
    "$WORK/two_members.ir" >/dev/null ||
    fail 'the two-member descriptor is missing its ordered slot table'
grep -F '|slot=0|method=method:trait:local:Ordered:0|implementation-method=equal' \
    "$WORK/two_members.ir" >/dev/null ||
    fail 'slot 0 is not filled by the member of that name'
grep -F '|slot=1|method=method:trait:local:Ordered:1|implementation-method=before' \
    "$WORK/two_members.ir" >/dev/null ||
    fail 'slot 1 is not filled by the member of that name'
grep -F 'caller=function:earlier|method=method:trait:local:Ordered:1' \
    "$WORK/two_members.ir" >/dev/null ||
    fail 'the second member is not reachable from a bounded call'
grep -F 'method-slot=1' "$WORK/two_members.ir" >/dev/null ||
    fail 'a call to the second member did not record its slot'
two_member_entries=$(grep -c '^dictionary-entry|' "$WORK/two_members.ir")
test "$two_member_entries" -eq 2 ||
    fail "expected two slot entries, found $two_member_entries"

# A DictionaryId is its ImplementationId with the `impl:` tag replaced and the
# `/decl=N` ordinal dropped. Deriving one field from the other and comparing
# makes that an exact check rather than a spot check, and dropping the ordinal
# is what keeps the identity independent of declaration order.
derive_dictionary_id() {
    sed -e 's/\/decl=[0-9]*$//' -e 's/^impl:/dictionary:/'
}
grep '^dictionary|' "$WORK/positive.first.ir" |
    sed -e 's/.*|implementation=\([^|]*\)|.*/\1/' |
    derive_dictionary_id >"$WORK/dictionary.derived"
grep '^dictionary|' "$WORK/positive.first.ir" |
    sed -e 's/^dictionary|dictionary-id=\([^|]*\)|.*/\1/' \
        >"$WORK/dictionary.declared"
test -s "$WORK/dictionary.derived" ||
    fail 'no DictionaryId derivations were compared'
cmp "$WORK/dictionary.derived" "$WORK/dictionary.declared" ||
    fail 'a DictionaryId is not derived from its ImplementationId'

# `same` carries exactly one dictionary parameter, and it names the bound it
# discharges rather than only the trait.
grep -F 'dictionary-parameter|dictionary-parameter-id=dictionary-parameter:function:same:0|owner=function:same|index=0|descriptor=dictionary-descriptor:abi1/trait:local:Equal|discharges-bound=type-parameter:function:same:0|trait=trait:local:Equal' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'same does not carry a dictionary parameter for its Equal bound'
parameters=$(grep -c '^dictionary-parameter|' "$WORK/positive.first.ir")
bounds=$(grep -c '^bound|' "$WORK/positive.first.ir")
test "$parameters" -eq "$bounds" ||
    fail "expected one dictionary parameter per bound, found $parameters for $bounds"

# The trait method call inside `same` resolves to (dictionary parameter, slot).
grep -F 'method-call|caller=function:same|method=method:trait:local:Equal:0|via-bound=type-parameter:function:same:0|dictionary-parameter=dictionary-parameter:function:same:0|method-slot=0' \
    "$WORK/positive.first.ir" >/dev/null ||
    fail 'the method call does not resolve to a dictionary parameter and slot'

# Every bounded call passes the dictionary its recorded selection denotes.
passed_dictionaries() {
    grep '^call|' "$1" |
        sed -e 's/.*|dictionary-arguments=\([^|]*\)|.*/\1/' >"$2"
}
grep '^call|' "$WORK/positive.first.ir" |
    sed -e 's/.*|selected-implementation=\([^|]*\)|.*/\1/' |
    derive_dictionary_id >"$WORK/call.derived"
passed_dictionaries "$WORK/positive.first.ir" "$WORK/call.passed"
test -s "$WORK/call.derived" ||
    fail 'no call dictionaries were compared against their selection'
cmp "$WORK/call.derived" "$WORK/call.passed" ||
    fail 'a bounded call passed a dictionary its selection does not denote'
test "$(grep -c 'dictionary-arguments=none' "$WORK/positive.first.ir")" -eq 0 ||
    fail 'a bounded call left its dictionary argument unelaborated'
test "$(grep -c 'dictionary-parameter=none' "$WORK/positive.first.ir")" -eq 0 ||
    fail 'a bounded call or method call named no dictionary parameter'

# Nothing below the dictionary is claimed: no monomorphised instance, no vtable
# layout, and no runtime candidate search.
! grep -Eq 'monomorph|vtable|search' "$WORK/positive.first.ir" ||
    fail 'the frontend claimed a lowering below the dictionary'

failures='
blanket_implementation:E2S132
default_method:E2S132
duplicate_trait:E2S127
implementation_duplicate_member:E2S127
implementation_extra_member:E2S127
implementation_missing_member:E2S127
inherited_member_source:E2S127
member_name_collision:E370
method_arity_mismatch:E2S128
method_name_mismatch:E2S127
method_parameter_mismatch:E2S128
method_result_mismatch:E2S128
missing_implementation:E2S129
multiple_bounds:E2S132
orphan_alias_ownership:E2S131
orphan_both_foreign:E2S131
overlapping_implementation:E2S130
recursive_bound:E2S132
trait_arity_mismatch:E2S127
two_type_parameter_trait:E2S132
unbounded_method_call:E2S129
'

previous_ifs=$IFS
IFS='
'
for entry in $failures; do
    test -n "$entry" || continue
    stem=${entry%%:*}
    code=${entry#*:}
    set +e
    "$WORK/kofun-traits-frontend" "$CASES/$stem.kofun" \
        "$WORK/$stem.ir" "$WORK/$stem.tokens" \
        >"$WORK/$stem.actual" 2>"$WORK/$stem.internal.stderr"
    status=$?
    set -e
    test "$status" -eq 1 ||
        fail "$stem exited $status instead of 1"
    cmp "$CASES/$stem.stderr" "$WORK/$stem.actual" ||
        fail "$stem diagnostic differs"
    grep -F "error[$code]:" "$WORK/$stem.actual" >/dev/null ||
        fail "$stem expected $code"
    test ! -s "$WORK/$stem.internal.stderr" ||
        fail "$stem wrote internal stderr"
    test ! -e "$WORK/$stem.ir" ||
        fail "$stem emitted rejected typed IR"
    test ! -e "$WORK/$stem.tokens" ||
        fail "$stem emitted rejected tokens"
done
IFS=$previous_ifs

# An alias never confers ownership: the refusal names the type the alias
# resolves to, not the alias.
grep -F 'nominal:foreign:Duration' \
    "$CASES/orphan_alias_ownership.stderr" >/dev/null ||
    fail 'the alias refusal did not resolve to the foreign type'

# RFC-0005 is accepted (decided 2026-08-09), so the member key
# `(owner identity, value namespace, normalized name)` is normative and the
# duplicate refusal is `E370`. These assertions replaced the anti-blessing
# guards that stood while it was under review: those required the refusal to
# land in the *parameter* scope and to name neither the member nor its owner,
# because a collision keyed by the trait could not see the member. They did
# their job -- nothing blessed the proposal before it was decided -- and are
# now the wrong shape to assert.
grep -F 'error[E370]' "$CASES/member_name_collision.stderr" >/dev/null ||
    fail 'a duplicate member is not refused as a member-scope collision'
grep -F "declares member 'equal' twice" \
    "$CASES/member_name_collision.stderr" >/dev/null ||
    fail 'the duplicate-member refusal does not name the colliding member'
grep -F "trait 'Equal'" "$CASES/member_name_collision.stderr" >/dev/null ||
    fail 'the duplicate-member refusal does not name the owning trait'
grep -F 'value namespace' "$CASES/member_name_collision.stderr" >/dev/null ||
    fail 'the duplicate-member refusal does not name the collided namespace'
grep -F 'the first is at bytes' \
    "$CASES/member_name_collision.stderr" >/dev/null ||
    fail 'the duplicate-member refusal does not carry both declaration spans'
grep -F 'rename one' "$CASES/member_name_collision.stderr" >/dev/null ||
    fail 'the duplicate-member refusal states no remedy'

# The same spelling under a different owner stays legal: the key is scoped to
# the owner, so two traits may each declare `equal`.
"$WORK/kofun-traits-frontend" "$CASES/member_name_distinct_owners.kofun" \
    "$WORK/distinct_owners.ir" "$WORK/distinct_owners.tokens" ||
    fail 'the same member name under two owners was refused'

# Two members of one owner may share a parameter spelling. Value parameters
# are scoped to the member, which is what keying the collision by the member
# rather than by the trait made possible.
"$WORK/kofun-traits-frontend" "$CASES/member_shared_parameter_names.kofun" \
    "$WORK/shared_parameters.ir" "$WORK/shared_parameters.tokens" ||
    fail 'two members sharing a parameter spelling were refused'

# `inherited_member_source` is the inherited-member source shape a reader would
# reach for. No inheritance edge exists to recognise it, so it is refused as
# punctuation: the message names a delimiter and neither trait. RFC-0005
# proposes keeping the refusal and giving it `E371`, so the reason is stated
# rather than inferred from a parse position; that too awaits review.
grep -F "expected '{'" \
    "$CASES/inherited_member_source.stderr" >/dev/null ||
    fail 'a supertrait clause is no longer refused as a delimiter'
! grep -F 'Base' "$CASES/inherited_member_source.stderr" >/dev/null ||
    fail 'the supertrait refusal now names the inherited member source'

# Declaration order must not select between candidates. `order_independence`
# is the positive program with every implementation declared in the opposite
# order; each call must reach the same trait and self-type, so only the
# declaration ordinal each identity carries may move.
"$WORK/kofun-traits-frontend" "$CASES/order_independence.kofun" \
    "$WORK/order.ir" "$WORK/order.tokens" \
    >"$WORK/order.stdout" 2>"$WORK/order.stderr"
test ! -s "$WORK/order.stdout" || fail 'reordered run wrote stdout'
test ! -s "$WORK/order.stderr" || fail 'reordered run wrote stderr'
selection() {
    grep '^call|' "$1" |
        sed -e 's/.*callee=\(function:[a-z_]*\)|.*/\1/' >"$2.callee"
    grep '^call|' "$1" |
        sed -e 's/.*selected-implementation=impl:[^/]*\/package:[^/]*\///' \
            -e 's/\/decl=[0-9]*|.*//' >"$2.selection"
}
selection "$WORK/positive.first.ir" "$WORK/declared"
selection "$WORK/order.ir" "$WORK/reordered"
cmp "$WORK/declared.callee" "$WORK/reordered.callee" ||
    fail 'reordering the implementations changed which function is called'
cmp "$WORK/declared.selection" "$WORK/reordered.selection" ||
    fail 'declaration order selected between implementation candidates'
test -s "$WORK/declared.selection" ||
    fail 'no selections were compared for order independence'

# The DictionaryId carries no declaration ordinal, so unlike the
# ImplementationId it must survive reordering byte for byte — the set of
# dictionaries and the dictionary each call passes both compare unstripped.
dictionary_ids() {
    grep '^dictionary|' "$1" |
        sed -e 's/^dictionary|dictionary-id=\([^|]*\)|.*/\1/' |
        sort >"$2"
}
dictionary_ids "$WORK/positive.first.ir" "$WORK/declared.dictionaries"
dictionary_ids "$WORK/order.ir" "$WORK/reordered.dictionaries"
cmp "$WORK/declared.dictionaries" "$WORK/reordered.dictionaries" ||
    fail 'reordering the implementations changed a DictionaryId'
test -s "$WORK/declared.dictionaries" ||
    fail 'no DictionaryIds were compared for order independence'
passed_dictionaries "$WORK/order.ir" "$WORK/reordered.passed"
cmp "$WORK/call.passed" "$WORK/reordered.passed" ||
    fail 'declaration order changed which dictionary a call passes'

ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/kofun-traits-sanitize" "$CASES/positive.kofun" \
    "$WORK/sanitize.ir" "$WORK/sanitize.tokens" \
    >"$WORK/sanitize.stdout" 2>"$WORK/sanitize.stderr"
test ! -s "$WORK/sanitize.stdout" ||
    fail 'sanitized positive run wrote stdout'
test ! -s "$WORK/sanitize.stderr" ||
    fail 'ASan/UBSan reported a positive-path finding'
cmp "$CASES/positive.ir" "$WORK/sanitize.ir" ||
    fail 'sanitized trait IR differs'

IFS='
'
for entry in $failures; do
    test -n "$entry" || continue
    stem=${entry%%:*}
    set +e
    ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/kofun-traits-sanitize" "$CASES/$stem.kofun" \
        "$WORK/$stem.sanitize.ir" "$WORK/$stem.sanitize.tokens" \
        >"$WORK/$stem.sanitize.actual" \
        2>"$WORK/$stem.sanitize.internal.stderr"
    status=$?
    set -e
    test "$status" -eq 1 ||
        fail "sanitized $stem exited $status instead of 1"
    cmp "$CASES/$stem.stderr" "$WORK/$stem.sanitize.actual" ||
        fail "sanitized $stem diagnostic differs"
    test ! -s "$WORK/$stem.sanitize.internal.stderr" ||
        fail "ASan/UBSan reported a finding for $stem"
    test ! -e "$WORK/$stem.sanitize.ir" ||
        fail "sanitized $stem emitted rejected typed IR"
    test ! -e "$WORK/$stem.sanitize.tokens" ||
        fail "sanitized $stem emitted rejected tokens"
done
IFS=$previous_ifs

# The refusal corpus is globbed rather than listed twice, so a fixture added
# without a gate entry stops the build (DD-022).
declared=$(printf '%s' "$failures" | grep -c ':')
present=$(find "$CASES" -name '*.stderr' -type f | wc -l | tr -d ' ')
test "$declared" -eq "$present" ||
    fail "gate lists $declared refusals but $present fixtures exist"

test -z "$(find "$WORK" -type f \
    \( -name '*.generated.c' -o -name '*.o' -o -name '*.wasm' \
       -o -name '*.elf' -o -name '*.native' \) -print)" ||
    fail 'trait frontend emitted a backend/runtime artifact'

printf '%s\n' \
    'PASS: traits, implementations, and bounded calls produce typed IR' \
    'PASS: TraitId, MethodId, and ImplementationId identities are stable' \
    'PASS: the #403 orphan rule admits and refuses exactly its cases' \
    'PASS: bound resolution yields one implementation or a stable diagnostic' \
    'PASS: dictionary descriptors, values, parameters, and arguments elaborate' \
    'PASS: two members fill their slots by name, in declared order, and both dispatch' \
    'PASS: a missing, unknown, or twice-written implementation member is refused' \
    'PASS: each DictionaryId derives from its ImplementationId and ignores order' \
    'PASS: a duplicate member is refused as E370 naming both declarations; the same name under another owner is legal' \
    'PASS: two members of one owner may share a parameter spelling' \
    'PASS: typed-only boundaries, GCC analyzer, and ASan/UBSan remain clean'

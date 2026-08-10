#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/stdlib/tzdb"
ASSERT_CONTEXT="tzdb producer"
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/build.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-tzdb.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15
cc=${CC:-cc}

fail() {
    printf 'tzdb producer: FAIL: %s\n' "$*" >&2
    exit 1
}

producer="$CASES/tzdb.kofun"
expected="$CASES/tzdb.stdout"
readme="$CASES/README.md"

canonical="$ROOT/stdlib/tzdb/tzdb.kofun"
assert_regular_file 'canonical tzdb surface' "$canonical"

for declaration in \
    'type ZoneId = {' \
    'type UtcOffset = {' \
    'type Instant = {' \
    'type LocalDateTime = {' \
    'type Transition = {' \
    'type Tzdb = {' \
    'type TzdbError =' \
    'type Resolution =' \
    'type FoldPolicy =' \
    'type GapPolicy =' \
    'type ResolutionPolicyError =' \
    'type AppliedResolution = {' \
    'fn tzdb_read(input: Bytes)' \
    'fn tzdb_resolve_local(' \
    'fn tzdb_resolve_instant(' \
    'fn tzdb_apply_fold(' \
    'fn tzdb_apply_gap(' \
    'fn tzdb_serialize_applied('
do
    assert_grep 'canonical tzdb surface lost a declaration' \
        -Fq -- "$declaration" "$canonical"
done

# The whole contract rests on this: the two cases that name more than one
# offset carry both of them, rather than handing back one as the answer.
assert_grep 'canonical Ambiguous no longer carries both offsets' -Fq -- \
    '| Ambiguous(earlier: UtcOffset, later: UtcOffset)' "$canonical"
assert_grep 'canonical Nonexistent no longer carries the offsets either side' \
    -Fq -- '| Nonexistent(before: UtcOffset, after: UtcOffset)' "$canonical"
assert_grep 'canonical fold policy lost its explicit alternatives' -Fq -- \
    '| FoldEarlier' "$canonical"
assert_grep 'canonical gap policy lost shift-forward' -Fq -- \
    '| GapShiftForward' "$canonical"
assert_grep 'canonical fold refusal is no longer typed' -Fq -- \
    '| FoldPolicyRefused(resolved: ResolvedLocal)' "$canonical"
assert_grep 'canonical gap refusal is no longer typed' -Fq -- \
    '| GapPolicyRefused(resolved: ResolvedLocal)' "$canonical"

# The canonical file is still ahead of the compiler. Pinning that keeps the
# corpus honest: the executable evidence is the producer, not this.
if "$ROOT/bin/kofun" check "$canonical" \
    >"$WORK/canonical.stdout" 2>"$WORK/canonical.stderr"
then
    fail "canonical source unexpectedly claimed executable codegen: $canonical"
fi
# The boundary moved past `ZoneId` when #1181 admitted `Text` record fields:
# `ZoneId` is `{ name: Text }` and now declares. `Transition` is the next
# record out, carrying `Instant` and `UtcOffset` fields, so it is what the
# canonical source stops at today. The assertion names the record rather than
# the file so that when the boundary moves again the failure says which one.
assert_grep 'canonical source did not stop at the documented compiler boundary' \
    -Fq -- 'error[E2S32]: record `Transition` has a field type outside the Stage 2 Int/Bool/Text slice' \
    "$WORK/canonical.stderr"

assert_regular_file 'Kofun tzdb producer' "$producer"
assert_regular_file 'tzdb exact golden' "$expected"
assert_regular_file 'tzdb boundary documentation' "$readme"

find "$CASES" -type f \( -name '*.py' -o -name '*.kf' \) >"$WORK/forbidden"
assert_file_empty 'forbidden Python or .kf source in the corpus' "$WORK/forbidden"
assert_not_grep 'producer imports an ambient dependency' -q -- '^import ' "$producer"
assert_not_grep 'producer names host time, file, zoneinfo, locale, network, or randomness' \
    -qE -- 'clock_gettime|nanosleep|fopen|open\(|zoneinfo|localtime|setlocale|socket\(|connect\(|random|rand\(' \
    "$producer"

command -v "$cc" >/dev/null 2>&1 || fail 'a C11 compiler is required'
kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"

"$WORK/kofun-stage2" "$producer" "$WORK/tzdb.c" \
    "$WORK/tzdb.ir" "$WORK/tzdb.tokens" \
    >"$WORK/stage2.stdout" 2>"$WORK/stage2.stderr" ||
    fail "Stage 2 producer failed: $(cat "$WORK/stage2.stderr")"
assert_file_nonempty 'typed tzdb HIR' "$WORK/tzdb.ir"
assert_file_nonempty 'emitted tzdb C11 source' "$WORK/tzdb.c"

for type_name in Bytes20 ZoneId Transition TzdbMetadata Instant \
    LocalDateTime UtcOffset Tzdb LoadResult SerializedResolution \
    SerializedAppliedResolution
do
    assert_grep "typed HIR carries $type_name" \
        -Fq -- "record|$type_name|" "$WORK/tzdb.ir"
done

for constructor in Unique Ambiguous Nonexistent ResolutionFailed \
    MalformedInput UnsupportedVersion DigestMismatch InvalidZone \
    TruncatedBytes TrailingBytes ArithmeticOverflow OversizedInput LimitExhausted \
    FoldEarlier FoldLater FoldReject GapShiftForward GapReject \
    PolicyApplied FoldPolicyRefused GapPolicyRefused
do
    assert_grep "typed HIR carries constructor $constructor" \
        -Fq -- "constructor|$constructor|" "$WORK/tzdb.ir"
done
assert_grep 'typed HIR carries the recursive byte digest' \
    -Fq -- 'function|digest_bytes|3|' "$WORK/tzdb.ir"
assert_grep 'typed HIR carries local-time resolution' \
    -Fq -- 'function|resolve_local|2|' "$WORK/tzdb.ir"
assert_grep 'typed HIR carries provenance serialization' \
    -Fq -- 'function|serialize_resolution|2|' "$WORK/tzdb.ir"
assert_grep 'typed HIR carries fold policy application' \
    -Fq -- 'function|apply_fold_policy|2|' "$WORK/tzdb.ir"
assert_grep 'typed HIR carries gap policy application' \
    -Fq -- 'function|apply_gap_policy|2|' "$WORK/tzdb.ir"
assert_eq 'both arithmetic guards carry the offending local operand' \
    "$(grep -Fc -- 'return ResolutionFailed(local.wall_seconds)' "$producer")" '2'
assert_grep 'arithmetic failure kind stays distinct from its payload' \
    -Fq -- 'ResolutionFailed(_) => { kind = code_arithmetic_overflow() }' \
    "$producer"

"$cc" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/tzdb.c" -o "$WORK/tzdb" ||
    fail 'emitted tzdb C11 source did not compile with warnings as errors'
assert_executable 'emitted tzdb C11 program' "$WORK/tzdb"

"$WORK/tzdb" >"$WORK/backend.stdout" 2>"$WORK/backend.stderr" ||
    fail "C11 backend failed: $(cat "$WORK/backend.stderr")"
cmp "$expected" "$WORK/backend.stdout" ||
    fail 'C11 backend output differs from the exact tzdb golden'

"$ROOT/bin/kofun" run "$producer" \
    >"$WORK/reference.stdout" 2>"$WORK/reference.stderr" ||
    fail "reference executor failed: $(cat "$WORK/reference.stderr")"
cmp "$expected" "$WORK/reference.stdout" ||
    fail 'reference executor output differs from the exact tzdb golden'

"$WORK/tzdb" >"$WORK/backend.second"
cmp "$WORK/backend.stdout" "$WORK/backend.second" ||
    fail 'two executions of the same tzdb binary differ'

# Independence from ambient time-zone and locale state, demonstrated rather
# than grepped for. The greps prove the symbols are not named; these runs prove
# the behaviour, which is the claim that matters to a caller. The empty
# environment is included because a program that needed TZ would more likely
# fall back than fail, and a fallback would not show up as a difference between
# two hostile settings.
TZ=Pacific/Kiritimati LC_ALL=C LANG=C "$WORK/tzdb" >"$WORK/hostile.stdout"
cmp "$WORK/backend.stdout" "$WORK/hostile.stdout" ||
    fail 'output changed under TZ=Pacific/Kiritimati'
TZ=America/Sao_Paulo LC_ALL=tr_TR.UTF-8 LANG=tr_TR.UTF-8 "$WORK/tzdb" \
    >"$WORK/hostile.locale.stdout"
cmp "$WORK/backend.stdout" "$WORK/hostile.locale.stdout" ||
    fail 'output changed under a different time zone and locale'
env -i "$WORK/tzdb" >"$WORK/bare.stdout"
cmp "$WORK/backend.stdout" "$WORK/bare.stdout" ||
    fail 'output changed with an empty environment'

assert_not_grep 'emitted C reaches ambient time, file, zoneinfo, locale, network, or randomness' \
    -qE -- 'time\.h|clock_gettime|gettimeofday|nanosleep|fopen|zoneinfo|localtime|setlocale|socket|connect|rand\(' \
    "$WORK/tzdb.c"
for record_name in Bytes20 ZoneId Transition TzdbMetadata Instant \
    LocalDateTime UtcOffset Tzdb LoadResult SerializedResolution \
    SerializedAppliedResolution
do
    assert_grep "emitted C contains $record_name" \
        -Fq -- "KofunRecord_$record_name" "$WORK/tzdb.c"
done
assert_grep 'emitted C contains the closed enum runtime value' \
    -Fq -- 'KofunEnumValue' "$WORK/tzdb.c"
assert_grep 'emitted C computes the fixture digest in producer code' \
    -Fq -- 'kofun_fn_digest_bytes' "$WORK/tzdb.c"
assert_grep 'emitted C resolves local time in producer code' \
    -Fq -- 'kofun_fn_resolve_local' "$WORK/tzdb.c"
assert_grep 'emitted C serializes provenance in producer code' \
    -Fq -- 'kofun_fn_serialize_resolution' "$WORK/tzdb.c"
assert_grep 'emitted C applies fold policy in producer code' \
    -Fq -- 'kofun_fn_apply_fold_policy' "$WORK/tzdb.c"
assert_grep 'emitted C applies gap policy in producer code' \
    -Fq -- 'kofun_fn_apply_gap_policy' "$WORK/tzdb.c"

field() {
    sed -n "$1p" "$expected"
}

assert_eq 'load succeeded' "$(field 1)" '0'
assert_eq 'schema version is bound' "$(field 2)" '1'
assert_num 'content digest is nonzero' "$(field 3)" -gt 0
assert_eq 'ZoneId Test/GapFold code is preserved' "$(field 4)" '7'
assert_eq 'first transition UTC instant' "$(field 5)" '1000'
assert_eq 'first transition before offset' "$(field 6)" '0'
assert_eq 'first transition after offset' "$(field 7)" '100'
assert_eq 'second transition UTC instant' "$(field 8)" '2000'
assert_eq 'second transition before offset' "$(field 9)" '100'
assert_eq 'second transition after offset' "$(field 10)" '0'
assert_eq 'Instant pass/return/read observation' "$(field 11)" '1400'
assert_eq 'normal local result is Unique' "$(field 12)" '1'
assert_eq 'local 1500 maps to UTC 1400' "$(field 13)" '1400'
assert_eq 'gap result is Nonexistent' "$(field 14)" '3'
assert_eq 'gap next valid UTC instant' "$(field 15)" '1000'
assert_eq 'fold result is Ambiguous' "$(field 16)" '2'
assert_eq 'fold preserves earlier and later UTC instants' "$(field 17)" '195002050'

assert_eq 'malformed magic error code' "$(field 18)" '-1'
assert_eq 'malformed magic byte position' "$(field 19)" '0'
assert_eq 'unsupported version error code' "$(field 20)" '-2'
assert_eq 'unsupported version detail' "$(field 21)" '2'
assert_eq 'digest mismatch error code' "$(field 22)" '-3'
assert_eq 'digest mismatch reports observed digest' "$(field 23)" "$(field 3)"
assert_eq 'invalid zone error code' "$(field 24)" '-4'
assert_eq 'invalid zone detail' "$(field 25)" '8'
assert_eq 'truncated bytes error code' "$(field 26)" '-5'
assert_eq 'truncated bytes length' "$(field 27)" '17'
assert_eq 'trailing bytes error code' "$(field 28)" '-6'
assert_eq 'trailing byte count' "$(field 29)" '1'
assert_eq 'oversized input error code' "$(field 30)" '-8'
assert_eq 'oversized input length' "$(field 31)" '21'
assert_eq 'transition limit error code' "$(field 32)" '-9'
assert_eq 'transition limit detail' "$(field 33)" '3'
assert_eq 'arithmetic overflow error code' "$(field 34)" '-7'
assert_eq 'arithmetic overflow reports the offending local operand' \
    "$(field 35)" '-9223372036854775808'

# The edges of the gap and the fold. Nothing above reads one: the resolver gets
# them right — `local >= start && local < end` for both — but an off-by-one at
# an edge is the classic way an hour goes missing, and until now nothing pinned
# it. Half-open at the top means the first local second of an interval is
# inside it and the first second after is not.
assert_eq 'the gap includes its low edge' "$(field 36)" '3'
assert_eq 'the gap excludes its high edge' "$(field 37)" '1'
assert_eq 'the second past the gap maps through the new offset' \
    "$(field 38)" '1000'
assert_eq 'the fold includes its low edge' "$(field 39)" '2'
assert_eq 'the fold excludes its high edge' "$(field 40)" '1'
assert_eq 'the second past the fold maps through the new offset' \
    "$(field 41)" '2100'

assert_resolution_row() {
    label=$1
    first=$2
    expected_digest=$3
    expected_kind=$4
    expected_payload=$5

    assert_eq "$label carries the zone" "$(field "$first")" '7'
    assert_eq "$label carries the format version" \
        "$(field "$((first + 1))")" '1'
    assert_eq "$label carries its content digest" \
        "$(field "$((first + 2))")" "$expected_digest"
    assert_eq "$label carries its resolution kind" \
        "$(field "$((first + 3))")" "$expected_kind"
    assert_eq "$label carries its resolution payload" \
        "$(field "$((first + 4))")" "$expected_payload"
}

assert_resolution_row 'serialized normal resolution' 42 "$(field 3)" 1 1400
assert_resolution_row 'serialized gap resolution' 47 "$(field 3)" 3 1000
assert_resolution_row 'serialized fold resolution' 52 "$(field 3)" 2 195002050

drift_digest=$(field 59)
assert_ne 'one-byte rule drift changes the content digest' \
    "$drift_digest" "$(field 3)"
assert_resolution_row 'drifted normal resolution' 57 "$drift_digest" 1 1400
assert_resolution_row 'drifted gap resolution' 62 "$drift_digest" 3 1001
assert_resolution_row 'drifted fold resolution' 67 "$drift_digest" 2 195002050
assert_eq 'original fixture transition byte 6' "$(field 72)" '232'
assert_eq 'drifted fixture changes byte 6 by one' "$(field 73)" '233'

assert_applied_row() {
    label=$1
    first=$2
    expected_kind=$3
    expected_payload=$4
    expected_policy=$5
    expected_outcome=$6
    expected_outcome_payload=$7

    assert_eq "$label carries the zone" "$(field "$first")" '7'
    assert_eq "$label carries the format version" \
        "$(field "$((first + 1))")" '1'
    assert_eq "$label carries the content digest" \
        "$(field "$((first + 2))")" "$(field 3)"
    assert_eq "$label carries the original resolution kind" \
        "$(field "$((first + 3))")" "$expected_kind"
    assert_eq "$label carries the original resolution payload" \
        "$(field "$((first + 4))")" "$expected_payload"
    assert_eq "$label records the explicit policy" \
        "$(field "$((first + 5))")" "$expected_policy"
    assert_eq "$label carries the typed outcome" \
        "$(field "$((first + 6))")" "$expected_outcome"
    assert_eq "$label carries the outcome payload" \
        "$(field "$((first + 7))")" "$expected_outcome_payload"
}

assert_applied_row 'fold Earlier' 74 2 195002050 1 1 1950
assert_applied_row 'fold Later' 82 2 195002050 2 1 2050
assert_applied_row 'fold Reject' 90 2 195002050 3 -10 3
assert_applied_row 'gap ShiftForward' 98 3 1000 4 1 1000
assert_applied_row 'gap Reject' 106 3 1000 5 -11 5
assert_applied_row 'Unique under FoldReject' 114 1 1400 3 1 1400

assert_num 'fold refusal is distinct from every reader error' \
    "$(field 96)" -lt -9
assert_num 'gap refusal is distinct from every reader error' \
    "$(field 112)" -lt -9

assert_num 'golden line count' "$(wc -l <"$expected" | tr -d ' ')" -eq 121

# A local reading and an instant are both one number. Keeping them apart is the
# whole reason the resolution sum has anywhere to live, so the toolchain must
# refuse to confuse them — at `check`, not only once the backend runs.

expect_rejected() {
    stem=$1
    reason=$2

    if "$ROOT/bin/kofun" check "$CASES/$stem.kofun" \
        >"$WORK/$stem.check.stdout" 2>"$WORK/$stem.check.stderr"
    then
        fail "$stem passed \`kofun check\`; the separate tzdb types did not stop it"
    fi
    assert_grep "$stem was rejected by check for the wrong reason" \
        -Fq -- "$reason" "$WORK/$stem.check.stderr"

    if "$ROOT/bin/kofun" build "$CASES/$stem.kofun" -o "$WORK/$stem" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    then
        fail "$stem built after check refused it"
    fi
    assert_grep "$stem was rejected by build for the wrong reason" \
        -Fq -- "$reason" "$WORK/$stem.stderr"
    assert_absent "$stem emitted a binary despite being refused" "$WORK/$stem"

    printf 'tzdb: refused by check and build: %s\n' "$stem"
}

expect_rejected mixed_local_instant \
    'error[E2S32]: nominal record binding has the wrong type'
expect_rejected local_wall_seconds_on_instant \
    'error[E2S32]: unknown nominal record field read'

# Derive the negative call site from the authoritative producer so the refusal
# cannot drift into a miniature duplicate API. Removing the one explicit policy
# must fail before a binary exists; there is no Earlier/Later/Shift default.
no_default="$WORK/no-default-policy.kofun"
sed 's/serialize_fold_application(serialized_fold, FoldEarlier(0))/serialize_fold_application(serialized_fold)/' \
    "$producer" >"$no_default"
assert_grep 'no-policy probe did not remove the explicit policy argument' \
    -Fq -- 'serialize_fold_application(serialized_fold)' "$no_default"
if "$ROOT/bin/kofun" check "$no_default" \
    >"$WORK/no-default.check.stdout" 2>"$WORK/no-default.check.stderr"
then
    fail 'a fold application without a policy passed `kofun check`'
fi
assert_grep 'missing policy was refused for the wrong reason' -Fq -- \
    'error[E2S17]: Core function `serialize_fold_application` expects 2 arguments, got 1' \
    "$WORK/no-default.check.stderr"
if "$ROOT/bin/kofun" build "$no_default" -o "$WORK/no-default" \
    >"$WORK/no-default.build.stdout" 2>"$WORK/no-default.build.stderr"
then
    fail 'a fold application without a policy produced a binary'
fi
assert_grep 'missing policy build was refused for the wrong reason' -Fq -- \
    'error[E2S17]: Core function `serialize_fold_application` expects 2 arguments, got 1' \
    "$WORK/no-default.build.stderr"
assert_absent 'missing-policy call emitted a binary' "$WORK/no-default"

# FoldPolicy and GapPolicy are not interchangeable. As with the no-default
# probe, mutate the real call site instead of maintaining a duplicate API.
wrong_policy="$WORK/wrong-policy-domain.kofun"
sed 's/GapShiftForward(0)/FoldEarlier(0)/' "$producer" >"$wrong_policy"
if "$ROOT/bin/kofun" check "$wrong_policy" \
    >"$WORK/wrong-policy.check.stdout" 2>"$WORK/wrong-policy.check.stderr"
then
    fail 'a fold policy was accepted by the gap-policy operation'
fi
assert_grep 'mixed fold/gap policy was refused for the wrong reason' -Fq -- \
    'error[E2S32]: concrete enum constructor `FoldEarlier` is only valid' \
    "$WORK/wrong-policy.check.stderr"
if "$ROOT/bin/kofun" build "$wrong_policy" -o "$WORK/wrong-policy" \
    >"$WORK/wrong-policy.build.stdout" 2>"$WORK/wrong-policy.build.stderr"
then
    fail 'a fold policy passed the gap-policy operation during build'
fi
assert_grep 'mixed policy build was refused for the wrong reason' -Fq -- \
    'error[E2S32]: concrete enum constructor `FoldEarlier` is only valid' \
    "$WORK/wrong-policy.build.stderr"
assert_absent 'mixed fold/gap policy emitted a binary' "$WORK/wrong-policy"

printf '%s\n' \
    'tzdb injected Bytes and versioned digest: PASS' \
    'tzdb normal, gap, and fold resolution: PASS' \
    'tzdb malformed, version, digest, zone, truncation, trailing, overflow, size, and limit errors: PASS' \
    'tzdb gap and fold edges are half-open at the top: PASS' \
    'tzdb local readings and instants cannot be confused: PASS' \
    'tzdb per-resolution provenance and one-byte drift: PASS' \
    'tzdb explicit fold/gap policy, typed refusal, and no default: PASS' \
    'tzdb bytes do not move under a hostile TZ, locale, or an empty environment: PASS' \
    'tzdb reference and C11 backend observations: PASS'

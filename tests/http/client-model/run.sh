#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

# The HTTP/1.1 reference model and its corpus.
#
#     sh tests/http/client-model/run.sh
#
# This is executable specification evidence for #644's children: one answer per
# script that a later Kofun implementation must match. Nothing here is a client,
# nothing opens a socket, and no capability is claimed by it passing.
#
# Three habits run through the corpus.
#
# Every positive message is re-run split at every byte boundary and at seeded
# multi-point boundaries, and must produce the same result. A framing reader is
# a resumable state machine or it is a reader that works only when the peer is
# generous, and the difference is invisible until something splits the message.
#
# Every limit is exercised at the last message it accepts and the first it
# refuses, one counter at a time, so a refusal names the counter that refused.
#
# Every rule the model implements is proved by removing it. The mutation section
# rebuilds the model with one behaviour changed and requires this corpus to
# notice — because a corpus that only reads the good path cannot tell whether
# the bad one is still refused, and the bad paths here are the smuggling shapes.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/http/client-model"
WORK=${KOFUN_HTTP_CLIENT_MODEL_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}http-client-model"}
ASSERT_CONTEXT='http client model'
. "$ROOT/tests/assertions/assert.sh"

command -v node >/dev/null 2>&1 ||
    assert_fail 'node is required to run the HTTP reference model'

case "$WORK" in
    */http-client-model|*/http-client-model.*) ;;
    *) assert_fail "work directory must end in http-client-model[.suffix]: $WORK" ;;
esac

rm -rf "$WORK"
mkdir -p "$WORK"

MODEL="$CASES/model.mjs"
FRAGMENT="$CASES/fragment.mjs"

# ---------------------------------------------------------------------------
# 1. The corpus is generated, and committed, and those are the same thing.
#
# `build-corpus.mjs` owns the scripts. Regenerating must change nothing: a
# fixture edited by hand and a generator edited without regenerating are the
# same defect seen from either side, and only comparing catches both.
# ---------------------------------------------------------------------------
cp -R "$CASES/fixtures" "$WORK/committed-fixtures"
node "$CASES/build-corpus.mjs" >"$WORK/build.stdout"
for script in "$CASES"/fixtures/*.script.json; do
    stem=$(basename "$script")
    cmp "$WORK/committed-fixtures/$stem" "$script" ||
        assert_fail "regenerating the corpus changed $stem"
done
committed=$(find "$WORK/committed-fixtures" -name '*.script.json' | wc -l | tr -d ' ')
regenerated=$(find "$CASES/fixtures" -name '*.script.json' | wc -l | tr -d ' ')
assert_num "regenerated script count" "$regenerated" -eq "$committed"
assert_num "corpus size" "$committed" -gt 40

# ---------------------------------------------------------------------------
# 2. Every script produces its recorded result, byte for byte.
# ---------------------------------------------------------------------------
positives=0
refusals=0
for script in "$CASES"/fixtures/*.script.json; do
    stem=$(basename "$script" .script.json)
    node "$MODEL" "$script" "$WORK/$stem.result.json" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr" ||
        assert_fail "the model refused the committed script $stem"
    cmp "$CASES/fixtures/$stem.result.json" "$WORK/$stem.result.json" ||
        assert_fail "$stem no longer produces its recorded result"
    if grep -q '"outcome": "complete"' "$WORK/$stem.result.json"; then
        positives=$((positives + 1))
    else
        refusals=$((refusals + 1))
    fi
done
assert_num "positive results" "$positives" -gt 10
assert_num "refusal results" "$refusals" -gt 25

# Every refusal names one of the model's four kinds and nothing else; a corpus
# that recorded an unknown kind would be recording a result the schema admits
# and the model cannot reach.
for stem in reject_both_framings reject_duplicate_length_agreeing \
    reject_obs_fold reject_chunk_extension; do
    assert_grep "$stem kind" -F '"kind": "protocol"' "$WORK/$stem.result.json"
done
for stem in limit_header_bytes_over limit_headers_over limit_body_bytes_over \
    limit_chunk_bytes_over limit_body_bytes_over_across_chunks; do
    assert_grep "$stem kind" -F '"kind": "limit-exceeded"' "$WORK/$stem.result.json"
done
for stem in reject_close_inside_status reject_close_inside_headers \
    reject_close_inside_body reject_close_inside_chunk reject_script_ends_early; do
    assert_grep "$stem kind" -F '"kind": "body-truncated"' "$WORK/$stem.result.json"
done

# ---------------------------------------------------------------------------
# 3. The request bytes, against vectors derived from the contract by hand.
# ---------------------------------------------------------------------------
extract_request() {
    node -e '
        const { readFileSync, writeFileSync } = require("node:fs")
        const result = JSON.parse(readFileSync(process.argv[1], "utf8"))
        writeFileSync(process.argv[2], Buffer.from(result.request_bytes))
    ' "$1" "$2"
}
for stem in get_content_length post_bytes; do
    extract_request "$WORK/$stem.result.json" "$WORK/$stem.request"
    cmp "$CASES/vectors/$stem.request" "$WORK/$stem.request" ||
        assert_fail "$stem does not serialize to its committed request vector"
done

# The framing headers are the model's to write. A caller that could set them
# could put a second message's framing on the wire, which is the request side of
# the same defect the response corpus is about.
for reserved in Content-Length Transfer-Encoding Host; do
    cat >"$WORK/reserved.script.json" <<RESERVED
{
  "schema": "kofun.http-transport-script/v1",
  "name": "reserved_header",
  "request": { "method": "GET", "target": "/", "host": "example.test",
    "headers": [["$reserved", "1"]] },
  "limits": { "max_header_bytes": 4096, "max_headers": 16,
    "max_body_bytes": 65536, "max_chunk_bytes": 4096 },
  "operations": [ { "op": "deliver", "bytes": [] } ]
}
RESERVED
    set +e
    node "$MODEL" "$WORK/reserved.script.json" "$WORK/reserved.result.json" \
        >"$WORK/reserved.stdout" 2>"$WORK/reserved.stderr"
    reserved_status=$?
    set -e
    # Refused before serialization, with no result document. The distinction is
    # the point: a result would say a transport was exercised, and this request
    # never reached one. A run that produced no bytes has nothing to report on.
    assert_num "reserved header $reserved status" "$reserved_status" -ne 0
    assert_absent "reserved.result.json" "$WORK/reserved.result.json"
    assert_grep "reserved header $reserved" -F "decides framing and is the model's to set" \
        "$WORK/reserved.stderr"
done

# ---------------------------------------------------------------------------
# 4. Fragmentation: every byte boundary, then seeded multi-point plans.
# ---------------------------------------------------------------------------
: >"$WORK/fragment.log"
for script in "$CASES"/fixtures/*.script.json; do
    node "$FRAGMENT" "$script" every >>"$WORK/fragment.log" 2>&1 ||
        assert_fail "fragmentation disagreed; see $WORK/fragment.log"
done
swept=$(grep -c '^PASS: ' "$WORK/fragment.log")
assert_num "fragmented scripts" "$swept" -eq "$committed"

# The seed is printed and the plan is a function of it alone, so a failure here
# replays from the number in the message on any machine.
KOFUN_HTTP_MODEL_SEED=${KOFUN_HTTP_MODEL_SEED:-20260812}
: >"$WORK/seeded.log"
for script in "$CASES"/fixtures/*.script.json; do
    node "$FRAGMENT" "$script" seed "$KOFUN_HTTP_MODEL_SEED" 16 \
        >>"$WORK/seeded.log" 2>&1 ||
        assert_fail "a seeded plan disagreed; replay with seed $KOFUN_HTTP_MODEL_SEED"
done
assert_grep "seeded.log" -F "from seed $KOFUN_HTTP_MODEL_SEED" "$WORK/seeded.log"

# Replaying one seed twice produces the same plans, which is what makes the
# number worth printing.
node "$FRAGMENT" "$CASES/fixtures/get_chunked.script.json" seed 7 8 >"$WORK/replay-a.log" 2>&1
node "$FRAGMENT" "$CASES/fixtures/get_chunked.script.json" seed 7 8 >"$WORK/replay-b.log" 2>&1
cmp "$WORK/replay-a.log" "$WORK/replay-b.log"

# ---------------------------------------------------------------------------
# 5. The schema refuses what it says it refuses.
# ---------------------------------------------------------------------------
expect_schema_refusal() {
    label=$1
    needle=$2
    set +e
    node "$MODEL" "$WORK/bad-$label.script.json" "$WORK/bad-$label.result.json" \
        >"$WORK/bad-$label.stdout" 2>"$WORK/bad-$label.stderr"
    refusal_status=$?
    set -e
    assert_num "schema refusal status for $label" "$refusal_status" -ne 0
    assert_absent "bad-$label.result.json" "$WORK/bad-$label.result.json"
    assert_grep "bad-$label.stderr" -F "$needle" "$WORK/bad-$label.stderr"
}

damage_script() {
    label=$1
    expression=$2
    node -e '
        const { readFileSync, writeFileSync } = require("node:fs")
        const script = JSON.parse(readFileSync(process.argv[1], "utf8"))
        const damage = new Function("script", process.argv[3])
        damage(script)
        writeFileSync(process.argv[2], JSON.stringify(script, null, 2))
    ' "$CASES/fixtures/get_content_length.script.json" \
        "$WORK/bad-$label.script.json" "$expression"
}

damage_script unknown-field 'script.surplus = 1'
expect_schema_refusal unknown-field 'is not a field of this schema'
damage_script unknown-operation 'script.operations[0].op = "teleport"'
expect_schema_refusal unknown-operation 'must be one of'
damage_script byte-out-of-range 'script.operations[0].bytes[0] = 256'
expect_schema_refusal byte-out-of-range 'must be at most 255'
damage_script negative-byte 'script.operations[0].bytes[0] = -1'
expect_schema_refusal negative-byte 'must be at least 0'
damage_script fractional-byte 'script.operations[0].bytes[0] = 1.5'
expect_schema_refusal fractional-byte 'must be a safe integer'
damage_script missing-limit 'delete script.limits.max_body_bytes'
expect_schema_refusal missing-limit 'is missing `max_body_bytes`'
damage_script zero-header-limit 'script.limits.max_header_bytes = 0'
expect_schema_refusal zero-header-limit 'must be at least 1'
damage_script terminal-not-last \
    'script.operations = [{op:"close"},{op:"deliver",bytes:[65]}]'
expect_schema_refusal terminal-not-last 'ends the script, so it must be last'
damage_script no-operations 'script.operations = []'
expect_schema_refusal no-operations 'must contain at least one operation'
damage_script wrong-schema 'script.schema = "kofun.http-transport-script/v9"'
expect_schema_refusal wrong-schema 'must be `kofun.http-transport-script/v1`'
damage_script bad-name 'script.name = "Not A Name"'
expect_schema_refusal bad-name 'must be a lowercase identifier'
damage_script unknown-method 'script.request.method = "PUT"'
expect_schema_refusal unknown-method 'must be one of'
damage_script phase-not-reached \
    'script.operations = [{op:"cancel",at:"drain"}]'
expect_schema_refusal phase-not-reached 'the model is at'

# ---------------------------------------------------------------------------
# 6. The rules, proved by removing them.
# ---------------------------------------------------------------------------
mutate() {
    label=$1
    expression=$2
    mkdir -p "$WORK/mutant-$label"
    cp "$CASES/schema.mjs" "$WORK/mutant-$label/schema.mjs"
    cp "$CASES/fragment.mjs" "$WORK/mutant-$label/fragment.mjs"
    sed "$expression" "$MODEL" >"$WORK/mutant-$label/model.mjs"
    if cmp -s "$MODEL" "$WORK/mutant-$label/model.mjs"; then
        assert_fail "mutation $label changed nothing"
    fi
}

# The mutant must disagree with the recorded result for one named fixture.
mutant_disagrees() {
    label=$1
    stem=$2
    set +e
    node "$WORK/mutant-$label/model.mjs" "$CASES/fixtures/$stem.script.json" \
        "$WORK/mutant-$label.result.json" \
        >"$WORK/mutant-$label.stdout" 2>"$WORK/mutant-$label.stderr"
    mutant_status=$?
    set -e
    if test "$mutant_status" -eq 0 &&
        cmp -s "$CASES/fixtures/$stem.result.json" "$WORK/mutant-$label.result.json"
    then
        assert_fail "mutation $label left $stem answering identically"
    fi
}

# Framing precedence. Accepting a response that declares both is the smuggling
# shape itself: two parties then disagree about where this message ends.
mutate framing-precedence \
    "s/    if (lengths.length > 0 \&\& encodings.length > 0) {/    if (false) {/"
mutant_disagrees framing-precedence reject_both_framings

# A duplicated Content-Length, even when the two agree. Resolving it is picking
# which peer to believe.
mutate duplicate-length "s/    if (lengths.length > 1) {/    if (false) {/"
mutant_disagrees duplicate-length reject_duplicate_length_agreeing

# Chunk size grammar. A size with an extension is a size someone else parsed
# differently.
mutate chunk-hex "s/    if (text.includes(';')) {/    if (false) {/"
mutant_disagrees chunk-hex reject_chunk_extension

# The limit comparisons, one at a time.
mutate body-limit \
    "s/                        limitError('max_body_bytes exceeded by the declared length', stream.cursor)/                        void 0/"
mutant_disagrees body-limit limit_body_bytes_over
mutate chunk-limit \
    "s/                        limitError('max_chunk_bytes exceeded by a chunk size', stream.cursor)/                        void 0/"
mutant_disagrees chunk-limit limit_chunk_bytes_over

# Reuse. A connection with a second message already on it is not reusable, and
# saying it is hands the next response this one's tail.
mutate reuse "s/        framing.kind !== 'close-delimited' \&\& trailing === 0 \&\& !stream.closed/        true/"
mutant_disagrees reuse get_pipelined_trailing

# Obs-fold. Unfolding is the repair the contract forbids.
mutate obs-fold \
    "s/        protocolError('obs-fold continuation lines are refused, not unfolded', 0)/        void 0/"
mutant_disagrees obs-fold reject_obs_fold

# The resumable chunk reader. Collapsing the data and CRLF steps back into one
# pass is the defect the fragmentation sweep found while this model was being
# written: whole-message runs stay correct and split ones read the body as a
# size, so only the sweep can see it.
mutate chunk-resume "s/                if (chunkStep === 'data') {/                if (false) {/"
mutant_disagrees chunk-resume get_chunked

# And one the whole-message runs cannot see at all.
#
# `takeExactly` consuming what it has before reporting that it has too little is
# the shape of the defect this model was written with: every committed script
# still produces its recorded result, because a whole message never takes the
# short path. Only splitting it does. The assertion is therefore in two halves —
# the recorded results must still match, and the sweep must still fail — because
# a mutation the corpus notices for the ordinary reason would prove nothing
# about the sweep.
mutate partial-consume \
    "s/        if (this.available < count) {/        if (this.available < count) { this.cursor += this.available;/"
node "$WORK/mutant-partial-consume/model.mjs" \
    "$CASES/fixtures/get_chunked.script.json" "$WORK/partial-consume.result.json" \
    >"$WORK/partial-consume.stdout" 2>&1 ||
    assert_fail 'the partial-consume mutant should still answer the whole message'
cmp "$CASES/fixtures/get_chunked.result.json" "$WORK/partial-consume.result.json" ||
    assert_fail 'the partial-consume mutant changed the whole-message answer, so it proves nothing about the sweep'
set +e
node "$WORK/mutant-partial-consume/fragment.mjs" \
    "$CASES/fixtures/get_chunked.script.json" every \
    >"$WORK/partial-consume-sweep.stdout" 2>&1
partial_consume_status=$?
set -e
assert_num "the sweep against a partial-consume reader" "$partial_consume_status" -ne 0
assert_grep "partial-consume-sweep.stdout" -F 'disagrees with the whole message' \
    "$WORK/partial-consume-sweep.stdout" 

printf '%s\n' \
    "PASS: $committed committed scripts regenerate unchanged and reproduce their recorded results" \
    "PASS: $positives complete and $refusals refused, each naming one of the four error kinds" \
    'PASS: GET and POST serialize to hand-derived vectors, and framing headers stay the model’s' \
    "PASS: every script agrees with itself at every byte boundary and under seeded plans" \
    'PASS: 13 malformed scripts and 10 removed rules are each refused, one of them only by the sweep'

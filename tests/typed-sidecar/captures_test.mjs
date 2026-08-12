// The #1224 gate: the production KSE2 capture codec against the frozen
// contract, and against a corrupted stream.
//
// The positive half is a join, not a golden. `spec/concurrency/scoped-captures-v1/model.mjs`
// is #1219's frozen oracle; `tooling/typed-sidecar/captures.mjs` is written
// independently of it. The test requires the two to produce the same bytes,
// the same decoded records, and the same projection — a golden would only
// prove the production reader still agrees with its own last output.
//
// The negative half is the part the oracle cannot supply. A producer is
// trusted to emit well-formed frames; a reader is not allowed to trust that,
// so every refusal below is a stream that is plausible up to the byte it is
// refused at.

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
    buildScopeHir,
    projectKse2CaptureSection,
    projectTypedSidecarCaptures,
    projectTypedSidecarV2,
} from '../../spec/concurrency/scoped-captures-v1/model.mjs'
import {
    CaptureCodecError,
    KSE2_LIMITS,
    decodeCanonicalPlaceBytes,
    decodeCaptureFrames,
    encodeCaptureEvent,
    encodeCaptureFrames,
    projectSidecarCaptures,
    projectSidecarV2,
    validateCaptureStream,
} from '../../tooling/typed-sidecar/captures.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')

const input = JSON.parse(readFileSync(
    join(ROOT, 'spec/concurrency/scoped-captures-v1/fixtures/canonical.json'), 'utf8'))
const hir = buildScopeHir(input)
const section = projectKse2CaptureSection(hir)

const stripped = section.events.map(({ wire_hex, ...rest }) => rest)

// ------------------------------------------------------- the frozen wire

assert.ok(section.events.length > 0, 'the canonical fixture carries capture events')
for (const [index, event] of section.events.entries()) {
    assert.equal(
        encodeCaptureEvent(event).toString('hex'),
        event.wire_hex,
        `event ${index} (${event.event}) must encode to the frozen bytes`,
    )
}
assert.equal(
    encodeCaptureFrames(section.events).toString('hex'),
    section.capture_frames_hex,
    'the concatenated frames must equal the frozen stream',
)
assert.equal(
    encodeCaptureFrames(section.events).toString('hex'),
    encodeCaptureFrames(section.events).toString('hex'),
    'encoding is deterministic',
)

const decoded = decodeCaptureFrames(section.capture_frames_hex)
assert.deepEqual(decoded, stripped, 'decoding the frozen stream must reproduce its records')
assert.deepEqual(
    projectSidecarCaptures(decoded),
    projectTypedSidecarCaptures(hir).map((capture) => JSON.parse(JSON.stringify(capture))),
    'the projected captures must equal the frozen projection',
)

// A place's structure is parsed back out of its canonical bytes rather than
// carried beside them, so the two cannot disagree.
for (const event of decoded.filter((entry) => entry.event === 'place')) {
    const parsed = decodeCanonicalPlaceBytes(event.canonical_bytes)
    assert.equal(parsed.base_binding_id, event.base_binding_id)
    assert.deepEqual(parsed.projections, event.projections)
}

// ------------------------------------------------- every unknown reason
//
// The canonical fixture exercises two of the three reasons, and a vocabulary
// is only closed if every member of it round-trips. These three events are
// built here rather than derived from the fixture, because which reason the
// analysis assigns is #1220-#1223's decision and not this codec's.

const UNKNOWN_REASONS = ['unresolved-call', 'projection-depth-exceeded', 'unnameable-place']
const REASON_TAG = { 'unresolved-call': 1, 'projection-depth-exceeded': 2, 'unnameable-place': 3 }

function unknownCanonicalBytes(taskId, reason, witnessNodeId) {
    return Buffer.concat([
        Buffer.from([0x4b, 0x55, 0x4e, 0x00, 0x02]),
        Buffer.from(taskId, 'hex'),
        Buffer.from([REASON_TAG[reason]]),
        Buffer.from(witnessNodeId, 'hex'),
    ]).toString('hex')
}

const sampleTask = decoded.find((event) => event.event === 'task')
for (const [index, reason] of UNKNOWN_REASONS.entries()) {
    const unknownId = String(0xa0 + index).padStart(2, '0').slice(-2).repeat(32)
    const witness = String(0xb0 + index).padStart(2, '0').slice(-2).repeat(32)
    const event = {
        canonical_bytes: unknownCanonicalBytes(sampleTask.task_id, reason, witness),
        event: 'unknown',
        kind: 12,
        reason,
        task_id: sampleTask.task_id,
        unknown_id: unknownId,
        witness_node_id: witness,
    }
    const [roundTripped] = decodeCaptureFrames(encodeCaptureEvent(event).toString('hex'))
    assert.deepEqual(roundTripped, event, `the ${reason} reason must round-trip exactly`)
}

// ------------------------------------------------------------- refusals

const stream = Buffer.from(section.capture_frames_hex, 'hex')

function refuses(name, mutate) {
    const bytes = Buffer.from(stream)
    const candidate = mutate(bytes)
    assert.throws(
        () => decodeCaptureFrames(candidate === undefined ? bytes : candidate),
        CaptureCodecError,
        `a stream with ${name} must be refused`,
    )
}

refuses('a truncated final frame', (bytes) => bytes.subarray(0, bytes.length - 1))
refuses('one byte removed from the middle', (bytes) =>
    Buffer.concat([bytes.subarray(0, 40), bytes.subarray(41)]))
refuses('an unknown event kind', (bytes) => { bytes[0] = 200 })
refuses('a nonzero reserved byte', (bytes) => { bytes[1] = 1 })
refuses('a frame length past the stream', (bytes) => { bytes.writeUInt32BE(0xffff, 4) })
refuses('a field count that disagrees with the payload', (bytes) => { bytes.writeUInt16BE(99, 2) })
refuses('an odd-length hex stream', () => section.capture_frames_hex.slice(0, -1))

// Field-level corruption inside the first frame's first field.
refuses('a field length past its frame', (bytes) => { bytes.writeUInt32BE(0xffff, 12) })
refuses('a field wire type the tag does not carry', (bytes) => { bytes[9] = 5 })

// Value-level corruption: every closed vocabulary is refused rather than
// silently mapped to a default.
const captureOffset = (() => {
    let offset = 0
    for (const event of section.events) {
        if (event.event === 'capture') return offset
        offset += Buffer.from(event.wire_hex, 'hex').length
    }
    throw new Error('no capture frame in the fixture')
})()

// The capture frame is [kind, 0, u16 count, u32 length] then fields; the mode
// byte is the payload of the fifth field, and the fields before it are two
// identities and a one-byte target kind.
const captureModeOffset = captureOffset + 8 +
    (8 + 32) + (8 + 32) + (8 + 1) + (8 + 32) + 8
refuses('an unknown capture mode', (bytes) => { bytes[captureModeOffset] = 9 })

const captureTargetKindOffset = captureOffset + 8 + (8 + 32) + (8 + 32) + 8
refuses('an unknown capture target kind', (bytes) => { bytes[captureTargetKindOffset] = 7 })

// ------------------------------------------------------- link invariants

function withEvents(mutate) {
    const events = JSON.parse(JSON.stringify(stripped))
    mutate(events)
    return events
}

function refusesStream(name, mutate) {
    assert.throws(
        () => validateCaptureStream(withEvents(mutate)),
        CaptureCodecError,
        `${name} must be refused`,
    )
}

refusesStream('a duplicate place identity', (events) => {
    const place = events.find((event) => event.event === 'place')
    events.push({ ...place })
})
refusesStream('a capture naming an undeclared task', (events) => {
    const capture = events.find((event) => event.event === 'capture')
    capture.task_id = 'ff'.repeat(32)
})
refusesStream('a capture naming an undeclared target', (events) => {
    const capture = events.find((event) => event.event === 'capture')
    capture.target_id = 'ee'.repeat(32)
})
refusesStream('an unknown target carrying two origins', (events) => {
    const capture = events.find(
        (event) => event.event === 'capture' && event.target_kind === 'unknown')
    if (capture === undefined) throw new Error('fixture has no unknown-target capture')
    capture.origin_node_ids = [...capture.origin_node_ids, 'dd'.repeat(32)]
})

// Encoding refuses the same shapes rather than producing bytes a reader would
// then have to refuse.
assert.throws(() => encodeCaptureEvent({ ...stripped.find((event) => event.event === 'capture'), mode: 'borrow' }),
    CaptureCodecError, 'an unknown mode must not encode')
assert.throws(() => encodeCaptureEvent({ ...stripped.find((event) => event.event === 'unknown'), reason: 'because' }),
    CaptureCodecError, 'an unknown reason must not encode')
assert.throws(() => encodeCaptureFrames(new Array(KSE2_LIMITS.capture_events + 1).fill(
    stripped.find((event) => event.event === 'capture'))),
    CaptureCodecError, 'exceeding the event limit must not encode')

// -------------------------------------------------------- place bytes

assert.throws(() => decodeCanonicalPlaceBytes('00'.repeat(40)), CaptureCodecError,
    'place bytes without the KPL header are refused')
const goodPlace = decoded.find((event) => event.event === 'place').canonical_bytes
assert.throws(() => decodeCanonicalPlaceBytes(goodPlace + 'ff'), CaptureCodecError,
    'place bytes with trailing input are refused')

// ------------------------------------------------------ the v2 document
//
// The v1 base is a tracked example with its file identity replaced by the
// fixture's, because a sidecar and the scope-HIR it carries captures for must
// name the same file — that rule is the one being exercised, so the test
// satisfies it rather than working around it.

const v1Document = JSON.parse(readFileSync(
    join(ROOT, 'spec/typed-sidecar/examples/complete.json'), 'utf8'))
v1Document.file.file_id = hir.file_id

const v2 = projectSidecarV2(v1Document, decoded)
const frozenV2 = JSON.parse(JSON.stringify(projectTypedSidecarV2(v1Document, hir)))
assert.deepEqual(v2, frozenV2, 'the projected v2 document must equal the frozen projection')
assert.equal(v2.schema, 'kofun.typed-sidecar/v2')
assert.equal(v2.authoritative, false, 'the v2 document stays non-authoritative')
assert.equal(v2.limits.profile, 'default-v2')

// v1 stays exactly what it was: the base document this projection was built
// from is unchanged, field for field.
const v1Again = JSON.parse(readFileSync(
    join(ROOT, 'spec/typed-sidecar/examples/complete.json'), 'utf8'))
v1Again.file.file_id = hir.file_id
assert.deepEqual(v1Document, v1Again, 'projecting v2 must not mutate its v1 input')

assert.throws(
    () => projectSidecarV2({ ...v1Document, authoritative: true }, decoded),
    CaptureCodecError,
    'an authoritative base document is refused',
)
assert.throws(
    () => projectSidecarV2({ ...v1Document, schema: 'kofun.typed-sidecar/v2' }, decoded),
    CaptureCodecError,
    'a base document that is already v2 is refused',
)

process.stdout.write(
    'PASS: production KSE2 capture frames equal the frozen wire and round-trip exactly\n' +
    'PASS: the projected captures and v2 document equal the frozen projection\n' +
    'PASS: truncation, corruption, closed vocabularies, and broken links are refused\n',
)

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
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
    buildScopeHir,
    projectKse2CaptureSection,
    projectTypedSidecarCaptures,
    projectTypedSidecarV2,
    validateScopeHir,
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
import {
    canReplaceTypedSidecar,
    canonicalTypedSidecarBytes,
    encodeTypedSidecar,
    readTypedSidecar,
    writeTypedSidecarAtomic,
} from '../../tooling/typed-sidecar/codec.mjs'

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

// --------------------------------------------------- section identities
//
// This independently assembled frame checks the production hash's domain,
// lengths, raw ID bytes and prefix. The frozen model supplies the positive
// record values, but neither it nor production supplies this test's encoder.
function derived(name, payload) {
    const domain = Buffer.from(`kofun.scope-hir.${name}/v2`)
    const bytes = Buffer.alloc(6 + 2 + domain.length + 4 + payload.length)
    Buffer.from([0x4b, 0x4f, 0x46, 0x55, 0x4e, 0]).copy(bytes)
    bytes.writeUInt16BE(domain.length, 6)
    domain.copy(bytes, 8)
    bytes.writeUInt32BE(payload.length, 8 + domain.length)
    payload.copy(bytes, 12 + domain.length)
    return createHash('sha256').update(bytes).digest('hex')
}

const rawId = (id) => Buffer.from(id, 'hex')
const indexBytes = (value) => { const bytes = Buffer.alloc(4); bytes.writeUInt32BE(value); return bytes }
const captureIdentity = (event) => derived('capture', Buffer.concat([
    rawId(event.task_id), Buffer.from([event.target_kind === 'place' ? 1 : 2]), rawId(event.target_id),
]))
const unknownIdentity = (event) => derived('unknown', Buffer.concat([
    rawId(event.task_id), Buffer.from([REASON_TAG[event.reason]]), rawId(event.witness_node_id),
]))
const identityField = { par: 'par_id', task: 'task_id', join: 'join_id', place: 'place_id', unknown: 'unknown_id', capture: 'capture_id' }
const flipId = (id) => (id[0] === 'e' ? 'd' : 'e') + id.slice(1)

// Mutation fixtures preserve the frozen section order whenever order is not
// the invariant under test. This is test construction, not reader repair.
function canonicalSection(events) {
    const compare = (left, right) => left < right ? -1 : left > right ? 1 : 0
    const pars = events.filter((event) => event.event === 'par').sort((a, b) => a.lexical_index - b.lexical_index)
    const parOrder = new Map(pars.map((event, index) => [event.par_id, index]))
    const tasks = events.filter((event) => event.event === 'task').sort((a, b) =>
        parOrder.get(a.par_id) - parOrder.get(b.par_id) || a.lexical_index - b.lexical_index)
    const taskOrder = new Map(tasks.map((event, index) => [event.task_id, index]))
    const targets = new Map(events.filter((event) => event.event === 'place' || event.event === 'unknown')
        .map((event) => [event[identityField[event.event]], event.canonical_bytes]))
    const modes = { read: 1, edit: 2, take: 3 }
    events.sort((a, b) => a.kind - b.kind || (
        a.event === 'par' ? a.lexical_index - b.lexical_index :
        a.event === 'task' ? parOrder.get(a.par_id) - parOrder.get(b.par_id) || a.lexical_index - b.lexical_index :
        a.event === 'join' ? taskOrder.get(a.task_id) - taskOrder.get(b.task_id) :
        a.event === 'place' || a.event === 'unknown' ? compare(a.canonical_bytes, b.canonical_bytes) :
        taskOrder.get(a.task_id) - taskOrder.get(b.task_id) || compare(targets.get(a.target_id), targets.get(b.target_id)) || modes[a.mode] - modes[b.mode]))
    return events
}

function sectionHir(events) {
    const display = { disclosure: 'hidden', text: null }
    const spans = new Map(hir.records.filter((record) => record.record === 'capture')
        .flatMap((capture) => capture.origins.map((origin) => [origin.node_id, origin.span])))
    let nextSpan = 100000
    return { ...hir, records: events.map((event) => {
        const { event: record, kind, ...fields } = structuredClone(event)
        const value = { ...fields, record, id: event[identityField[record]] }
        delete value[identityField[record]]
        if (record === 'par' || record === 'task' || record === 'place') value.display = display
        if (record === 'place') value.projections = value.projections.map((projection) =>
            projection.kind === 'field' ? { ...projection, display } : projection)
        if (record === 'capture') {
            value.origins = value.origin_node_ids.map((node_id) => {
                if (!spans.has(node_id)) { spans.set(node_id, { start: nextSpan, end: nextSpan + 1 }); nextSpan += 2 }
                return { node_id, span: spans.get(node_id) }
            })
            delete value.origin_node_ids
        }
        return value
    }) }
}

function eventIdentity(event) {
    let payload
    if (event.event === 'par') payload = Buffer.concat([rawId(hir.file_id), rawId(event.scope_id), rawId(event.node_id)])
    if (event.event === 'task') payload = Buffer.concat([
        rawId(event.par_id), indexBytes(event.lexical_index), rawId(event.spawn_node_id),
        rawId(event.lambda_node_id), rawId(event.handle_binding_id),
    ])
    if (event.event === 'join') payload = Buffer.concat([
        rawId(event.task_id), Buffer.from([event.join_kind === 'explicit' ? 1 : 2]),
        event.node_id === null ? Buffer.alloc(0) : rawId(event.node_id),
    ])
    if (event.event === 'place') payload = Buffer.from(event.canonical_bytes, 'hex')
    if (event.event === 'unknown') payload = Buffer.concat([
        rawId(event.task_id), Buffer.from([REASON_TAG[event.reason]]), rawId(event.witness_node_id),
    ])
    if (event.event === 'capture') payload = Buffer.concat([
        rawId(event.task_id), Buffer.from([event.target_kind === 'place' ? 1 : 2]), rawId(event.target_id),
    ])
    return derived(event.event, payload)
}

for (const event of decoded) {
    assert.equal(eventIdentity(event), event[identityField[event.event]],
        `${event.event} identity agrees with independent raw-byte framing`)
}

function refusesSection(name, mutate, message, wire = true) {
    const candidate = withEvents(mutate)
    const check = (error) => error instanceof CaptureCodecError && message.test(error.message)
    assert.throws(() => validateCaptureStream(candidate), check, name)
    assert.throws(() => projectSidecarCaptures(candidate), check, `${name}: capture projection`)
    assert.throws(() => projectSidecarV2(v1Document, candidate), check, `${name}: document projection`)
    // Semantically wrong but structurally valid frames remain usable by raw
    // codecs. A caller must cross the section validator after decoding.
    if (wire) {
        const reread = decodeCaptureFrames(encodeCaptureFrames(candidate))
        assert.throws(() => validateCaptureStream(reread), check, `${name}: after raw round trip`)
    }
}

for (const kind of ['task', 'join', 'place', 'unknown', 'capture']) {
    refusesSection(`${kind} ID preimage mismatch`, (events) => {
        const event = events.find((entry) => entry.event === kind)
        event[identityField[kind]] = flipId(event[identityField[kind]])
    }, new RegExp(`${kind} identity preimage mismatch`))
}

refusesSection('unknown origin must equal its witness, not merely have length one', (events) => {
    const capture = events.find((event) => event.event === 'capture' && event.target_kind === 'unknown')
    capture.origin_node_ids = [events.find((event) => event.event === 'capture' && event.target_kind === 'place').origin_node_ids[0]]
}, /exactly its witness/)

refusesSection('unknown cannot be captured by another declared task', (events) => {
    const capture = events.find((event) => event.event === 'capture' && event.target_kind === 'unknown')
    capture.task_id = events.find((event) => event.event === 'task' && event.task_id !== capture.task_id).task_id
    // Keep CaptureId correct so only the cross-task link is invalid.
    capture.capture_id = captureIdentity(capture)
}, /belongs to another task/)

refusesSection('KUN bytes must match the unknown fields', (events) => {
    const unknown = events.find((event) => event.event === 'unknown')
    unknown.canonical_bytes = unknownCanonicalBytes(unknown.task_id, unknown.reason, flipId(unknown.witness_node_id))
}, /unknown bytes do not match/)
refusesSection('UnknownId excludes the KUN prefix', (events) => {
    const unknown = events.find((event) => event.event === 'unknown')
    unknown.unknown_id = derived('unknown', Buffer.from(unknown.canonical_bytes, 'hex'))
}, /unknown identity preimage mismatch/)
refusesSection('KPL base must equal the separately supplied base', (events) => {
    events.find((event) => event.event === 'place').base_binding_id = 'fe'.repeat(32)
}, /place bytes do not match/, false)
refusesSection('KPL projections cannot disagree with the supplied projections', (events) => {
    const place = events.find((event) => event.event === 'place')
    place.projections = []
}, /place bytes do not match/, false)
refusesSection('extra projection metadata is not silently stripped', (events) => {
    events.find((event) => event.event === 'place').projections[0].display = { text: 'private' }
}, /place bytes do not match/, false)

// Every directly exposed section ID has the same nonzero rule. Updating an
// identity alone must fail that rule before a later preimage or link check.
const idFields = {
    par: ['par_id', 'node_id', 'scope_id', 'parent_scope_id', 'scope_token_binding_id'],
    task: ['task_id', 'par_id', 'spawn_node_id', 'lambda_node_id', 'handle_binding_id'],
    join: ['join_id', 'task_id', 'node_id'],
    place: ['place_id', 'base_binding_id'],
    unknown: ['unknown_id', 'task_id', 'witness_node_id'],
    capture: ['capture_id', 'task_id', 'target_id'],
}
for (const [kind, names] of Object.entries(idFields)) {
    for (const name of names) {
        refusesSection(`nonzero ${kind}.${name}`, (events) => {
            const event = events.find((entry) => entry.event === kind && (name !== 'node_id' || entry.node_id !== null))
            assert.ok(event, `${kind}.${name} fixture exists`)
            event[name] = '00'.repeat(32)
            if (kind === 'place' && name === 'base_binding_id') {
                const canonical = Buffer.from(event.canonical_bytes, 'hex')
                canonical.fill(0, 5, 37)
                event.canonical_bytes = canonical.toString('hex')
            }
        }, /must be nonzero/)
    }
}
refusesSection('nonzero capture origin', (events) => {
    events.find((event) => event.event === 'capture').origin_node_ids[0] = '00'.repeat(32)
}, /must be nonzero/)

// The canonical-place parser stays a structural codec. Section validation
// rejects semantically invalid bounds/depth/IDs even when the digest agrees.
function replacePlace(events, canonical) {
    const place = events.find((event) => event.event === 'place')
    const before = place.place_id
    const parsed = decodeCanonicalPlaceBytes(canonical)
    Object.assign(place, parsed, { canonical_bytes: canonical, place_id: derived('place', Buffer.from(canonical, 'hex')) })
    for (const capture of events.filter((event) => event.event === 'capture' && event.target_id === before)) {
        capture.target_id = place.place_id
        capture.capture_id = captureIdentity(capture)
    }
}
const baseId = decoded.find((event) => event.event === 'place').base_binding_id
const ownerId = 'ab'.repeat(32)
const fieldBytes = Buffer.concat([Buffer.from([1]), rawId(ownerId), indexBytes(0)])
const kpl = (projections) => Buffer.concat([
    Buffer.from([0x4b, 0x50, 0x4c, 0, 2]), rawId(baseId), Buffer.from([projections.length]), ...projections,
]).toString('hex')
const constantBound = (value) => { const bytes = Buffer.alloc(9); bytes[0] = 1; bytes.writeBigInt64BE(BigInt(value), 1); return bytes }
refusesSection('depth nine is not a known place even with a correct hash', (events) => {
    replacePlace(events, kpl(Array(9).fill(fieldBytes)))
}, /exceeds eight projections/)
refusesSection('inverted constant range with a correct hash', (events) => {
    replacePlace(events, kpl([Buffer.concat([Buffer.from([2]), constantBound(5), constantBound(4)])]))
}, /inverted bounds/)
refusesSection('nonzero field owner in canonical bytes', (events) => {
    replacePlace(events, kpl([Buffer.concat([Buffer.from([1]), Buffer.alloc(32), indexBytes(0)])]))
}, /must be nonzero/)
refusesSection('nonzero dynamic bound in canonical bytes', (events) => {
    replacePlace(events, kpl([Buffer.concat([Buffer.from([2, 2]), Buffer.alloc(32), constantBound(4)])]))
}, /must be nonzero/)
for (const bounds of [[4, 4], ['-9223372036854775808', '9223372036854775807']]) {
    const candidate = withEvents((events) => replacePlace(events, kpl([
        Buffer.concat([Buffer.from([2]), constantBound(bounds[0]), constantBound(bounds[1])]),
    ])))
    canonicalSection(candidate)
    assert.equal(validateScopeHir(sectionHir(candidate)), true, 'replaced slice fixture obeys the frozen complete-section contract')
    assert.doesNotThrow(() => validateCaptureStream(candidate), 'empty and i64-extreme slices remain valid')
}

// Each reason can be a fully linked synthetic section, not just a raw frame.
for (const reason of UNKNOWN_REASONS) {
    const candidate = withEvents((events) => {
        const unknown = events.find((event) => event.event === 'unknown')
        const before = unknown.unknown_id
        unknown.reason = reason
        unknown.canonical_bytes = unknownCanonicalBytes(unknown.task_id, reason, unknown.witness_node_id)
        unknown.unknown_id = unknownIdentity(unknown)
        for (const capture of events.filter((event) => event.event === 'capture' && event.target_id === before)) {
            capture.target_id = unknown.unknown_id
            capture.capture_id = captureIdentity(capture)
        }
    })
    canonicalSection(candidate)
    assert.equal(validateScopeHir(sectionHir(candidate)), true, `${reason}: normalized fixture matches the frozen contract`)
    assert.doesNotThrow(() => projectSidecarV2(v1Document, candidate), `${reason}: consistent synthetic section`)
}

const foreignFile = JSON.parse(JSON.stringify(v1Document))
foreignFile.file.file_id = flipId(hir.file_id)
assert.throws(() => projectSidecarV2(foreignFile, decoded),
    (error) => error instanceof CaptureCodecError && /par identity preimage mismatch/.test(error.message),
    'nonempty capture section must be bound to the base FileId')
const badPar = withEvents((events) => {
    // Section-only validation has no FileId, but the document projector does.
    events.find((event) => event.event === 'par').node_id = 'ef'.repeat(32)
})
assert.doesNotThrow(() => validateCaptureStream(badPar), 'section-only validation does not claim a FileId')
assert.throws(() => projectSidecarV2(v1Document, badPar),
    (error) => error instanceof CaptureCodecError && /par identity preimage mismatch/.test(error.message),
    'projector checks ParId against the supplied base file')

// No source snapshot, node table, prefix status or root-scope context is
// supplied by these APIs. Empty events carry no FileId and prove no provenance.
assert.deepEqual(projectSidecarV2(foreignFile, []).captures, [],
    'empty projection is valid without advertising a capture FileId proof')
assert.doesNotThrow(() => validateCaptureStream(decoded),
    'opaque source IDs need no invented source parser or node-table fixture')

// -------------------------------------------------- complete sections
//
// These fixtures independently allocate opaque upstream IDs and construct all
// derived IDs using the test's framed hash. No source analysis is simulated.
function completeFixture(taskCounts, capturesPerTask = 0) {
    let nextIdentity = 1000
    const fresh = () => (nextIdentity++).toString(16).padStart(64, '0')
    const events = []
    for (const [lexical_index, taskCount] of taskCounts.entries()) {
        const par = { event: 'par', kind: 8, lexical_index, node_id: fresh(), scope_id: fresh(),
            parent_scope_id: hir.root_scope_id, scope_token_binding_id: fresh() }
        par.par_id = eventIdentity(par)
        events.push(par)
        for (let index = 0; index < taskCount; index += 1) {
            const task = { event: 'task', kind: 9, lexical_index: index, par_id: par.par_id,
                spawn_node_id: fresh(), lambda_node_id: fresh(), handle_binding_id: fresh() }
            task.task_id = eventIdentity(task)
            const join = { event: 'join', kind: 10, task_id: task.task_id, join_kind: 'scope-exit', node_id: null }
            join.join_id = eventIdentity(join)
            events.push(task, join)
            for (let index = 0; index < capturesPerTask; index += 1) {
                const base = fresh()
                const place = { event: 'place', kind: 11, base_binding_id: base, projections: [],
                    canonical_bytes: Buffer.concat([Buffer.from([0x4b, 0x50, 0x4c, 0, 2]), rawId(base), Buffer.from([0])]).toString('hex') }
                place.place_id = eventIdentity(place)
                const capture = { event: 'capture', kind: 13, task_id: task.task_id,
                    target_kind: 'place', target_id: place.place_id, mode: 'read', origin_node_ids: [fresh()] }
                capture.capture_id = eventIdentity(capture)
                events.push(place, capture)
            }
        }
    }
    return canonicalSection(events)
}

function assertSectionIds(events, name) {
    for (const event of events) {
        assert.equal(event[identityField[event.event]], eventIdentity(event), `${name}: coherent ${event.event} ID`)
    }
}

function refusesComplete(name, events, normativeMessage, productionMessage) {
    assertSectionIds(events, name)
    assert.throws(() => validateScopeHir(sectionHir(events)), normativeMessage, `${name}: frozen oracle refuses`)
    const check = (error) => error instanceof CaptureCodecError && productionMessage.test(error.message)
    assert.throws(() => validateCaptureStream(events), check, name)
    assert.throws(() => projectSidecarCaptures(events), check, `${name}: captures`)
    assert.throws(() => projectSidecarV2(v1Document, events), check, `${name}: document`)
    const raw = decodeCaptureFrames(encodeCaptureFrames(events))
    assert.throws(() => validateCaptureStream(raw), check, `${name}: structural round trip still needs validation`)
}

function acceptsComplete(name, events) {
    assertSectionIds(events, name)
    assert.equal(validateScopeHir(sectionHir(events)), true, `${name}: frozen oracle accepts`)
    assert.doesNotThrow(() => validateCaptureStream(events), name)
    assert.doesNotThrow(() => validateCaptureStream(decodeCaptureFrames(encodeCaptureFrames(events))), `${name}: round trip`)
    assert.doesNotThrow(() => projectSidecarV2(v1Document, events), `${name}: document`)
}

function reversePhase(events, kind) {
    const indexes = events.flatMap((event, index) => event.event === kind ? [index] : [])
    const reversed = indexes.map((index) => events[index]).reverse()
    indexes.forEach((index, offset) => { events[index] = reversed[offset] })
    return events
}

const phaseOrder = withEvents((events) => {
    const index = events.findIndex((event) => event.event === 'place')
    const [place] = events.splice(index, 1)
    events.splice(events.findIndex((event) => event.event === 'join'), 0, place)
})
refusesComplete('place before join phase', phaseOrder, /phase order/, /phase order/)
const sparsePars = completeFixture([0])
sparsePars[0].lexical_index = 1 // ParId intentionally does not contain this index.
refusesComplete('non-dense par index', sparsePars, /par order/, /par indexes must be dense/)

const duplicateScopes = completeFixture([0, 0])
duplicateScopes[1].scope_id = duplicateScopes[0].scope_id
duplicateScopes[1].par_id = eventIdentity(duplicateScopes[1])
refusesComplete('distinct ParIds cannot reuse a ScopeId', duplicateScopes,
    /duplicate par scope identity/, /duplicate par scope identity/)
for (const index of [0, 1]) {
    const rootAlias = completeFixture([0, 0])
    rootAlias[index].scope_id = hir.root_scope_id
    rootAlias[index].par_id = eventIdentity(rootAlias[index])
    refusesComplete(`par ${index} scope aliases the external root`, rootAlias,
        /must not alias the root scope/, /must not alias the section root scope/)
}
for (const [name, mutate, message] of [
    ['first par is its own parent', (pars) => { pars[0].parent_scope_id = pars[0].scope_id }, /must not alias/],
    ['later par is its own parent', (pars) => { pars[1].parent_scope_id = pars[1].scope_id }, /parent must be/],
    ['later par names a forward parent', (pars) => { pars[1].parent_scope_id = pars[2].scope_id }, /parent must be/],
    ['later par names a different external root', (pars) => { pars[1].parent_scope_id = 'bc'.repeat(32) }, /parent must be/],
    ['first par names a later par', (pars) => { pars[0].parent_scope_id = pars[1].scope_id }, /must not alias/],
    ['two par scopes form a cycle', (pars) => {
        pars[0].parent_scope_id = pars[1].scope_id
        pars[1].parent_scope_id = pars[0].scope_id
    }, /must not alias/],
]) {
    const parents = completeFixture([0, 0, 0])
    mutate(parents) // Parent links are deliberately not part of ParId.
    refusesComplete(name, parents, /parent link is not closed/, message)
}
const nestedScopes = completeFixture([0, 0, 0, 0])
nestedScopes[1].parent_scope_id = nestedScopes[0].scope_id
nestedScopes[2].parent_scope_id = nestedScopes[1].scope_id
acceptsComplete('nested earlier scopes and a later root sibling', nestedScopes)
nestedScopes[3].parent_scope_id = nestedScopes[0].scope_id
acceptsComplete('a later par can return to a non-immediate earlier parent', nestedScopes)

// The first parent determines the section's possible external root, not its
// actual compiler provenance. A consistently different opaque root remains
// valid when the oracle's explicit root context agrees; production has none.
const opaqueRoot = 'bd'.repeat(32)
const otherRoot = completeFixture([0, 0, 0])
otherRoot.forEach((par) => { par.parent_scope_id = opaqueRoot })
otherRoot[1].parent_scope_id = otherRoot[0].scope_id
assertSectionIds(otherRoot, 'a consistently different opaque root')
assert.equal(validateScopeHir({ ...sectionHir(otherRoot), root_scope_id: opaqueRoot }), true)
assert.doesNotThrow(() => validateCaptureStream(otherRoot))
assert.doesNotThrow(() => projectSidecarCaptures(otherRoot))
assert.doesNotThrow(() => projectSidecarV2(v1Document, otherRoot))
assert.doesNotThrow(() => validateCaptureStream(decodeCaptureFrames(encodeCaptureFrames(otherRoot))))

// A real cross-domain digest collision cannot be manufactured as a coherent
// hash fixture. The section-only reader cannot recompute ParId, so reuse a
// correctly derived PlaceId as that unchecked ParId to isolate its global
// identity registry. The oracle additionally has the FileId and rejects the
// bad ParId itself. Raw frames remain structural in either case.
const crossKindIdentity = completeFixture([0])
const collidingPlace = structuredClone(decoded.find((event) => event.event === 'place'))
assert.equal(collidingPlace.place_id, eventIdentity(collidingPlace))
crossKindIdentity[0].par_id = collidingPlace.place_id
crossKindIdentity.push(collidingPlace)
assert.throws(() => validateScopeHir(sectionHir(crossKindIdentity)), /ParId preimage mismatch/)
const duplicateRecord = (error) => error instanceof CaptureCodecError && /declared twice/.test(error.message)
assert.throws(() => validateCaptureStream(crossKindIdentity), duplicateRecord, 'record IDs are unique across kinds')
assert.throws(() => projectSidecarCaptures(crossKindIdentity), duplicateRecord)
assert.throws(() => projectSidecarV2(v1Document, crossKindIdentity), duplicateRecord)
assert.throws(() => validateCaptureStream(decodeCaptureFrames(encodeCaptureFrames(crossKindIdentity))), duplicateRecord)

const sparseTasks = completeFixture([2])
const sparseTask = sparseTasks.filter((event) => event.event === 'task')[1]
const oldTaskId = sparseTask.task_id
sparseTask.lexical_index = 2
sparseTask.task_id = eventIdentity(sparseTask)
const repairedJoin = sparseTasks.find((event) => event.event === 'join' && event.task_id === oldTaskId)
repairedJoin.task_id = sparseTask.task_id
repairedJoin.join_id = eventIdentity(repairedJoin)
refusesComplete('non-dense per-par task index', sparseTasks, /task indexes.*not dense/, /task indexes must be dense/)

const missingJoin = completeFixture([2])
missingJoin.splice(missingJoin.findLastIndex((event) => event.event === 'join'), 1)
refusesComplete('missing task join', missingJoin, /exactly one join/, /exactly one join/)
const duplicateJoin = completeFixture([1])
const extraJoin = { ...duplicateJoin.find((event) => event.event === 'join'), join_kind: 'explicit', node_id: 'ad'.repeat(32) }
extraJoin.join_id = eventIdentity(extraJoin)
duplicateJoin.push(extraJoin)
refusesComplete('two different correctly derived joins for one task', duplicateJoin, /exactly one join/, /duplicate joins/)

refusesComplete('join order', reversePhase(completeFixture([2]), 'join'), /join order/, /join order/)
refusesComplete('place canonical-byte order', reversePhase(structuredClone(decoded), 'place'), /place order/, /place order/)
refusesComplete('unknown canonical-byte order', reversePhase(structuredClone(decoded), 'unknown'), /unknown order/, /unknown order/)
refusesComplete('capture task/target order', reversePhase(structuredClone(decoded), 'capture'), /capture order/, /capture order/)
// Dense task indexes reset per par; their global order must still follow pars.
refusesComplete('task order across two pars', reversePhase(completeFixture([1, 1]), 'task'), /task order/, /task order/)

for (const [name, tasks, captures, pattern] of [
    ['65 pars', Array(65).fill(0), 0, /par limit exceeded/],
    ['65 tasks across two pars', [33, 32], 0, /task limit exceeded/],
    ['65 captures for one task', [1], 65, /capture limit exceeded/],
]) {
    refusesComplete(name, completeFixture(tasks, captures), pattern, pattern)
}
acceptsComplete('64 empty pars', completeFixture(Array(64).fill(0)))
acceptsComplete('64 total tasks across two pars', completeFixture([32, 32]))
acceptsComplete('64 captures for each of two tasks', completeFixture([2], 64))

// A complete section is required independently of the eventual sidecar's
// partial/cancelled status. The existing cancellation publication test below
// uses a complete valid section; a transaction-aware raw-prefix API is future
// work and must specify which declarations/facts were committed.
const midSection = completeFixture([1]).filter((event) => event.event !== 'join')
refusesComplete('raw mid-section task prefix', midSection, /exactly one join/, /exactly one join/)

// ----------------------------------------------------------- publication
//
// A v2 document publishes through the same codec, the same replacement
// decision, and the same atomic write as v1. That is the point of teaching the
// v1 validator the v2 schema rather than writing a second one: a parallel
// publisher is how the byte limit, the depth bound, and the replay rule come
// to differ between versions without anyone choosing that.

// The tracked v2 schema is a third party to this: neither the production
// projector nor #1219's model wrote it, so the document's shape is joined to
// it rather than only to the two implementations that agree with each other.
const v2Schema = JSON.parse(readFileSync(
    join(ROOT, 'spec/typed-sidecar/kofun.typed-sidecar.v2.schema.json'), 'utf8'))
assert.deepEqual(
    Object.keys(v2).sort(),
    [...v2Schema.required].sort(),
    'the projected document carries exactly the fields the v2 schema requires',
)
assert.equal(v2.schema, v2Schema.properties.schema.const)
assert.equal(v2.capture_profile, v2Schema.properties.capture_profile.const)
assert.equal(v2.limits.profile, v2Schema.properties.limits.properties.profile.const)
assert.ok(
    v2.captures.length <= v2Schema.properties.captures.maxItems,
    'the capture count is within the schema bound',
)

const encoded = encodeTypedSidecar(v2)
assert.equal(encoded.ok, true, `a v2 document must encode: ${JSON.stringify(encoded)}`)
const reread = readTypedSidecar(encoded.bytes)
assert.equal(reread.ok, true, 'a v2 document must read back')
assert.deepEqual(
    JSON.parse(JSON.stringify(reread.document.captures)),
    JSON.parse(JSON.stringify(v2.captures)),
    'the captures survive the round trip',
)
assert.equal(
    Buffer.from(encodeTypedSidecar(v2).bytes).toString('utf8'),
    Buffer.from(encoded.bytes).toString('utf8'),
    'canonical v2 bytes are stable across runs',
)

// v1 encodes to exactly what it did before this slice taught the validator v2,
// pinned against the **tracked example file** rather than against
// `canonicalTypedSidecarBytes` of the same document.
//
// The self-comparison was the first thing written here and it defends nothing:
// the encoder and the canonicaliser live in one module, so a change to
// canonicalisation moves both sides of that equation together and the
// assertion still passes. `spec/typed-sidecar/examples/complete.json` is
// checked in, is already canonical byte for byte, and does not move when this
// codec does.
const trackedExamplePath = join(ROOT, 'spec/typed-sidecar/examples/complete.json')
const trackedExample = readFileSync(trackedExamplePath, 'utf8')
const encodedTracked = encodeTypedSidecar(JSON.parse(trackedExample))
assert.equal(encodedTracked.ok, true, 'the tracked v1 example still encodes')
assert.equal(
    Buffer.from(encodedTracked.bytes).toString('utf8'),
    trackedExample,
    'the tracked v1 example must encode to its own tracked bytes',
)
assert.equal(
    canonicalTypedSidecarBytes(JSON.parse(trackedExample)),
    trackedExample,
    'canonicalisation itself must still produce the tracked bytes',
)

const encodedV1 = encodeTypedSidecar(v1Document)
assert.equal(encodedV1.ok, true, 'a v1 document with a substituted file id still encodes')

const digest = v1Document.file.content_sha256
const newer = JSON.parse(JSON.stringify(v2))
newer.generation.sequence += 1
assert.deepEqual(canReplaceTypedSidecar(v2, newer, digest), { allow: true, reason: 'allow' })

// Replay: the same document, or an older one, is refused rather than written
// again — a publisher that crashed and retried must not move the sidecar
// backwards.
assert.equal(canReplaceTypedSidecar(v2, v2, digest).reason, 'stale-sequence')
const older = JSON.parse(JSON.stringify(v2))
older.generation.sequence = Math.max(0, older.generation.sequence - 1)
assert.equal(canReplaceTypedSidecar(newer, older, digest).reason, 'stale-sequence')

// The source moved under the publisher.
assert.equal(canReplaceTypedSidecar(v2, newer, 'f'.repeat(64)).reason, 'source-mismatch')

// A different file entirely.
const otherFile = JSON.parse(JSON.stringify(newer))
otherFile.file.file_id = 'c'.repeat(64)
assert.equal(canReplaceTypedSidecar(v2, otherFile, digest).reason, 'wrong-file')

// Cancellation: a run that stopped publishes a partial document, and it is a
// valid v2 document rather than a special case.
const cancelled = JSON.parse(JSON.stringify(v2))
cancelled.completeness = 'partial'
cancelled.source_status = 'cancelled'
cancelled.generation.sequence += 2
const encodedCancelled = encodeTypedSidecar(cancelled)
assert.equal(encodedCancelled.ok, true, 'a cancelled v2 document must encode')
assert.deepEqual(canReplaceTypedSidecar(v2, cancelled, digest), { allow: true, reason: 'allow' })

// A v2 document whose captures are malformed never becomes bytes.
for (const [name, mutate] of [
    ['an unknown mode', (doc) => { doc.captures[0].mode = 'borrow' }],
    ['a duplicate capture identity', (doc) => { doc.captures.push({ ...doc.captures[0] }) }],
    ['a target that is neither place nor unknown', (doc) => { doc.captures[0].target = { kind: 'other' } }],
    ['a capture with no origin', (doc) => { doc.captures[0].origin_node_ids = [] }],
    ['the wrong capture profile', (doc) => { doc.capture_profile = 'kofun.stage2-analysis/other/v1' }],
    ['a v1 limits profile', (doc) => { doc.limits.profile = 'default-v1' }],
]) {
    const broken = JSON.parse(JSON.stringify(v2))
    mutate(broken)
    assert.equal(encodeTypedSidecar(broken).ok, false, `${name} must not encode`)
}

// Atomic publication: the bytes on disk are the canonical bytes, and a stale
// replacement leaves them alone.
const work = mkdtempSync(join(tmpdir(), 'kofun-captures-'))
const destination = join(work, 'sidecar.json')
const published = await writeTypedSidecarAtomic(destination, v2, { currentSourceDigest: digest })
assert.equal(published.ok, true, `atomic publication must succeed: ${JSON.stringify(published)}`)
assert.equal(
    readFileSync(destination, 'utf8'),
    canonicalTypedSidecarBytes(v2),
    'the published file is the canonical v2 bytes',
)
const replayed = await writeTypedSidecarAtomic(destination, v2, { currentSourceDigest: digest })
assert.equal(replayed.ok, false, 'republishing the same sequence is refused')
assert.equal(
    readFileSync(destination, 'utf8'),
    canonicalTypedSidecarBytes(v2),
    'a refused replacement leaves the published bytes untouched',
)
const advanced = await writeTypedSidecarAtomic(destination, newer, { currentSourceDigest: digest })
assert.equal(advanced.ok, true, 'a newer sequence publishes')
assert.equal(readFileSync(destination, 'utf8'), canonicalTypedSidecarBytes(newer))
rmSync(work, { recursive: true, force: true })

process.stdout.write(
    'PASS: production KSE2 capture frames equal the frozen wire and round-trip exactly\n' +
    'PASS: the projected captures and v2 document equal the frozen projection\n' +
    'PASS: truncation, corruption, closed vocabularies, and broken links are refused\n' +
    'PASS: complete capture sections enforce identity, order, join and profile bounds\n' +
    'PASS: v2 publishes through the v1 codec, replay and cancellation included, and v1 bytes are unchanged\n',
)

// Full synthetic transactions add the upstream context absent from this section gate.
await import('./capture_transactions_test.mjs')

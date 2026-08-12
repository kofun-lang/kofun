// The production KSE2 capture-event codec and typed-sidecar v2 capture
// projector (#1224).
//
// #1219 froze the wire in `spec/concurrency/scoped-captures-v1/model.mjs`.
// This file does not import it. The frozen model is the contract and the
// oracle; a production reader that shared its code would agree with it by
// construction and prove nothing, so the two are written independently and
// `tests/typed-sidecar/captures_test.mjs` requires them to produce the same
// bytes and the same projection.
//
// The producer here is synthetic by design. Deriving captures from compiler
// analysis is #1220-#1223; this slice reads records that already exist and
// must refuse a malformed stream before anything is published.

const CAPTURE_KIND = Object.freeze({
    par: 8,
    task: 9,
    join: 10,
    place: 11,
    unknown: 12,
    capture: 13,
})

const KIND_EVENT = Object.freeze(Object.fromEntries(
    Object.entries(CAPTURE_KIND).map(([event, kind]) => [kind, event]),
))

// The wire discriminants are part of the frozen contract, not an internal
// choice: a field's declared type is what lets a reader refuse a frame whose
// tag it knows and whose payload it does not.
const WIRE = Object.freeze({ bytes: 1, id: 3, u8: 4, u32: 5, 'id-list': 8 })

export const KSE2_LIMITS = Object.freeze({
    capture_events: 8384,
    event_bytes: 16 * 1024 * 1024,
    events: 16384,
    field_bytes: 16 * 1024,
    relations: 256,
})

const UNKNOWN_REASON_TAG = Object.freeze({
    'unresolved-call': 1,
    'projection-depth-exceeded': 2,
    'unnameable-place': 3,
})

const TAG_UNKNOWN_REASON = Object.freeze(Object.fromEntries(
    Object.entries(UNKNOWN_REASON_TAG).map(([reason, tag]) => [tag, reason]),
))

const MODE_TAG = Object.freeze({ read: 1, edit: 2, take: 3 })
const TAG_MODE = Object.freeze(Object.fromEntries(
    Object.entries(MODE_TAG).map(([mode, tag]) => [tag, mode]),
))

const JOIN_KIND_TAG = Object.freeze({ explicit: 1, 'scope-exit': 2 })
const TAG_JOIN_KIND = Object.freeze(Object.fromEntries(
    Object.entries(JOIN_KIND_TAG).map(([kind, tag]) => [tag, kind]),
))

const ID = /^[0-9a-f]{64}$/

export class CaptureCodecError extends Error {
    constructor(path, message) {
        super(`${path}: ${message}`)
        this.name = 'CaptureCodecError'
        this.path = path
    }
}

function fail(path, message) {
    throw new CaptureCodecError(path, message)
}

function identity(value, path) {
    if (typeof value !== 'string' || !ID.test(value)) {
        fail(path, 'expected 64 lowercase hexadecimal digits')
    }
    return value
}

// ------------------------------------------------------------------ encode

function u16(value) {
    const bytes = Buffer.alloc(2)
    bytes.writeUInt16BE(value)
    return bytes
}

function u32(value) {
    const bytes = Buffer.alloc(4)
    bytes.writeUInt32BE(value)
    return bytes
}

function field(tag, wire, payload) {
    if (payload.length > KSE2_LIMITS.field_bytes) {
        fail('$kse.events', `field exceeds ${KSE2_LIMITS.field_bytes} bytes`)
    }
    return Buffer.concat([Buffer.from([tag, WIRE[wire]]), u16(0), u32(payload.length), payload])
}

function frame(kind, fields) {
    const payload = Buffer.concat(fields)
    return Buffer.concat([Buffer.from([kind, 0]), u16(fields.length), u32(payload.length), payload])
}

function idField(tag, value, path) {
    return field(tag, 'id', Buffer.from(identity(value, path), 'hex'))
}

export function encodeCaptureEvent(event) {
    const kind = CAPTURE_KIND[event.event]
    if (kind === undefined) fail('$kse.events', `unknown event ${event.event}`)
    if (event.kind !== kind) fail('$kse.events.kind', `expected ${kind} for ${event.event}`)

    if (event.event === 'par') {
        return frame(kind, [
            idField(1, event.par_id, '$kse.par.par_id'),
            idField(2, event.node_id, '$kse.par.node_id'),
            idField(3, event.scope_id, '$kse.par.scope_id'),
            idField(4, event.parent_scope_id, '$kse.par.parent_scope_id'),
            idField(5, event.scope_token_binding_id, '$kse.par.scope_token_binding_id'),
            field(6, 'u32', u32(event.lexical_index)),
        ])
    }
    if (event.event === 'task') {
        return frame(kind, [
            idField(1, event.task_id, '$kse.task.task_id'),
            idField(2, event.par_id, '$kse.task.par_id'),
            idField(3, event.spawn_node_id, '$kse.task.spawn_node_id'),
            idField(4, event.lambda_node_id, '$kse.task.lambda_node_id'),
            idField(5, event.handle_binding_id, '$kse.task.handle_binding_id'),
            field(6, 'u32', u32(event.lexical_index)),
        ])
    }
    if (event.event === 'join') {
        const fields = [
            idField(1, event.join_id, '$kse.join.join_id'),
            idField(2, event.task_id, '$kse.join.task_id'),
            field(3, 'u8', Buffer.from([JOIN_KIND_TAG[event.join_kind] ?? 0])),
        ]
        if (JOIN_KIND_TAG[event.join_kind] === undefined) {
            fail('$kse.join.join_kind', 'expected explicit or scope-exit')
        }
        // The node is absent for a scope-exit join, and an absent field is
        // absent from the frame rather than present and zero: a reader that
        // saw a zero identity could not tell it from a real one.
        if (event.node_id !== null && event.node_id !== undefined) {
            fields.push(idField(4, event.node_id, '$kse.join.node_id'))
        }
        return frame(kind, fields)
    }
    if (event.event === 'place') {
        return frame(kind, [
            idField(1, event.place_id, '$kse.place.place_id'),
            idField(2, event.base_binding_id, '$kse.place.base_binding_id'),
            field(3, 'bytes', Buffer.from(event.canonical_bytes, 'hex')),
        ])
    }
    if (event.event === 'unknown') {
        const tag = UNKNOWN_REASON_TAG[event.reason]
        if (tag === undefined) fail('$kse.unknown.reason', `unknown reason ${event.reason}`)
        return frame(kind, [
            idField(1, event.unknown_id, '$kse.unknown.unknown_id'),
            idField(2, event.task_id, '$kse.unknown.task_id'),
            idField(3, event.witness_node_id, '$kse.unknown.witness_node_id'),
            field(4, 'u8', Buffer.from([tag])),
            field(5, 'bytes', Buffer.from(event.canonical_bytes, 'hex')),
        ])
    }

    const mode = MODE_TAG[event.mode]
    if (mode === undefined) fail('$kse.capture.mode', 'expected read, edit, or take')
    if (event.target_kind !== 'place' && event.target_kind !== 'unknown') {
        fail('$kse.capture.target_kind', 'expected place or unknown')
    }
    const origins = event.origin_node_ids
    if (!Array.isArray(origins) || origins.length < 1) {
        fail('$kse.capture.origin_node_ids', 'expected at least one origin')
    }
    if (origins.length > KSE2_LIMITS.relations) {
        fail('$kse.capture.origin_node_ids', `exceeds ${KSE2_LIMITS.relations} origins`)
    }
    return frame(kind, [
        idField(1, event.capture_id, '$kse.capture.capture_id'),
        idField(2, event.task_id, '$kse.capture.task_id'),
        field(3, 'u8', Buffer.from([event.target_kind === 'place' ? 1 : 2])),
        idField(4, event.target_id, '$kse.capture.target_id'),
        field(5, 'u8', Buffer.from([mode])),
        field(6, 'id-list', Buffer.concat(origins.map(
            (origin, index) => Buffer.from(identity(origin, `$kse.capture.origin_node_ids[${index}]`), 'hex'),
        ))),
    ])
}

export function encodeCaptureFrames(events) {
    if (!Array.isArray(events)) fail('$kse.events', 'expected an array of events')
    if (events.length > KSE2_LIMITS.capture_events) {
        fail('$kse.events', `exceeds ${KSE2_LIMITS.capture_events} events`)
    }
    return Buffer.concat(events.map(encodeCaptureEvent))
}

// ------------------------------------------------------------------ decode
//
// The decoder is the half a producer cannot check for itself. Every length in
// the frame is read before it is trusted: a field that claims more bytes than
// the frame holds, a frame that claims more than the stream holds, and a
// trailing byte after the last frame are each refused with the offset that
// carried the claim, because a reader that stops at "malformed" cannot tell a
// truncated stream from a corrupted one.

function readFields(payload, path) {
    const fields = []
    let offset = 0
    while (offset < payload.length) {
        if (offset + 8 > payload.length) {
            fail(path, `field header at byte ${offset} runs past the frame`)
        }
        const tag = payload[offset]
        const wire = payload[offset + 1]
        const length = payload.readUInt32BE(offset + 4)
        if (length > KSE2_LIMITS.field_bytes) {
            fail(path, `field ${tag} exceeds ${KSE2_LIMITS.field_bytes} bytes`)
        }
        if (offset + 8 + length > payload.length) {
            fail(path, `field ${tag} at byte ${offset} claims ${length} bytes past the frame`)
        }
        fields.push({ tag, wire, value: payload.subarray(offset + 8, offset + 8 + length) })
        offset += 8 + length
    }
    return fields
}

function fieldMap(fields, path) {
    const map = new Map()
    for (const entry of fields) {
        if (map.has(entry.tag)) fail(path, `field ${entry.tag} appears twice`)
        map.set(entry.tag, entry)
    }
    return map
}

function requireField(map, tag, wire, path) {
    const entry = map.get(tag)
    if (entry === undefined) fail(path, `field ${tag} is required`)
    if (entry.wire !== WIRE[wire]) {
        fail(path, `field ${tag} is wire ${entry.wire}, expected ${WIRE[wire]}`)
    }
    return entry.value
}

function idFrom(bytes, path) {
    if (bytes.length !== 32) fail(path, `expected a 32-byte identity, got ${bytes.length}`)
    return bytes.toString('hex')
}

export function decodeCaptureFrames(input) {
    const bytes = typeof input === 'string' ? Buffer.from(input, 'hex') : Buffer.from(input)
    if (typeof input === 'string' && input.length !== bytes.length * 2) {
        fail('$kse.capture_frames_hex', 'expected an even-length lowercase hexadecimal string')
    }
    if (bytes.length > KSE2_LIMITS.event_bytes) {
        fail('$kse.capture_frames_hex', `exceeds ${KSE2_LIMITS.event_bytes} bytes`)
    }

    const events = []
    let offset = 0
    while (offset < bytes.length) {
        if (offset + 8 > bytes.length) {
            fail('$kse.capture_frames_hex', `frame header at byte ${offset} runs past the stream`)
        }
        const kind = bytes[offset]
        const reserved = bytes[offset + 1]
        const declared = bytes.readUInt16BE(offset + 2)
        const length = bytes.readUInt32BE(offset + 4)
        const event = KIND_EVENT[kind]
        if (event === undefined) fail('$kse.capture_frames_hex', `unknown event kind ${kind} at byte ${offset}`)
        if (reserved !== 0) fail('$kse.capture_frames_hex', `reserved byte at ${offset + 1} is not zero`)
        if (offset + 8 + length > bytes.length) {
            fail('$kse.capture_frames_hex',
                `frame at byte ${offset} claims ${length} payload bytes past the stream`)
        }
        const path = `$kse.capture_frames_hex[${events.length}]`
        const fields = readFields(bytes.subarray(offset + 8, offset + 8 + length), path)
        if (fields.length !== declared) {
            fail(path, `frame declares ${declared} fields and carries ${fields.length}`)
        }
        events.push(decodeEvent(event, kind, fieldMap(fields, path), path))
        offset += 8 + length
        if (events.length > KSE2_LIMITS.capture_events) {
            fail('$kse.capture_frames_hex', `exceeds ${KSE2_LIMITS.capture_events} events`)
        }
    }
    return events
}

function decodeEvent(event, kind, fields, path) {
    if (event === 'par') {
        return {
            event,
            kind,
            lexical_index: requireField(fields, 6, 'u32', path).readUInt32BE(0),
            node_id: idFrom(requireField(fields, 2, 'id', path), path),
            par_id: idFrom(requireField(fields, 1, 'id', path), path),
            parent_scope_id: idFrom(requireField(fields, 4, 'id', path), path),
            scope_id: idFrom(requireField(fields, 3, 'id', path), path),
            scope_token_binding_id: idFrom(requireField(fields, 5, 'id', path), path),
        }
    }
    if (event === 'task') {
        return {
            event,
            handle_binding_id: idFrom(requireField(fields, 5, 'id', path), path),
            kind,
            lambda_node_id: idFrom(requireField(fields, 4, 'id', path), path),
            lexical_index: requireField(fields, 6, 'u32', path).readUInt32BE(0),
            par_id: idFrom(requireField(fields, 2, 'id', path), path),
            spawn_node_id: idFrom(requireField(fields, 3, 'id', path), path),
            task_id: idFrom(requireField(fields, 1, 'id', path), path),
        }
    }
    if (event === 'join') {
        const joinKindByte = requireField(fields, 3, 'u8', path)
        if (joinKindByte.length !== 1) fail(path, 'join kind must be one byte')
        const joinKind = TAG_JOIN_KIND[joinKindByte[0]]
        if (joinKind === undefined) fail(path, `unknown join kind ${joinKindByte[0]}`)
        const node = fields.get(4)
        if (joinKind === 'scope-exit' && node !== undefined) {
            fail(path, 'a scope-exit join carries no node')
        }
        if (joinKind === 'explicit' && node === undefined) {
            fail(path, 'an explicit join names its node')
        }
        return {
            event,
            join_id: idFrom(requireField(fields, 1, 'id', path), path),
            join_kind: joinKind,
            kind,
            node_id: node === undefined ? null : idFrom(requireField(fields, 4, 'id', path), path),
            task_id: idFrom(requireField(fields, 2, 'id', path), path),
        }
    }
    if (event === 'place') {
        const canonical = requireField(fields, 3, 'bytes', path)
        const base = idFrom(requireField(fields, 2, 'id', path), path)
        const place = decodeCanonicalPlaceBytes(canonical, path)
        if (place.base_binding_id !== base) {
            fail(path, 'the place frame and its canonical bytes name different bindings')
        }
        return {
            base_binding_id: base,
            canonical_bytes: canonical.toString('hex'),
            event,
            kind,
            place_id: idFrom(requireField(fields, 1, 'id', path), path),
            projections: place.projections,
        }
    }
    if (event === 'unknown') {
        const reasonByte = requireField(fields, 4, 'u8', path)
        if (reasonByte.length !== 1) fail(path, 'unknown reason must be one byte')
        const reason = TAG_UNKNOWN_REASON[reasonByte[0]]
        if (reason === undefined) fail(path, `unknown reason tag ${reasonByte[0]}`)
        return {
            canonical_bytes: requireField(fields, 5, 'bytes', path).toString('hex'),
            event,
            kind,
            reason,
            task_id: idFrom(requireField(fields, 2, 'id', path), path),
            unknown_id: idFrom(requireField(fields, 1, 'id', path), path),
            witness_node_id: idFrom(requireField(fields, 3, 'id', path), path),
        }
    }

    const targetByte = requireField(fields, 3, 'u8', path)
    if (targetByte.length !== 1) fail(path, 'target kind must be one byte')
    if (targetByte[0] !== 1 && targetByte[0] !== 2) {
        fail(path, `unknown target kind tag ${targetByte[0]}`)
    }
    const modeByte = requireField(fields, 5, 'u8', path)
    if (modeByte.length !== 1) fail(path, 'mode must be one byte')
    const mode = TAG_MODE[modeByte[0]]
    if (mode === undefined) fail(path, `unknown mode tag ${modeByte[0]}`)
    const originBytes = requireField(fields, 6, 'id-list', path)
    if (originBytes.length === 0 || originBytes.length % 32 !== 0) {
        fail(path, 'origin list must be a nonempty whole number of identities')
    }
    const origins = []
    for (let start = 0; start < originBytes.length; start += 32) {
        origins.push(originBytes.subarray(start, start + 32).toString('hex'))
    }
    if (origins.length > KSE2_LIMITS.relations) {
        fail(path, `exceeds ${KSE2_LIMITS.relations} origins`)
    }
    if (new Set(origins).size !== origins.length) fail(path, 'origins repeat')
    return {
        capture_id: idFrom(requireField(fields, 1, 'id', path), path),
        event,
        kind,
        mode,
        origin_node_ids: origins,
        target_id: idFrom(requireField(fields, 4, 'id', path), path),
        target_kind: targetByte[0] === 1 ? 'place' : 'unknown',
        task_id: idFrom(requireField(fields, 2, 'id', path), path),
    }
}

// ------------------------------------------------------------- place bytes
//
// A place's structure is carried twice: as the canonical bytes a digest is
// taken over, and as the projections a reader displays. The bytes are the
// authority, so the structure is parsed back out of them rather than trusted
// from a parallel field — a producer that disagreed with its own digest would
// otherwise publish both and be believed.

const PLACE_MAGIC = Buffer.from([0x4b, 0x50, 0x4c, 0x00, 0x02])

function bound(bytes, offset, path) {
    if (offset >= bytes.length) fail(path, 'a slice bound runs past the place bytes')
    const tag = bytes[offset]
    if (tag === 1) {
        if (offset + 9 > bytes.length) fail(path, 'a constant bound runs past the place bytes')
        let value = bytes.readBigUInt64BE(offset + 1)
        if (value >= 1n << 63n) value -= 1n << 64n
        return [{ kind: 'constant', value: value.toString() }, offset + 9]
    }
    if (tag === 2) {
        if (offset + 33 > bytes.length) fail(path, 'a node bound runs past the place bytes')
        return [
            { kind: 'node', node_id: bytes.subarray(offset + 1, offset + 33).toString('hex') },
            offset + 33,
        ]
    }
    fail(path, `unknown slice bound tag ${tag}`)
    return [null, offset]
}

export function decodeCanonicalPlaceBytes(input, path = '$place') {
    const bytes = typeof input === 'string' ? Buffer.from(input, 'hex') : Buffer.from(input)
    if (bytes.length < PLACE_MAGIC.length + 33) fail(path, 'place bytes are shorter than a header')
    if (!bytes.subarray(0, PLACE_MAGIC.length).equals(PLACE_MAGIC)) {
        fail(path, 'place bytes do not carry the KPL v2 header')
    }
    const base = bytes.subarray(5, 37).toString('hex')
    const count = bytes[37]
    const projections = []
    let offset = 38
    for (let index = 0; index < count; index += 1) {
        if (offset >= bytes.length) fail(path, `projection ${index} runs past the place bytes`)
        const tag = bytes[offset]
        if (tag === 1) {
            if (offset + 37 > bytes.length) fail(path, `field projection ${index} runs past the place bytes`)
            projections.push({
                kind: 'field',
                ordinal: bytes.readUInt32BE(offset + 33),
                owner_type_id: bytes.subarray(offset + 1, offset + 33).toString('hex'),
            })
            offset += 37
        } else if (tag === 2) {
            const [lower, afterLower] = bound(bytes, offset + 1, path)
            const [upper, afterUpper] = bound(bytes, afterLower, path)
            projections.push({ kind: 'slice', lower, upper })
            offset = afterUpper
        } else {
            fail(path, `unknown projection tag ${tag} at byte ${offset}`)
        }
    }
    if (offset !== bytes.length) {
        fail(path, `place bytes carry ${bytes.length - offset} bytes after ${count} projections`)
    }
    return { base_binding_id: base, projections }
}

// ------------------------------------------------------------------ links
//
// A stream can be individually well-formed and collectively meaningless: a
// capture naming a task no task event declared, two places with one identity,
// an unknown target with two origins. These are the rules that need the whole
// stream, so they run after decoding rather than inside it.

export function validateCaptureStream(events) {
    const declared = new Map()
    for (const [index, event] of events.entries()) {
        const path = `$kse.events[${index}]`
        const id = event.par_id ?? event.task_id_declared ?? null
        if (event.event === 'par') register(declared, 'par', event.par_id, path)
        if (event.event === 'task') {
            register(declared, 'task', event.task_id, path)
            requireDeclared(declared, 'par', event.par_id, path, 'task names a par')
        }
        if (event.event === 'join') {
            register(declared, 'join', event.join_id, path)
            requireDeclared(declared, 'task', event.task_id, path, 'join names a task')
        }
        if (event.event === 'place') register(declared, 'place', event.place_id, path)
        if (event.event === 'unknown') {
            register(declared, 'unknown', event.unknown_id, path)
            requireDeclared(declared, 'task', event.task_id, path, 'unknown names a task')
        }
        if (event.event === 'capture') {
            register(declared, 'capture', event.capture_id, path)
            requireDeclared(declared, 'task', event.task_id, path, 'capture names a task')
            requireDeclared(declared, event.target_kind, event.target_id, path,
                `capture names a ${event.target_kind}`)
            if (event.target_kind === 'unknown' && event.origin_node_ids.length !== 1) {
                fail(path, 'an unknown target carries exactly one origin')
            }
        }
        void id
    }
    return events
}

function register(declared, kind, id, path) {
    const key = `${kind}:${id}`
    if (declared.has(key)) fail(path, `${kind} ${id} is declared twice`)
    declared.set(key, true)
}

function requireDeclared(declared, kind, id, path, what) {
    if (!declared.has(`${kind}:${id}`)) fail(path, `${what} that no ${kind} event declared`)
}

// --------------------------------------------------------------- projection

export const CAPTURE_PROFILE = 'kofun.stage2-analysis/scoped-captures/v1'
export const SIDECAR_V2_SCHEMA = 'kofun.typed-sidecar/v2'

const DISPLAY_KEYS = new Set(['display', 'label', 'name', 'text'])

// The sidecar is a projection for readers, and a capture's display name is the
// one thing it must not carry: a name is source text, and the sidecar is
// explicitly non-authoritative about source. The check walks the projection
// rather than trusting the projector that just built it.
function rejectDisplayLeak(value, path) {
    if (Array.isArray(value)) {
        value.forEach((item, index) => rejectDisplayLeak(item, `${path}[${index}]`))
        return
    }
    if (value === null || typeof value !== 'object') return
    for (const [key, nested] of Object.entries(value)) {
        if (DISPLAY_KEYS.has(key)) fail(`${path}.${key}`, 'a capture projection carries no display name')
        rejectDisplayLeak(nested, `${path}.${key}`)
    }
}

export function projectSidecarV2(v1Document, events) {
    if (v1Document === null || typeof v1Document !== 'object') {
        fail('$typed-v1', 'expected a typed-sidecar v1 document')
    }
    if (v1Document.schema !== 'kofun.typed-sidecar/v1') {
        fail('$typed-v1.schema', 'base document must be typed-sidecar v1')
    }
    if (v1Document.authoritative !== false) {
        fail('$typed-v1.authoritative', 'sidecar must be non-authoritative')
    }
    if (v1Document.limits?.profile !== 'default-v1') {
        fail('$typed-v1.limits.profile', 'base document must use default-v1')
    }
    const captures = projectSidecarCaptures(events)
    rejectDisplayLeak(captures, '$typed-v2.captures')
    const result = JSON.parse(JSON.stringify(v1Document))
    result.capture_profile = CAPTURE_PROFILE
    result.captures = captures
    result.schema = SIDECAR_V2_SCHEMA
    result.limits = { ...result.limits, profile: 'default-v2' }
    return result
}

export function projectSidecarCaptures(events) {
    validateCaptureStream(events)
    const places = new Map()
    const unknowns = new Map()
    for (const event of events) {
        if (event.event === 'place') places.set(event.place_id, event)
        if (event.event === 'unknown') unknowns.set(event.unknown_id, event)
    }
    return events.filter((event) => event.event === 'capture').map((capture) => ({
        id: capture.capture_id,
        mode: capture.mode,
        origin_node_ids: [...capture.origin_node_ids],
        target: capture.target_kind === 'place'
            ? {
                kind: 'place',
                place: {
                    base_binding_id: places.get(capture.target_id).base_binding_id,
                    canonical_bytes: places.get(capture.target_id).canonical_bytes,
                    id: capture.target_id,
                    projections: places.get(capture.target_id).projections,
                },
            }
            : {
                kind: 'unknown',
                unknown: {
                    canonical_bytes: unknowns.get(capture.target_id).canonical_bytes,
                    id: capture.target_id,
                    reason: unknowns.get(capture.target_id).reason,
                    witness_node_id: unknowns.get(capture.target_id).witness_node_id,
                },
            },
        task_id: capture.task_id,
    }))
}

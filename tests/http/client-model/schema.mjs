// The canonical shapes a transport script and a model result may take, and the
// only reader of either.
//
// Schema validation here is not a courtesy pass before the real work — it is
// how the corpus stays a specification. A field this file does not name cannot
// appear, because a field nothing reads is a field that can say anything; a
// value outside its stated domain is refused rather than coerced, because a
// coerced value is a test that passes for a reason the fixture does not state.
//
// Every refusal carries the path it happened at, so a corpus of several hundred
// scripts names the row rather than the file.

export class SchemaError extends Error {
    constructor(path, detail) {
        super(`${path}: ${detail}`)
        this.path = path
        this.detail = detail
    }
}

const fail = (path, detail) => {
    throw new SchemaError(path, detail)
}

const isPlainObject = (value) =>
    typeof value === 'object' && value !== null && !Array.isArray(value)

/*
 * Exactly these keys, no more and no fewer. Optional keys are declared, so a
 * key that is neither required nor optional is a typo or a field from a version
 * this reader does not implement — both of which must stop the run.
 */
const object = (path, value, required, optional = []) => {
    if (!isPlainObject(value)) fail(path, 'must be an object')
    const present = Object.keys(value)
    for (const key of required) {
        if (!Object.hasOwn(value, key)) fail(path, `is missing \`${key}\``)
    }
    const known = new Set([...required, ...optional])
    for (const key of present) {
        if (!known.has(key)) fail(`${path}.${key}`, 'is not a field of this schema')
    }
    return value
}

const string = (path, value) => {
    if (typeof value !== 'string') fail(path, 'must be a string')
    return value
}

const literal = (path, value, expected) => {
    if (string(path, value) !== expected) {
        fail(path, `must be \`${expected}\`, not \`${value}\``)
    }
    return value
}

const boolean = (path, value) => {
    if (typeof value !== 'boolean') fail(path, 'must be true or false')
    return value
}

/*
 * A count is a non-negative safe integer. `Number.isInteger` alone admits
 * `1e21`, which round-trips through JSON as a different number than it compares
 * as, and admits `-0`.
 */
const count = (path, value, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) => {
    if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
        fail(path, 'must be a safe integer')
    }
    if (Object.is(value, -0)) fail(path, 'must not be negative zero')
    if (value < min) fail(path, `must be at least ${min}`)
    if (value > max) fail(path, `must be at most ${max}`)
    return value
}

const array = (path, value, item) => {
    if (!Array.isArray(value)) fail(path, 'must be an array')
    return value.map((entry, index) => item(`${path}[${index}]`, entry))
}

/*
 * Wire bytes are integers in 0..255 and nothing else. The model never sees a
 * string it has to decode, so a script cannot smuggle an encoding decision past
 * it — which is the point of a byte-level oracle.
 */
const bytes = (path, value) => array(path, value, (itemPath, item) =>
    count(itemPath, item, { max: 255 }))

const enumeration = (path, value, allowed) => {
    const found = string(path, value)
    if (!allowed.includes(found)) {
        fail(path, `must be one of ${allowed.map((one) => `\`${one}\``).join(', ')}`)
    }
    return found
}

// ---------------------------------------------------------------------------
// Transport script
// ---------------------------------------------------------------------------

export const SCRIPT_SCHEMA = 'kofun.http-transport-script/v1'
export const RESULT_SCHEMA = 'kofun.http-model-result/v1'

/*
 * The stages a script may interrupt at. They are the model's own phase names,
 * so a script cannot ask for an interruption at a moment the model does not
 * have.
 */
export const PHASES = ['write', 'head', 'body', 'drain']

/*
 * One scripted operation. `deliver` hands the model bytes the peer sent;
 * `close` is a clean end of stream; `fail` is a transport error; `cancel` is
 * the caller withdrawing. The last three carry the phase they happen at, which
 * is checked against where the model actually is rather than assumed.
 */
const operation = (path, value) => {
    const kind = enumeration(`${path}.op`, object(path, value, ['op'], ['bytes', 'at']).op,
        ['deliver', 'close', 'fail', 'cancel'])
    if (kind === 'deliver') {
        object(path, value, ['op', 'bytes'])
        return { op: kind, bytes: bytes(`${path}.bytes`, value.bytes) }
    }
    if (kind === 'close') {
        object(path, value, ['op'])
        return { op: kind }
    }
    object(path, value, ['op', 'at'])
    return { op: kind, at: enumeration(`${path}.at`, value.at, PHASES) }
}

const header = (path, value) => {
    if (!Array.isArray(value) || value.length !== 2) {
        fail(path, 'must be a two-element [name, value] array')
    }
    return [string(`${path}[0]`, value[0]), string(`${path}[1]`, value[1])]
}

/*
 * Every limit is required and finite. The contract this models says every read
 * has a caller-visible limit and there is no infinite default, so a script that
 * omits one is not a script with a default — it is a script that has not said
 * what it is testing.
 */
const limits = (path, value) => {
    object(path, value, [
        'max_header_bytes',
        'max_headers',
        'max_body_bytes',
        'max_chunk_bytes',
    ])
    return {
        max_header_bytes: count(`${path}.max_header_bytes`, value.max_header_bytes, { min: 1 }),
        max_headers: count(`${path}.max_headers`, value.max_headers, { min: 1 }),
        max_body_bytes: count(`${path}.max_body_bytes`, value.max_body_bytes),
        max_chunk_bytes: count(`${path}.max_chunk_bytes`, value.max_chunk_bytes, { min: 1 }),
    }
}

const request = (path, value) => {
    object(path, value, ['method', 'target', 'host'], ['headers', 'body'])
    return {
        method: enumeration(`${path}.method`, value.method, ['GET', 'POST']),
        target: string(`${path}.target`, value.target),
        host: string(`${path}.host`, value.host),
        headers: value.headers === undefined
            ? []
            : array(`${path}.headers`, value.headers, header),
        body: value.body === undefined ? [] : bytes(`${path}.body`, value.body),
    }
}

export const readScript = (value, path = 'script') => {
    object(path, value, ['schema', 'name', 'request', 'limits', 'operations'])
    literal(`${path}.schema`, value.schema, SCRIPT_SCHEMA)
    const name = string(`${path}.name`, value.name)
    if (!/^[a-z0-9][a-z0-9_-]*$/.test(name)) {
        fail(`${path}.name`, 'must be a lowercase identifier')
    }
    const operations = array(`${path}.operations`, value.operations, operation)
    if (operations.length === 0) {
        fail(`${path}.operations`, 'must contain at least one operation')
    }
    /*
     * A terminal operation ends the script, so anything after it is an
     * instruction the model would never reach. Ordering is part of the schema
     * rather than something the model discovers.
     */
    operations.forEach((entry, index) => {
        const terminal = entry.op !== 'deliver'
        if (terminal && index !== operations.length - 1) {
            fail(`${path}.operations[${index}]`,
                `\`${entry.op}\` ends the script, so it must be last`)
        }
    })
    return {
        schema: value.schema,
        name,
        request: request(`${path}.request`, value.request),
        limits: limits(`${path}.limits`, value.limits),
        operations,
    }
}

// ---------------------------------------------------------------------------
// Model result
// ---------------------------------------------------------------------------

export const OUTCOMES = ['complete', 'error', 'cancelled']

export const FRAMINGS = ['none', 'content-length', 'chunked', 'close-delimited']

/*
 * The error kinds this model can reach. They are the contract's taxonomy
 * narrowed to what a scripted transport can produce: no DNS, no TLS, no
 * redirect, no timeout, because none of those exist at this boundary.
 */
export const ERROR_KINDS = [
    'protocol',
    'limit-exceeded',
    'body-truncated',
    'transport',
]

export const readResult = (value, path = 'result') => {
    object(path, value, [
        'schema',
        'name',
        'request_bytes',
        'outcome',
        'framing',
        'reusable',
        'retry_safe',
        'counters',
        'trace',
    ], ['status', 'headers', 'body', 'error'])
    literal(`${path}.schema`, value.schema, RESULT_SCHEMA)
    const outcome = enumeration(`${path}.outcome`, value.outcome, OUTCOMES)
    const parsed = {
        schema: value.schema,
        name: string(`${path}.name`, value.name),
        request_bytes: bytes(`${path}.request_bytes`, value.request_bytes),
        outcome,
        framing: enumeration(`${path}.framing`, value.framing, FRAMINGS),
        reusable: boolean(`${path}.reusable`, value.reusable),
        retry_safe: boolean(`${path}.retry_safe`, value.retry_safe),
        counters: object(`${path}.counters`, value.counters,
            ['header_bytes', 'header_count', 'body_bytes', 'operations']),
        trace: array(`${path}.trace`, value.trace, string),
    }
    for (const key of Object.keys(parsed.counters)) {
        count(`${path}.counters.${key}`, parsed.counters[key])
    }
    /*
     * The optional fields are not optional by outcome. A complete response has
     * a status, headers, and a body; a failed one has an error and none of
     * those. Letting both appear would let a result claim a body it never
     * framed.
     */
    if (outcome === 'complete') {
        object(path, value, [...Object.keys(parsed), 'status', 'headers', 'body'])
        parsed.status = count(`${path}.status`, value.status, { min: 100, max: 599 })
        parsed.headers = array(`${path}.headers`, value.headers, header)
        parsed.body = bytes(`${path}.body`, value.body)
    } else {
        object(path, value, [...Object.keys(parsed), 'error'])
        object(`${path}.error`, value.error, ['kind', 'detail', 'at'])
        parsed.error = {
            kind: enumeration(`${path}.error.kind`, value.error.kind, ERROR_KINDS),
            detail: string(`${path}.error.detail`, value.error.detail),
            at: count(`${path}.error.at`, value.error.at),
        }
    }
    if (outcome !== 'complete' && parsed.reusable) {
        fail(`${path}.reusable`, 'a connection that did not complete is never reusable')
    }
    return parsed
}

/*
 * One canonical serialization, so two results compare as bytes. Keys are
 * emitted in a fixed order rather than insertion order, because insertion order
 * is a property of the code that built the object and not of what it means.
 */
const ORDER = [
    'schema', 'name', 'request_bytes', 'outcome', 'status', 'headers', 'body',
    'error', 'framing', 'reusable', 'retry_safe', 'counters', 'trace',
]

export const canonicalResult = (result) => {
    const ordered = {}
    for (const key of ORDER) {
        if (Object.hasOwn(result, key)) ordered[key] = result[key]
    }
    for (const key of Object.keys(result)) {
        if (!ORDER.includes(key)) {
            fail(`result.${key}`, 'has no place in the canonical order')
        }
    }
    return `${JSON.stringify(ordered, null, 2)}\n`
}

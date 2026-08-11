// The deterministic HTTP/1.1 reference model.
//
//     node tests/http/client-model/model.mjs SCRIPT.json RESULT.json
//
// This is executable specification evidence. It is not a client, it does not
// open anything, and no later Kofun slice may take it as an implementation to
// port — what it owes them is one answer per script that they must match.
//
// Everything it sees is bytes. There is no host HTTP parser here and there must
// not be: a model that borrowed one would agree with that parser's reading of
// an ambiguous message rather than with the contract's, and ambiguity is most
// of what this corpus is about. It consults no clock, no locale, no
// environment, no network, and no randomness.
//
// ## Failing closed
//
// The contract's word is that malformed and smuggling-shaped responses are
// refused, never repaired. That is a rule about what *not* to do, so the model
// has to be read for absences: there is no branch anywhere below that picks a
// framing when two are declared, drops a duplicate `Content-Length`, unfolds an
// obs-fold continuation, or accepts a chunk size it could not read exactly. Each
// of those is a place a lenient parser would keep going and hand back a body
// somebody else framed.
//
// ## Limits
//
// Every counter is checked before the bytes it would count are taken, so a
// limit refusal happens at the boundary rather than after the model has already
// held the excess. `read_all` has no unbounded form.

import { readFileSync, writeFileSync } from 'node:fs'
import { realpathSync } from 'node:fs'
import { argv } from 'node:process'
import {
    RESULT_SCHEMA,
    SchemaError,
    canonicalResult,
    readResult,
    readScript,
} from './schema.mjs'

const CR = 13
const LF = 10
const SP = 32
const HTAB = 9

class ModelFailure extends Error {
    constructor(kind, detail, at) {
        super(detail)
        this.kind = kind
        this.detail = detail
        this.at = at
    }
}

/*
 * A defect in the script rather than in the message it carries.
 *
 * It is deliberately not a `ModelFailure`: those become an `error` result,
 * which says the peer sent something the model refused. A script that asks to
 * cancel at a phase the run never reached is the author being wrong about the
 * run, and recording that as a protocol error would blame the message for the
 * corpus. It leaves as a non-zero exit with no result document.
 */
export class ScriptError extends Error {}

const protocolError = (detail, at) => {
    throw new ModelFailure('protocol', detail, at)
}
const limitError = (detail, at) => {
    throw new ModelFailure('limit-exceeded', detail, at)
}
const truncatedError = (detail, at) => {
    throw new ModelFailure('body-truncated', detail, at)
}

const asciiBytes = (text) => {
    const out = []
    for (const character of text) {
        const code = character.codePointAt(0)
        if (code > 0x7f) {
            protocolError(`request field carries a non-ASCII byte \`${character}\``, 0)
        }
        out.push(code)
    }
    return out
}

/*
 * A token as the grammar admits it, checked rather than assumed. A caller who
 * can put a space or a control byte into a header name can put a whole second
 * message there, which is the request-side half of smuggling.
 */
const TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
const isFieldValue = (value) => {
    for (const character of value) {
        const code = character.codePointAt(0)
        if (code === CR || code === LF || code === 0 || code > 0x7f) return false
        if (code < SP && code !== HTAB) return false
    }
    return value === value.trim()
}

/*
 * Framing is the model's, not the caller's. A request header that would decide
 * how the body is delimited is refused rather than merged with what the model
 * emits, because two sources for one framing decision is the defect this whole
 * corpus is about — on the request side it is just as available.
 */
const RESERVED_REQUEST_HEADERS = new Set([
    'content-length',
    'transfer-encoding',
    'host',
])

const serializeRequest = (request) => {
    const { method, target, host, headers, body } = request
    if (!/^\/[!-~]*$/.test(target)) {
        protocolError('request target must be an origin-form path of visible ASCII', 0)
    }
    if (!/^[!-~]+$/.test(host) || host.includes(',')) {
        protocolError('request host must be one visible-ASCII authority', 0)
    }
    for (const [name, value] of headers) {
        if (!TOKEN.test(name)) {
            protocolError(`request header name \`${name}\` is not a token`, 0)
        }
        if (RESERVED_REQUEST_HEADERS.has(name.toLowerCase())) {
            protocolError(
                `request header \`${name}\` decides framing and is the model's to set`,
                0,
            )
        }
        if (!isFieldValue(value)) {
            protocolError(`request header \`${name}\` has an invalid field value`, 0)
        }
    }
    if (method === 'GET' && body.length !== 0) {
        protocolError('a GET carries no body in this profile', 0)
    }

    const lines = [`${method} ${target} HTTP/1.1`, `Host: ${host}`]
    for (const [name, value] of headers) lines.push(`${name}: ${value}`)
    if (method === 'POST') lines.push(`Content-Length: ${body.length}`)
    const head = asciiBytes(`${lines.join('\r\n')}\r\n\r\n`)
    return method === 'POST' ? head.concat(body) : head
}

/*
 * The delivered stream, read strictly forward. Nothing here ever looks past
 * what has been delivered, so a script that splits a message at any byte
 * boundary reaches the same states in the same order as one that delivers it
 * whole — which is what makes the fragmentation corpus a test of the model
 * rather than of the script.
 */
class Stream {
    constructor() {
        this.bytes = []
        this.cursor = 0
        this.closed = false
    }

    deliver(chunk) {
        if (this.closed) protocolError('bytes arrived after the peer closed', this.cursor)
        for (const byte of chunk) this.bytes.push(byte)
    }

    close() {
        this.closed = true
    }

    get available() {
        return this.bytes.length - this.cursor
    }

    /* One line ending in CRLF. A bare LF is not a line ending here: accepting
     * one is how two parties disagree about where a message stops. */
    takeLine(limit, phase) {
        for (let index = this.cursor; index + 1 < this.bytes.length; index += 1) {
            if (this.bytes[index] !== CR) {
                if (this.bytes[index] === LF) {
                    protocolError('a bare LF ends no line in this profile', index)
                }
                continue
            }
            if (this.bytes[index + 1] !== LF) {
                protocolError('a CR that does not begin CRLF', index)
            }
            const length = index - this.cursor
            if (length + 2 > limit.remaining) {
                limitError(`${limit.name} exceeded by the line at ${this.cursor}`, this.cursor)
            }
            limit.remaining -= length + 2
            const line = this.bytes.slice(this.cursor, index)
            this.cursor = index + 2
            return line
        }
        if (this.closed) {
            truncatedError(`the peer closed inside the ${phase}`, this.cursor)
        }
        return null
    }

    takeExactly(count) {
        if (this.available < count) {
            if (this.closed) {
                truncatedError('the peer closed inside the body', this.cursor)
            }
            return null
        }
        const taken = this.bytes.slice(this.cursor, this.cursor + count)
        this.cursor += count
        return taken
    }
}

const decodeAscii = (line) => {
    let text = ''
    for (const byte of line) {
        if (byte === 0 || byte > 0x7f) {
            protocolError('a control or non-ASCII byte in a header line', 0)
        }
        if (byte < SP && byte !== HTAB) {
            protocolError('a control byte in a header line', 0)
        }
        text += String.fromCharCode(byte)
    }
    return text
}

const parseStatusLine = (line) => {
    const text = decodeAscii(line)
    const match = /^HTTP\/1\.1 ([0-9]{3})(?: ([\t !-~]*))?$/.exec(text)
    if (match === null) {
        protocolError('the status line is not an HTTP/1.1 status line', 0)
    }
    const status = Number(match[1])
    if (status < 100 || status > 599) {
        protocolError(`status ${status} is outside 100..599`, 0)
    }
    return status
}

const parseHeaderLine = (line) => {
    if (line.length > 0 && (line[0] === SP || line[0] === HTAB)) {
        protocolError('obs-fold continuation lines are refused, not unfolded', 0)
    }
    const text = decodeAscii(line)
    const colon = text.indexOf(':')
    if (colon <= 0) protocolError('a header line with no field name', 0)
    const name = text.slice(0, colon)
    if (!TOKEN.test(name)) {
        protocolError(`header name \`${name}\` is not a token`, 0)
    }
    const value = text.slice(colon + 1).replace(/^[ \t]+|[ \t]+$/g, '')
    if (!isFieldValue(value)) {
        protocolError(`header \`${name}\` has an invalid field value`, 0)
    }
    return [name, value]
}

/*
 * Which framing a response declares, refusing every shape where more than one
 * answer is available. This is the whole of the smuggling surface, so it is one
 * function and it has no fallback branch.
 */
const decideFraming = (status, headers, cursor) => {
    const lengths = []
    const encodings = []
    for (const [name, value] of headers) {
        const lower = name.toLowerCase()
        if (lower === 'content-length') lengths.push(value)
        if (lower === 'transfer-encoding') encodings.push(value)
    }
    if (lengths.length > 0 && encodings.length > 0) {
        protocolError(
            'the response declares both Content-Length and Transfer-Encoding',
            cursor,
        )
    }
    if (encodings.length > 1) {
        protocolError('the response declares Transfer-Encoding more than once', cursor)
    }
    if (encodings.length === 1) {
        if (encodings[0].toLowerCase() !== 'chunked') {
            protocolError(
                `Transfer-Encoding \`${encodings[0]}\` is not supported in this profile`,
                cursor,
            )
        }
        return { kind: 'chunked', length: 0 }
    }
    if (lengths.length > 1) {
        /* Even when they agree. Two sources for one length is the shape, and a
         * reader that resolves it has decided which peer to believe. */
        protocolError('the response declares Content-Length more than once', cursor)
    }
    if (lengths.length === 1) {
        if (!/^[0-9]+$/.test(lengths[0])) {
            protocolError(`Content-Length \`${lengths[0]}\` is not a decimal count`, cursor)
        }
        const length = Number(lengths[0])
        if (!Number.isSafeInteger(length)) {
            protocolError('Content-Length exceeds the model\'s exact integer range', cursor)
        }
        return { kind: 'content-length', length }
    }
    /* No declared framing. Informational, no-content, and not-modified carry no
     * body at all; anything else runs to the close, which the profile permits
     * and which is never reusable. */
    if (status < 200 || status === 204 || status === 304) {
        return { kind: 'none', length: 0 }
    }
    return { kind: 'close-delimited', length: 0 }
}

const parseChunkSize = (line, cursor) => {
    const text = decodeAscii(line)
    if (text.includes(';')) {
        protocolError('chunk extensions are refused in this profile', cursor)
    }
    if (!/^[0-9A-Fa-f]{1,15}$/.test(text)) {
        protocolError(`\`${text}\` is not a bounded chunk size`, cursor)
    }
    return Number.parseInt(text, 16)
}

export const runScript = (script) => {
    const trace = []
    const note = (event) => trace.push(event)
    const stream = new Stream()
    const { limits } = script

    const requestBytes = serializeRequest(script.request)
    note(`write:${requestBytes.length}`)

    const headerBudget = { name: 'max_header_bytes', remaining: limits.max_header_bytes }
    const counters = {
        header_bytes: 0,
        header_count: 0,
        body_bytes: 0,
        operations: 0,
    }

    let phase = 'head'
    let status = 0
    let headers = []
    let framing = { kind: 'none', length: 0 }
    let body = []
    let cancelledAt = null
    let transportFailureAt = null
    /* Where the chunked reader is between deliveries. Carried here rather than
     * rediscovered, because rediscovering it is what read the body as a size. */
    let chunkStep = 'size'
    let chunkRemaining = 0

    const advance = () => {
        for (;;) {
            if (phase === 'head') {
                const line = stream.takeLine(headerBudget, 'status line')
                if (line === null) return
                if (status === 0) {
                    status = parseStatusLine(line)
                    note(`status:${status}`)
                    continue
                }
                if (line.length === 0) {
                    counters.header_bytes = limits.max_header_bytes - headerBudget.remaining
                    counters.header_count = headers.length
                    framing = decideFraming(status, headers, stream.cursor)
                    note(`framing:${framing.kind}`)
                    phase = framing.kind === 'none' ? 'done' : 'body'
                    if (phase === 'done') note('body:0')
                    continue
                }
                if (headers.length >= limits.max_headers) {
                    limitError('max_headers exceeded', stream.cursor)
                }
                headers.push(parseHeaderLine(line))
                continue
            }
            if (phase === 'body') {
                if (framing.kind === 'content-length') {
                    if (framing.length > limits.max_body_bytes) {
                        limitError('max_body_bytes exceeded by the declared length', stream.cursor)
                    }
                    const taken = stream.takeExactly(framing.length)
                    if (taken === null) return
                    body = taken
                    counters.body_bytes = body.length
                    note(`body:${body.length}`)
                    phase = 'done'
                    continue
                }
                if (framing.kind === 'close-delimited') {
                    if (!stream.closed) return
                    const taken = stream.bytes.slice(stream.cursor)
                    if (counters.body_bytes + taken.length > limits.max_body_bytes) {
                        limitError('max_body_bytes exceeded before the close', stream.cursor)
                    }
                    stream.cursor += taken.length
                    body = taken
                    counters.body_bytes = body.length
                    note(`body:${body.length}`)
                    phase = 'done'
                    continue
                }
                /*
                 * Chunked, in three resumable steps.
                 *
                 * The size line, the data, and the trailing CRLF each arrive
                 * whenever the peer sends them, so each is its own state. An
                 * earlier version read the data and then the CRLF in one pass:
                 * when the data arrived and the CRLF had not, it had already
                 * consumed the data and returned, and the next delivery re-read
                 * from the top and took the body's own bytes as a size line.
                 * The whole-message and byte-at-a-time runs then disagreed —
                 * which is the property the fragmentation corpus exists to
                 * check, found by it here.
                 *
                 * The rule this restores: no step consumes anything until
                 * everything it needs is present.
                 */
                if (chunkStep === 'size') {
                    const sizeLine = stream.takeLine(
                        { name: 'max_chunk_bytes', remaining: Number.MAX_SAFE_INTEGER },
                        'chunk size',
                    )
                    if (sizeLine === null) return
                    const size = parseChunkSize(sizeLine, stream.cursor)
                    if (size > limits.max_chunk_bytes) {
                        limitError('max_chunk_bytes exceeded by a chunk size', stream.cursor)
                    }
                    if (counters.body_bytes + size > limits.max_body_bytes) {
                        limitError('max_body_bytes exceeded by a chunk', stream.cursor)
                    }
                    if (size === 0) {
                        note(`body:${counters.body_bytes}`)
                        phase = 'trailers'
                        continue
                    }
                    chunkRemaining = size
                    chunkStep = 'data'
                    continue
                }
                if (chunkStep === 'data') {
                    const taken = stream.takeExactly(chunkRemaining)
                    if (taken === null) return
                    for (const byte of taken) body.push(byte)
                    counters.body_bytes = body.length
                    chunkRemaining = 0
                    chunkStep = 'crlf'
                    continue
                }
                const terminator = stream.takeExactly(2)
                if (terminator === null) return
                if (terminator[0] !== CR || terminator[1] !== LF) {
                    protocolError('a chunk is not followed by CRLF', stream.cursor)
                }
                chunkStep = 'size'
                continue
            }
            if (phase === 'trailers') {
                const line = stream.takeLine(headerBudget, 'trailer section')
                if (line === null) return
                if (line.length === 0) {
                    phase = 'done'
                    continue
                }
                if (headers.length >= limits.max_headers) {
                    limitError('max_headers exceeded by a trailer', stream.cursor)
                }
                headers.push(parseHeaderLine(line))
                counters.header_count = headers.length
                continue
            }
            return
        }
    }

    let failure = null
    try {
        for (const operation of script.operations) {
            counters.operations += 1
            if (operation.op === 'deliver') {
                stream.deliver(operation.bytes)
                advance()
                if (phase === 'done') continue
                continue
            }
            if (operation.op === 'close') {
                stream.close()
                advance()
                continue
            }
            /* `fail` and `cancel` name the phase they expect. A script that
             * names one the model is not in is describing a different run, and
             * saying so is more useful than injecting at whatever phase the
             * model happens to have reached. */
            const reached = phase === 'done' ? 'drain' : phase === 'head' ? 'head' : 'body'
            const expected = operation.at === 'write' ? 'write' : operation.at
            if (expected !== 'write' && expected !== reached) {
                throw new ScriptError(
                    `the script injects at \`${operation.at}\` and the model is at \`${reached}\``,
                )
            }
            if (operation.op === 'cancel') {
                cancelledAt = stream.cursor
                note(`cancel:${operation.at}`)
            } else {
                transportFailureAt = stream.cursor
                note(`fail:${operation.at}`)
            }
            break
        }
        if (cancelledAt === null && transportFailureAt === null && phase !== 'done') {
            truncatedError('the script ended before the message did', stream.cursor)
        }
    } catch (error) {
        if (!(error instanceof ModelFailure)) throw error
        failure = error
        note(`error:${error.kind}`)
    }

    const trailing = stream.bytes.length - stream.cursor

    if (cancelledAt !== null && failure === null) {
        return {
            schema: RESULT_SCHEMA,
            name: script.name,
            request_bytes: requestBytes,
            outcome: 'cancelled',
            error: { kind: 'transport', detail: 'the caller cancelled', at: cancelledAt },
            framing: framing.kind,
            reusable: false,
            retry_safe: false,
            counters,
            trace,
        }
    }
    if (transportFailureAt !== null && failure === null) {
        return {
            schema: RESULT_SCHEMA,
            name: script.name,
            request_bytes: requestBytes,
            outcome: 'error',
            error: {
                kind: 'transport',
                detail: 'the transport failed',
                at: transportFailureAt,
            },
            framing: framing.kind,
            /* A transport that failed before any response byte arrived has not
             * been observed to have taken effect, and an idempotent request may
             * be sent again. Anything after that is the caller's policy and not
             * this model's to grant. */
            reusable: false,
            retry_safe: script.request.method === 'GET' && stream.bytes.length === 0,
            counters,
            trace,
        }
    }
    if (failure !== null) {
        return {
            schema: RESULT_SCHEMA,
            name: script.name,
            request_bytes: requestBytes,
            outcome: 'error',
            error: { kind: failure.kind, detail: failure.detail, at: failure.at },
            framing: framing.kind,
            reusable: false,
            retry_safe: false,
            counters,
            trace,
        }
    }

    /*
     * Reusable means the framing completed exactly and the peer sent nothing
     * after it. Trailing bytes are a pipelined message this profile did not ask
     * for, and reusing a connection with unread bytes on it is how the next
     * response gets read as this one's.
     */
    const reusable =
        framing.kind !== 'close-delimited' && trailing === 0 && !stream.closed
    if (trailing > 0) note(`trailing:${trailing}`)
    note('complete')

    return {
        schema: RESULT_SCHEMA,
        name: script.name,
        request_bytes: requestBytes,
        outcome: 'complete',
        status,
        headers,
        body,
        framing: framing.kind,
        reusable,
        retry_safe: false,
        counters,
        trace,
    }
}

const main = (argv) => {
    if (argv.length !== 2) {
        process.stderr.write(
            'usage: node tests/http/client-model/model.mjs SCRIPT.json RESULT.json\n',
        )
        return 2
    }
    const [scriptPath, resultPath] = argv
    let script
    try {
        script = readScript(JSON.parse(readFileSync(scriptPath, 'utf8')))
    } catch (error) {
        const detail = error instanceof SchemaError || error instanceof SyntaxError
            ? error.message
            : String(error)
        process.stderr.write(`FAIL: http model: ${scriptPath}: ${detail}\n`)
        return 1
    }
    let result
    try {
        result = runScript(script)
    } catch (error) {
        const detail = error instanceof ScriptError ? error.message : String(error)
        process.stderr.write(`FAIL: http model: ${script.name}: ${detail}\n`)
        return 1
    }
    /* Read back through the same schema before publishing. A result the reader
     * would refuse is a result this model must not have produced. */
    readResult(result)
    writeFileSync(resultPath, canonicalResult(result))
    return 0
}

/*
 * Only when this file is the command. `fragment.mjs` imports `runScript` to run
 * one script many ways in a single process, and a module that exits on import
 * cannot be imported.
 */
if (realpathSync(argv[1]) === realpathSync(new URL(import.meta.url).pathname)) {
    process.exit(main(argv.slice(2)))
}

// Writes the committed corpus.
//
//     node tests/http/client-model/build-corpus.mjs
//
// The scripts are generated because they are mechanical — a wire message and a
// delivery plan — and they are *committed* because they are the specification a
// later Kofun slice must match. Regenerating must be a no-op on a clean tree,
// and the gate checks exactly that: if this file and the fixtures disagree,
// somebody edited one of them by hand.
//
// The expected results are not written here. They are the model's own output,
// recorded by the gate on first acceptance and compared byte for byte
// afterwards, so this file cannot quietly state an answer the model does not
// give.

import { mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const fixtures = join(here, 'fixtures')

const wire = (text) => Array.from(Buffer.from(text, 'latin1'))

const LIMITS = {
    max_header_bytes: 4096,
    max_headers: 16,
    max_body_bytes: 65536,
    max_chunk_bytes: 4096,
}

const GET = { method: 'GET', target: '/index.html', host: 'example.test', headers: [['Accept', '*/*']] }
const POST = {
    method: 'POST',
    target: '/submit',
    host: 'example.test',
    headers: [['Content-Type', 'application/octet-stream']],
    body: [0, 1, 2, 253, 254, 255],
}

const scripts = []
const script = (name, request, operations, limits = LIMITS) => {
    scripts.push({
        schema: 'kofun.http-transport-script/v1',
        name,
        request,
        limits,
        operations,
    })
}

/* One delivery of the whole message. The fragmentation sweep in the gate
 * re-runs each of these at every byte boundary, so the corpus states the
 * message and the gate states the splitting. */
const whole = (text, extra = []) => [{ op: 'deliver', bytes: wire(text) }, ...extra]

// ---------------------------------------------------------------------------
// Positive: the four framings, and both request shapes
// ---------------------------------------------------------------------------
script('get_no_body', GET,
    whole('HTTP/1.1 204 No Content\r\nX-Trace: 1\r\n\r\n'))
script('get_content_length', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello'))
script('get_content_length_empty', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'))
script('get_chunked', GET,
    whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n'))
script('get_chunked_trailers', GET,
    whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nX-Checksum: 5\r\n\r\n'))
script('get_close_delimited', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello', [{ op: 'close' }]))
script('get_informational_status', GET,
    whole('HTTP/1.1 100 Continue\r\n\r\n'))
script('post_bytes', POST,
    whole('HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok'))
script('post_empty_body', { ...POST, body: [] },
    whole('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'))

/* Reuse is a property of the framing *and* of what follows it. A second
 * message on the wire is not this one's, and a connection with unread bytes is
 * one whose next response would be read as this one's tail. */
script('get_pipelined_trailing', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'))

// ---------------------------------------------------------------------------
// Negative: framing ambiguity and smuggling shapes
// ---------------------------------------------------------------------------
script('reject_both_framings', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello'))
script('reject_duplicate_length_agreeing', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello'))
script('reject_duplicate_length_conflicting', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello'))
script('reject_duplicate_transfer_encoding', GET,
    whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n'))
script('reject_unsupported_transfer_encoding', GET,
    whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n'))
script('reject_negative_length', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n'))
/* Optional whitespace around a field value is not part of the value, so a
 * trailing space leaves a valid length — this pair is here because the first
 * version of the corpus asserted the opposite and the model was right. What is
 * refused is whitespace *inside* the value, which trimming cannot rescue. */
script('length_trailing_whitespace', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5 \r\n\r\nhello'))
script('reject_length_internal_space', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5 6\r\n\r\nhello'))
script('reject_hex_length', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 0x5\r\n\r\nhello'))

// ---------------------------------------------------------------------------
// Negative: line and field grammar
// ---------------------------------------------------------------------------
script('reject_obs_fold', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Note: a\r\n  b\r\n\r\nhello'))
script('reject_bare_lf_status', GET,
    whole('HTTP/1.1 200 OK\nContent-Length: 5\r\n\r\nhello'))
script('reject_bare_cr_in_header', GET,
    whole('HTTP/1.1 200 OK\r\nX-Note: a\rb\r\n\r\n'))
script('reject_space_in_header_name', GET,
    whole('HTTP/1.1 200 OK\r\nX Note: a\r\n\r\n'))
script('reject_empty_header_name', GET,
    whole('HTTP/1.1 200 OK\r\n: a\r\n\r\n'))
script('reject_control_in_header_value', GET,
    whole('HTTP/1.1 200 OK\r\nX-Note: ab\r\n\r\n'))
script('reject_http_10_status', GET,
    whole('HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n'))
script('reject_status_not_three_digits', GET,
    whole('HTTP/1.1 20 OK\r\nContent-Length: 0\r\n\r\n'))
script('reject_garbage_before_status', GET,
    whole('garbage\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'))

// ---------------------------------------------------------------------------
// Negative: chunked grammar
// ---------------------------------------------------------------------------
script('reject_chunk_extension', GET,
    whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;a=b\r\nhello\r\n0\r\n\r\n'))
script('reject_chunk_size_not_hex', GET,
    whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n'))
script('reject_chunk_missing_crlf', GET,
    whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloX0\r\n\r\n'))
script('reject_chunk_trailer_fold', GET,
    whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n X: 1\r\n\r\n'))

// ---------------------------------------------------------------------------
// Negative: truncation
// ---------------------------------------------------------------------------
script('reject_close_inside_status', GET,
    whole('HTTP/1.1 200', [{ op: 'close' }]))
script('reject_close_inside_headers', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n', [{ op: 'close' }]))
script('reject_close_inside_body', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel', [{ op: 'close' }]))
script('reject_close_inside_chunk', GET,
    whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel', [{ op: 'close' }]))
script('reject_script_ends_early', GET,
    whole('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel'))

// ---------------------------------------------------------------------------
// Limits: at the bound, and one past it
//
// Each pair moves exactly one limit, so a refusal names the counter that
// refused rather than whichever one a bigger message happened to reach first.
// ---------------------------------------------------------------------------
const filler = (bytes) => 'x'.repeat(bytes)

/* `max_header_bytes` counts the status line and every header line with its
 * CRLF, so the boundary message is built to land on it exactly. */
const headerBoundary = (total) => {
    const prefix = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Pad: '
    const suffix = '\r\n\r\n'
    return `${prefix}${filler(total - prefix.length - suffix.length)}${suffix}`
}
script('limit_header_bytes_at_bound', GET, whole(headerBoundary(256)),
    { ...LIMITS, max_header_bytes: 256 })
script('limit_header_bytes_over', GET, whole(headerBoundary(257)),
    { ...LIMITS, max_header_bytes: 256 })

const manyHeaders = (count) => {
    let text = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n'
    for (let index = 1; index < count; index += 1) text += `X-N${index}: v\r\n`
    return `${text}\r\n`
}
script('limit_headers_at_bound', GET, whole(manyHeaders(4)),
    { ...LIMITS, max_headers: 4 })
script('limit_headers_over', GET, whole(manyHeaders(5)),
    { ...LIMITS, max_headers: 4 })

script('limit_body_bytes_at_bound', GET,
    whole(`HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n${filler(8)}`),
    { ...LIMITS, max_body_bytes: 8 })
script('limit_body_bytes_over', GET,
    whole(`HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n${filler(9)}`),
    { ...LIMITS, max_body_bytes: 8 })

script('limit_chunk_bytes_at_bound', GET,
    whole(`HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n8\r\n${filler(8)}\r\n0\r\n\r\n`),
    { ...LIMITS, max_chunk_bytes: 8 })
script('limit_chunk_bytes_over', GET,
    whole(`HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n${filler(9)}\r\n0\r\n\r\n`),
    { ...LIMITS, max_chunk_bytes: 8 })

/* A body that crosses `max_body_bytes` only when its chunks are added up. Each
 * chunk is within `max_chunk_bytes`, so a model that checked only the chunk
 * would accept it. */
script('limit_body_bytes_over_across_chunks', GET,
    whole('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n'),
    { ...LIMITS, max_body_bytes: 8, max_chunk_bytes: 8 })

// ---------------------------------------------------------------------------
// Cancellation and transport failure, at every phase the model has
// ---------------------------------------------------------------------------
script('cancel_at_write', GET, [{ op: 'cancel', at: 'write' }])
script('cancel_at_head', GET,
    [{ op: 'deliver', bytes: wire('HTTP/1.1 200 OK\r\n') }, { op: 'cancel', at: 'head' }])
script('cancel_at_body', GET,
    [
        { op: 'deliver', bytes: wire('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel') },
        { op: 'cancel', at: 'body' },
    ])
script('cancel_at_drain', GET,
    [
        { op: 'deliver', bytes: wire('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello') },
        { op: 'cancel', at: 'drain' },
    ])
script('fail_at_write', GET, [{ op: 'fail', at: 'write' }])
script('fail_at_head', GET,
    [{ op: 'deliver', bytes: wire('HTTP/1.1 200 OK\r\n') }, { op: 'fail', at: 'head' }])
script('fail_at_body', GET,
    [
        { op: 'deliver', bytes: wire('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel') },
        { op: 'fail', at: 'body' },
    ])
script('fail_at_write_post', POST, [{ op: 'fail', at: 'write' }])

// ---------------------------------------------------------------------------

const written = new Set()
mkdirSync(fixtures, { recursive: true })
for (const entry of readdirSync(fixtures)) {
    if (entry.endsWith('.script.json')) rmSync(join(fixtures, entry))
}
for (const one of scripts) {
    if (written.has(one.name)) {
        throw new Error(`two scripts are named \`${one.name}\``)
    }
    written.add(one.name)
    writeFileSync(
        join(fixtures, `${one.name}.script.json`),
        `${JSON.stringify(one, null, 2)}\n`,
    )
}
process.stdout.write(`wrote ${written.size} transport scripts\n`)

// #1262. Compare the Kofun response decoder against the #1257 reference model.
// Every expected value is read from the model's own result documents, not
// copied into this file.
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

const [outputPath, rootArgument] = process.argv.slice(2)
assert(outputPath && rootArgument, 'usage: check.mjs OUTPUT ROOT')
const root = rootArgument

const lines = fs.readFileSync(outputPath, 'utf8').trimEnd().split('\n')
const cases = new Map()
const fragments = []
for (let index = 0; index < lines.length; ) {
    const label = lines[index++]
    const result = Number(lines[index++])
    if (result === 0) {
        const status = Number(lines[index++])
        const framing = Number(lines[index++])
        const headerCount = Number(lines[index++])
        const headers = []
        for (let header = 0; header < headerCount; header += 1) {
            const nameLength = Number(lines[index++])
            const name = Buffer.from(lines.slice(index, index + nameLength).map(Number)).toString('latin1')
            index += nameLength
            const valueLength = Number(lines[index++])
            const value = Buffer.from(lines.slice(index, index + valueLength).map(Number)).toString('latin1')
            index += valueLength
            headers.push([name, value])
        }
        const bodyLength = Number(lines[index++])
        const body = lines.slice(index, index + bodyLength).map(Number)
        index += bodyLength
        const headerBytes = Number(lines[index++])
        const bodyBytes = Number(lines[index++])
        const reusable = Number(lines[index++])
        const cursor = Number(lines[index++])
        const entry = { kind: 'complete', status, framing, headers, body, headerBytes, bodyBytes, reusable, cursor }
        if (label === 'fragment') fragments.push(entry)
        else cases.set(label, entry)
    } else {
        const cursor = Number(lines[index++])
        index += 1 // status, unset on an error
        index += 1 // framing, unset on an error
        const retrySafe = Number(lines[index++])
        const reusable = Number(lines[index++])
        const kind = result === 2 ? 'protocol' : result === 3 ? 'limit-exceeded' : 'body-truncated'
        cases.set(label, { kind, at: cursor, retrySafe, reusable })
    }
}

const model = (name) =>
    JSON.parse(fs.readFileSync(path.join(root, 'tests/http/client-model/fixtures', `${name}.result.json`), 'utf8'))

const FRAMING = { none: 1, 'content-length': 2, chunked: 3, 'close-delimited': 4 }

// 1. The four framing plans, byte for byte against the model.
for (const [label, fixture] of [
    ['content-length', 'get_content_length'],
    ['no-body', 'get_no_body'],
    ['chunked', 'get_chunked'],
    ['close-delimited', 'get_close_delimited'],
]) {
    const entry = cases.get(label)
    const expected = model(fixture)
    assert(entry, `${label}: missing`)
    assert.equal(entry.kind, 'complete', `${label}: not complete`)
    assert.equal(entry.status, expected.status, `${label}: status`)
    assert.equal(entry.framing, FRAMING[expected.framing], `${label}: framing`)
    assert.deepEqual(entry.headers, expected.headers, `${label}: headers`)
    assert.deepEqual(entry.body, expected.body, `${label}: body`)
    assert.equal(entry.headerBytes, expected.counters.header_bytes, `${label}: header_bytes`)
    assert.equal(entry.bodyBytes, expected.counters.body_bytes, `${label}: body_bytes`)
    assert.equal(entry.reusable, expected.reusable ? 1 : 0, `${label}: reusable`)
}

// 2. Every refusal carries the model's kind and exact offset.
for (const [label, fixture] of [
    ['both-framings', 'reject_both_framings'],
    ['duplicate-length', 'reject_duplicate_length_conflicting'],
    ['obs-fold', 'reject_obs_fold'],
    ['bare-lf', 'reject_bare_lf_status'],
    ['duplicate-te', 'reject_duplicate_transfer_encoding'],
    ['unsupported-te', 'reject_unsupported_transfer_encoding'],
    ['chunk-extension', 'reject_chunk_extension'],
    ['chunk-not-hex', 'reject_chunk_size_not_hex'],
    ['close-inside-body', 'reject_close_inside_body'],
    ['max-headers', 'limit_headers_over'],
    ['max-header-bytes', 'limit_header_bytes_over'],
    ['max-body-bytes', 'limit_body_bytes_over'],
    ['max-chunk-bytes', 'limit_chunk_bytes_over'],
    ['bad-status', 'reject_status_not_three_digits'],
    ['bad-header-name', 'reject_space_in_header_name'],
]) {
    const entry = cases.get(label)
    const expected = model(fixture).error
    assert(entry, `${label}: missing`)
    assert.equal(entry.kind, expected.kind, `${label}: error kind`)
    assert.equal(entry.at, expected.at, `${label}: error offset`)
    assert.equal(entry.retrySafe, 0, `${label}: retry-safe on an error`)
    assert.equal(entry.reusable, 0, `${label}: reusable on an error`)
}

// 3. Fragmentation converges: every prefix before the full message is
//    incomplete, and exactly one terminal result is printed for the whole
//    message, equal to the whole-message decode.
assert.equal(fragments.length, 1, 'fragmentation printed more than one terminal result')
assert.deepEqual(fragments[0], cases.get('content-length'), 'fragmentation result differs from the whole message')

console.log(`PASS: ${cases.size} response cases agree with the #1257 model; every fragmentation prefix is incomplete until the whole message`)

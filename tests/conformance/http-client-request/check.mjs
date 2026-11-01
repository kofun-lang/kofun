// #1261. Compare the Kofun serializer's output against the #1257 reference
// model. The fixture prints `label`, then either `status`, `length`, and one
// decimal byte per line, or a write outcome and a retry-safety fact.
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const [outputPath, rootArgument] = process.argv.slice(2)
assert(outputPath && rootArgument, 'usage: check.mjs OUTPUT ROOT')
const root = rootArgument

const lines = fs.readFileSync(outputPath, 'utf8').trimEnd().split('\n')
const cases = new Map()
for (let index = 0; index < lines.length; ) {
    const label = lines[index++]
    const first = Number(lines[index++])
    const second = Number(lines[index++])
    if (label.includes('write')) {
        assert(!cases.has(label), `${label}: duplicate case`)
        cases.set(label, { outcome: first, retry_safe: second })
        continue
    }
    const bytes = []
    for (let byte = 0; byte < second; byte += 1) bytes.push(Number(lines[index++]))
    assert(!cases.has(label), `${label}: duplicate case`)
    cases.set(label, { status: first, bytes })
}

const fixtureResult = (name) =>
    JSON.parse(
        fs.readFileSync(
            path.join(root, 'tests/http/client-model/fixtures', `${name}.result.json`),
            'utf8',
        ),
    )

const expectRequest = (label, name) => {
    const entry = cases.get(label)
    assert(entry, `${label}: missing`)
    assert.equal(entry.status, 0, `${label}: refused`)
    assert.deepEqual(entry.bytes, fixtureResult(name).request_bytes, `${label}: request bytes differ`)
}

// 1. Canonical bytes, matched against the #1257 model rather than a copy.
expectRequest('get', 'get_chunked')
expectRequest('post', 'post_bytes')
expectRequest('post-empty', 'post_empty_body')

// 2. Validation happens before the first byte: a refusal leaves the carrier
//    empty, so nothing can reach a transport.
for (const [label, status] of [
    ['bad-name', 2],
    ['reserved', 3],
    ['bad-value', 4],
    ['get-body', 5],
    ['unsupported-method', 1],
    ['too-many-headers', 6],
    ['header-bytes-over', 7],
    ['body-over', 8],
]) {
    const entry = cases.get(label)
    assert(entry, `${label}: missing`)
    assert.equal(entry.status, status, `${label}: wrong refusal status`)
    assert.equal(entry.bytes.length, 0, `${label}: refused request wrote bytes`)
}

// 3. The write phase. Every short-write boundary converges, and the injected
//    outcomes are the model's own `outcome`/`retry_safe` for the same phase.
const writeCase = (label, expected) => {
    const entry = cases.get(label)
    assert(entry, `${label}: missing`)
    assert.deepEqual(entry, expected, `${label}: write outcome differs`)
}
writeCase('write-one', { outcome: 0, retry_safe: 1 })
writeCase('write-tiny', { outcome: 0, retry_safe: 1 })
writeCase('write-mid', { outcome: 0, retry_safe: 1 })
writeCase('write-short', { outcome: 0, retry_safe: 1 })
writeCase('write-zero', { outcome: 3, retry_safe: 1 })

const injected = (name) => {
    const result = fixtureResult(name)
    const detail = result.error.detail
    const outcome =
        detail === 'the caller cancelled' ? 1 : detail === 'the deadline elapsed' ? 2 : 3
    return { outcome, retry_safe: result.retry_safe ? 1 : 0 }
}
writeCase('cancel-write', injected('cancel_at_write'))
writeCase('deadline-write', injected('deadline_at_write'))
writeCase('fail-write', injected('fail_at_write'))
writeCase('deadline-write-post', injected('deadline_at_write_post'))
writeCase('fail-write-post', injected('fail_at_write_post'))

console.log(`PASS: ${cases.size} serializer cases agree with the #1257 model`)

// The corpus, and the two joins that keep it honest (#1352).
//
// `corpus.json` is the single source of the message bytes. This writes them out
// for the C oracle to digest, and checks that the literals inside
// `sha256.kofun` are the same bytes — so the message the Kofun model hashes and
// the message `bootstrap/stage2/sha256.c` hashes cannot drift apart while both
// sides stay green.
//
// It computes no digest. The C implementation is the oracle and the published
// vectors are the anchor; a JavaScript SHA-256 here would be a third
// implementation agreeing with itself.

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const CORPUS = JSON.parse(readFileSync(join(HERE, 'corpus.json'), 'utf8'))
const SOURCE = readFileSync(join(HERE, 'sha256.kofun'), 'utf8')

if (CORPUS.schema !== 'kofun.digest-model-corpus/v1') {
    throw new Error(`unexpected corpus schema ${CORPUS.schema}`)
}

// The four vectors FIPS 180-4 publishes, written out rather than referenced, so
// the gate anchors on the standard and not only on agreement between two
// implementations in this repository.
const PUBLISHED = Object.freeze({
    empty: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    abc: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    nist448: '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    nist896: 'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1',
})

function literalFor(name, part) {
    const pattern = new RegExp(`let ${name}_${part}: List\\[Int\\] = (\\[[^\\]]*\\])`)
    const match = pattern.exec(SOURCE)
    if (match === null) throw new Error(`sha256.kofun has no ${name}_${part} literal`)
    return match[1]
        .replace(/[[\]\s]/g, '')
        .split(',')
        .filter((piece) => piece.length > 0)
        .map((piece) => {
            if (!/^\d+$/.test(piece)) throw new Error(`${name}_${part} has a non-integer ${piece}`)
            return Number(piece)
        })
}

function checkLiterals() {
    for (const message of CORPUS.messages) {
        const first = literalFor(message.name, 'first')
        const second = literalFor(message.name, 'second')
        // A zero-length message still needs a list to name, so it carries one
        // element that the length keeps out of the digest.
        const expectedFirst = message.length === 0 ? [0] : message.bytes.slice(0, 64)
        const expectedSecond = message.bytes.slice(64)
        if (JSON.stringify(first) !== JSON.stringify(expectedFirst)) {
            throw new Error(`${message.name}_first does not match corpus.json`)
        }
        if (JSON.stringify(second) !== JSON.stringify(expectedSecond)) {
            throw new Error(`${message.name}_second does not match corpus.json`)
        }
        if (message.bytes.length !== message.length) {
            throw new Error(`${message.name} declares length ${message.length} and carries ${message.bytes.length}`)
        }
        for (const byte of message.bytes) {
            if (!Number.isInteger(byte) || byte < 0 || byte > 255) {
                throw new Error(`${message.name} carries a non-byte ${byte}`)
            }
        }
    }
    return CORPUS.messages.length
}

const [mode, argument] = process.argv.slice(2)

if (mode === 'files') {
    if (argument === undefined) throw new Error('usage: corpus.mjs files <directory>')
    for (const message of CORPUS.messages) {
        writeFileSync(join(argument, `${message.name}.bin`), Buffer.from(message.bytes))
    }
    process.stdout.write(CORPUS.messages.map((message) => message.name).join('\n') + '\n')
} else if (mode === 'literals') {
    process.stdout.write(`${checkLiterals()}\n`)
} else if (mode === 'published') {
    const lines = Object.entries(PUBLISHED).map(([name, digest]) => {
        const message = CORPUS.messages.find((entry) => entry.name === name)
        if (message === undefined) throw new Error(`the corpus has no ${name} message`)
        return `${name} ${digest}`
    })
    process.stdout.write(lines.join('\n') + '\n')
} else if (mode === 'names') {
    process.stdout.write(CORPUS.messages.map((message) => message.name).join(' ') + '\n')
} else {
    process.stderr.write('usage: corpus.mjs <files DIR|literals|published|names>\n')
    process.exit(2)
}

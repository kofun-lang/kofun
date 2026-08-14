#!/usr/bin/env node

// Decode a wasm module's sections and exports from its bytes.
//
// The point is independence: the emitter's own account of what it wrote is not
// evidence about what it wrote. This reads the binary with nothing shared
// between it and `bootstrap/wasm/compiler.c` except the format.
//
// Output is one fact per line so the gate can assert on exact lines rather than
// on a substring of a paragraph — `section import` and `export main func` are
// each either present or absent, with no third reading.

import { readFileSync } from 'node:fs'

const SECTIONS = {
    0: 'custom', 1: 'type', 2: 'import', 3: 'function', 4: 'table',
    5: 'memory', 6: 'global', 7: 'export', 8: 'start', 9: 'elem',
    10: 'code', 11: 'data', 12: 'datacount',
}
const KINDS = { 0: 'func', 1: 'table', 2: 'memory', 3: 'global' }

const bytes = readFileSync(process.argv[2])
if (bytes.length < 8) throw new Error('not a wasm module: too short')
const magic = bytes.subarray(0, 4).toString('hex')
if (magic !== '0061736d') throw new Error(`not a wasm module: magic ${magic}`)
const version = bytes.subarray(4, 8).toString('hex')
if (version !== '01000000') throw new Error(`unexpected wasm version ${version}`)

const out = []
let i = 8

function uleb() {
    let value = 0
    let shift = 0
    for (;;) {
        const byte = bytes[i]
        i += 1
        value |= (byte & 0x7f) << shift
        if ((byte & 0x80) === 0) return value
        shift += 7
    }
}

while (i < bytes.length) {
    const id = bytes[i]
    i += 1
    const size = uleb()
    const end = i + size
    out.push(`section ${SECTIONS[id] ?? id}`)
    if (id === 7) {
        const count = uleb()
        for (let entry = 0; entry < count; entry += 1) {
            const nameLength = uleb()
            const name = bytes.subarray(i, i + nameLength).toString('utf8')
            i += nameLength
            const kind = bytes[i]
            i += 1
            uleb() // index
            out.push(`export ${name} ${KINDS[kind] ?? kind}`)
        }
    }
    i = end
}

process.stdout.write(out.join('\n') + '\n')

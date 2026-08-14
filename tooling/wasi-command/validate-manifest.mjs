#!/usr/bin/env node

// Validate a wasm32-wasi-command1 capability manifest against the frozen model.
//
//     node tooling/wasi-command/validate-manifest.mjs MANIFEST.json
//
// The refusals are #1293's, by name, because the vocabulary is what a caller
// writes code against: `UnknownCapabilityKey` and `IncompleteManifest` are
// different mistakes with different fixes, and collapsing them into "invalid
// manifest" makes the reader guess which they made.
//
// This calls `project` from the projection model rather than re-implementing
// its rules. A transcription of an executable contract agrees with whoever
// transcribed it — #1296's first slice shipped a gate that did exactly that and
// passed a module the normative validator refused.

import { readFileSync } from 'node:fs'

import { CAPABILITIES } from '../../spec/wasi-command-profile-v1/contract.mjs'
import { Refusal, project } from '../../spec/wasi-command-projection-v1/model.mjs'

const path = process.argv[2]
if (path === undefined) {
    process.stderr.write('usage: validate-manifest.mjs MANIFEST.json\n')
    process.exit(2)
}

let parsed
try {
    parsed = JSON.parse(readFileSync(path, 'utf8'))
} catch (error) {
    process.stderr.write(`MalformedManifest: ${path}: ${error.message}\n`)
    process.exit(1)
}

if (parsed.profile !== 'wasm32-wasi-command1') {
    process.stderr.write(
        `UnknownProfile: ${JSON.stringify(parsed.profile)} is not wasm32-wasi-command1\n`,
    )
    process.exit(1)
}

// The page ceiling lives in the manifest per the profile. A manifest that omits
// it is incomplete rather than defaulted: a silent default is a grant nobody
// wrote.
try {
    // `reachable: []` is this slice — no checked operation is lowered yet, so
    // the projection's job here is the manifest's own validity. The grant rules
    // run unchanged, which is what makes this the same check the later slice
    // needs rather than a stand-in for it.
    const result = project(
        { reachable: [] },
        { capabilities: parsed.capabilities, memoryPages: parsed.memoryPages },
    )
    process.stdout.write(`imports ${result.imports.length}\n`)
    process.stdout.write(`granted ${result.grantedButUnused.length}/${CAPABILITIES.length}\n`)
} catch (error) {
    if (error instanceof Refusal) {
        // `Refusal.message` already begins with the code — writing both
        // produced `UnknownCapabilityKey: UnknownCapabilityKey: telepathy`,
        // which reads as a bug in the tool rather than in the manifest.
        process.stderr.write(`${error.code}: ${error.detail}\n`)
        process.exit(1)
    }
    throw error
}

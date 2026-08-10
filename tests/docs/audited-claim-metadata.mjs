#!/usr/bin/env node
// The structured half of the audited-claim gate (#1170).
//
// `tests/docs/audited-claim.sh` reads Markdown. The same claim lives in JSON
// that no prose scan touches, and that JSON is the more authoritative of the
// two because tooling reads it and quotes it onward. #1156 found the Stage 1
// seed described as an `"audited C11 artifact"` in `bootstrap/manifest.json`
// -- three lines below `"bootstrap_model": "trusted-c11-seed"`, so one object
// gave two answers -- and it had survived both #1138 and the prose gate built
// for #1138, because everyone including its author went looking in prose.
//
// This cannot be done by widening the prose scan. These are JSON string
// values, and which ones carry a claim is a per-field judgement: `public_wording`
// and `bounded_capability` describe the artifact, while `criterion`, `note`
// and `reproduction_command` describe how it is checked. A line-oriented scan
// cannot tell those apart, so the fields are named here.
//
// The second-order reason this matters more than the prose sites:
// `release/claims.json` generates `artifacts/release-evidence/CLAIMS.md`, so
// one uncorrected field is copied into published evidence that reads as
// independently produced.
//
//   node tests/docs/audited-claim-metadata.mjs

import { readFileSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const PREFIX = 'audited-claim-metadata'

// The same record the prose gate keys off, so the two halves cannot disagree
// about whether the word is available. Kept as a literal rather than parsed
// out of the shell script: a parser that failed to find it would silently
// decide the deliverable was closed, which is the failure this gate exists to
// stop.
const AUDIT_RECORD = 'bootstrap/AUDIT.md'

// Claim-bearing fields only. Anything not listed here is not read, so adding a
// descriptive field to either file does not silently widen this gate.
const MANIFEST_FIELDS = [
    { path: ['bootstrap_model'] },
    { path: ['truthful_status'] },
    { path: ['stages', '*', 'role'] },
    { path: ['stages', '*', 'status'] },
    { path: ['stages', '*', 'implementation'] },
    { path: ['gates', '*'] },
]
const CLAIM_FIELDS = [
    'public_wording',
    'public_status',
    'bounded_capability',
    'compatibility',
]

// `bindgen-c-stage1` is about bindgen's output -- raw `extern "C"` declarations
// derived from a Clang AST -- not about the bootstrap chain, and it sits
// outside the M4 deliverable entirely. Sweeping it in would be the mirror of
// the error #1138 was filed about: correcting a word without reading what it
// was attached to.
//
// Exempted by claim id rather than by pattern, deliberately. "A different
// subject" is not expressible as a regular expression, and an attempt at one
// would either miss this or start exempting real sites by accident. An id is
// a judgement recorded as a judgement.
const EXEMPT_CLAIM_IDS = new Set(['bindgen-c-stage1'])

// "audited <noun>" claims the act. "can be independently audited" states a
// property, which the ROADMAP deliverable and any future audit record both
// need to keep saying. Same distinction the prose gate draws.
const CLAIMS_AUDIT = /\baudited\b/
const STATES_PROPERTY = /\b(?:be|being|independently) audited\b/

const failures = []
const fail = (subject, detail) => failures.push({ subject, detail })

function readJson(relative) {
    // Fail closed: an unreadable or malformed file constrains the word rather
    // than releasing it, because releasing it is the outcome that restores the
    // defect.
    try {
        return JSON.parse(readFileSync(join(ROOT, relative), 'utf8'))
    } catch (error) {
        fail(relative, `is missing or is not JSON (${error.message})`)
        return null
    }
}

function offending(value) {
    if (typeof value !== 'string') return false
    return CLAIMS_AUDIT.test(value) && !STATES_PROPERTY.test(value)
}

// Resolves one field spec into [path, value] pairs, expanding `*` over the
// keys of an object. A spec that matches nothing is itself a failure: it means
// the file moved under this gate and the gate stopped looking.
function resolveField(root, path, relative) {
    let frontier = [{ trail: [], node: root }]
    for (const step of path) {
        const next = []
        for (const { trail, node } of frontier) {
            if (node === null || typeof node !== 'object') continue
            if (step === '*') {
                for (const [key, value] of Object.entries(node)) {
                    next.push({ trail: [...trail, key], node: value })
                }
            } else if (Object.hasOwn(node, step)) {
                next.push({ trail: [...trail, step], node: node[step] })
            }
        }
        frontier = next
    }
    if (frontier.length === 0) {
        fail(relative, `declares no \`${path.join('.')}\`; this gate is no longer reading what it names`)
    }
    return frontier
}

function scanManifest(scanRoot) {
    const hits = []
    const manifest = scanRoot ?? readJson('bootstrap/manifest.json')
    if (manifest === null) return hits
    for (const { path } of MANIFEST_FIELDS) {
        for (const { trail, node } of resolveField(manifest, path, 'bootstrap/manifest.json')) {
            if (offending(node)) {
                hits.push({ file: 'bootstrap/manifest.json', at: trail.join('.'), value: node })
            }
        }
    }
    return hits
}

function scanClaims(scanRoot) {
    const hits = []
    const claims = scanRoot ?? readJson('release/claims.json')
    if (claims === null) return hits
    if (!Array.isArray(claims.claims)) {
        fail('release/claims.json', 'has no `claims` array')
        return hits
    }
    for (const claim of claims.claims) {
        if (EXEMPT_CLAIM_IDS.has(claim.id)) continue
        for (const field of CLAIM_FIELDS) {
            if (offending(claim[field])) {
                hits.push({
                    file: 'release/claims.json',
                    at: `${claim.id}.${field}`,
                    value: claim[field],
                })
            }
        }
    }
    return hits
}

// ---------------------------------------------------------------------------

if (existsSync(join(ROOT, AUDIT_RECORD))) {
    process.stdout.write(
        `PASS: ${AUDIT_RECORD} records the audit; the word is unconstrained in metadata\n`)
    process.exit(0)
}

const hits = [...scanManifest(null), ...scanClaims(null)]

for (const hit of hits) {
    fail(`${hit.file} ${hit.at}`,
        `describes the bootstrap artifacts as audited: ${JSON.stringify(hit.value.slice(0, 90))}`)
}

// --------------------------------------------------------------- self-test
// This scan is quiet today: after #1156 the only remaining occurrence is the
// exempt one. Quiet is indistinguishable from broken without this -- which is
// exactly how the prose gate spent its whole life reporting PASS while
// matching nothing. So the scan is required to still refuse a reintroduced
// claim, and to still respect the exemption while doing it.
{
    // Shaped like the real file, so the "no longer reading what it names"
    // check exercises the same paths rather than tripping on a thin probe.
    const probe = {
        bootstrap_model: 'trusted-c11-seed',
        truthful_status: 'fine',
        stages: {
            trusted_seed: {
                implementation: 'bootstrap/stage1/compiler.c',
                status: 'working',
                role: 'audited C11 artifact used to start the compiler',
            },
        },
        gates: { python_free_bootstrap: 'working' },
    }
    if (scanManifest(probe).length === 0) {
        fail('self-test', 'the manifest scan did not flag a reintroduced audit claim; it is inert')
    }

    const claimProbe = {
        claims: [
            { id: 'compiler-seed', bounded_capability: 'kept beside a hand-audited C transliteration' },
            { id: 'bindgen-c-stage1', public_wording: 'audited raw C bindings from the Clang AST' },
            { id: 'reproducible-bootstrap', compatibility: 'the seed can be independently audited' },
        ],
    }
    const claimHits = scanClaims(claimProbe)
    if (!claimHits.some((hit) => hit.at.startsWith('compiler-seed'))) {
        fail('self-test', 'the claims scan did not flag a reintroduced audit claim; it is inert')
    }
    if (claimHits.some((hit) => hit.at.startsWith('bindgen-c-stage1'))) {
        fail('self-test', 'the claims scan swept in the exempt bindgen claim')
    }
    if (claimHits.some((hit) => hit.at.startsWith('reproducible-bootstrap'))) {
        fail('self-test', '"can be independently audited" states a property and must stay sayable')
    }
}

if (failures.length > 0) {
    for (const { subject, detail } of failures) {
        process.stderr.write(`${PREFIX}: ${subject}: ${detail}\n`)
    }
    process.stderr.write(
        `${PREFIX}: no audit record exists at ${AUDIT_RECORD}, so the bootstrap\n` +
        `  artifacts may not be described as audited. Record the audit there and\n` +
        `  close the docs/ROADMAP.md deliverable, or say what is true: the seeds\n` +
        `  are hash-pinned and gated, which is a real and different property.\n`)
    process.exit(1)
}

process.stdout.write(
    'PASS: no claim-bearing metadata field claims an audit, and the scan still refuses one\n')

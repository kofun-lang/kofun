#!/usr/bin/env node
// Negative-mutation fixtures for the release claim manifest.
//
// Each mutation breaks the claim/evidence join in one specific way that the
// manifest is supposed to make impossible. `check-claims.sh` applies every one
// and requires the checker to refuse it, naming the affected claim. Without
// this, a checker that silently stopped enforcing a rule would still report
// PASS on the honest manifest and nobody would notice.
//
//   node tests/release/make-invalid.mjs list
//   node tests/release/make-invalid.mjs <mutation> <output.json>

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const MANIFEST_PATH = join(ROOT, 'release', 'claims.json')

// Every mutation names the subject the checker must blame, so the gate asserts
// the diagnostic points at the right row rather than merely being non-empty.
const MUTATIONS = {
    'status-drift': {
        blame: 'arithmetic-core',
        apply(manifest) {
            find(manifest, 'arithmetic-core').public_status = 'fully general'
        },
    },
    'orphaned-claim': {
        blame: 'arithmetic-core',
        apply(manifest) {
            find(manifest, 'arithmetic-core').public_wording = 'a capability nobody publishes'
        },
    },
    'unowned-public-claim': {
        blame: 'docs/MVP_IMPLEMENTED.md',
        apply(manifest) {
            manifest.claims = manifest.claims.filter((claim) => claim.id !== 'arithmetic-core')
        },
    },
    'renamed-claim-id': {
        blame: 'docs/MVP_IMPLEMENTED.md',
        apply(manifest) {
            find(manifest, 'arithmetic-core').id = 'arithmetic-core-v2'
            manifest.claims.sort((left, right) => (left.id < right.id ? -1 : 1))
        },
    },
    'duplicate-id': {
        blame: 'arithmetic-core',
        apply(manifest) {
            manifest.claims.push(structuredClone(find(manifest, 'arithmetic-core')))
        },
    },
    'missing-evidence-file': {
        blame: 'arithmetic-core',
        apply(manifest) {
            find(manifest, 'arithmetic-core').negative_boundary.evidence =
                'tests/conformance/numeric/this_fixture_was_deleted.kofun'
        },
    },
    'directory-as-evidence': {
        blame: 'arithmetic-core',
        apply(manifest) {
            find(manifest, 'arithmetic-core').negative_boundary.evidence = 'tests/fuzz'
        },
    },
    // Names a task that does not exist, so the checker must resolve the
    // command against Taskfile.yml and refuse it. A command that is not a
    // `task <name>` at all is a different refusal, covered below.
    'missing-task': {
        blame: 'arithmetic-core',
        apply(manifest) {
            find(manifest, 'arithmetic-core').reproduction.command = 'task no-such-task'
        },
    },
    'unresolvable-command': {
        blame: 'arithmetic-core',
        apply(manifest) {
            // Deliberately still spelled `make`: this mutation exercises the
            // "not a resolvable command" refusal, which is a different path
            // from `missing-task` above. A bulk make-to-task rename must not
            // touch it.
            find(manifest, 'arithmetic-core').reproduction.command = 'make native'
        },
    },
    'unknown-state': {
        blame: 'claims[0].state',
        apply(manifest) {
            manifest.claims[0].state = 'nearly-implemented'
        },
    },
    'unknown-target': {
        blame: 'arithmetic-core',
        apply(manifest) {
            find(manifest, 'arithmetic-core').targets = ['some-unlisted-target']
        },
    },
    'unknown-area': {
        blame: 'arithmetic-core',
        apply(manifest) {
            find(manifest, 'arithmetic-core').area = 'undeclared'
        },
    },
    'open-claim-with-positive-gate': {
        blame: 'general-native-lowering',
        apply(manifest) {
            find(manifest, 'general-native-lowering').positive_gate = {
                command: 'task native',
                observation: 'general native lowering works',
            }
        },
    },
    'unsupported-claim-without-refusal': {
        blame: 'general-parser-type-checker',
        apply(manifest) {
            const claim = find(manifest, 'general-parser-type-checker')
            claim.state = 'unsupported'
            claim.negative_boundary = {
                kind: 'limit',
                evidence: 'docs/TYPE_SYSTEM.md',
                observation: 'documented as absent',
            }
        },
    },
    'executable-claim-without-boundary': {
        blame: 'arithmetic-core',
        apply(manifest) {
            delete find(manifest, 'arithmetic-core').negative_boundary
        },
    },
    'safety-claim-without-threat-model': {
        blame: 'borrowed-list-ownership',
        apply(manifest) {
            delete find(manifest, 'borrowed-list-ownership').safety.threat_model
        },
    },
    'performance-claim-without-budget': {
        blame: 'stdio-language-server',
        apply(manifest) {
            delete find(manifest, 'stdio-language-server').performance.budget
        },
    },
    'unknown-manifest-field': {
        blame: 'claims[0]',
        apply(manifest) {
            manifest.claims[0].verified_by_vibes = true
        },
    },
    'undeclared-readme-area': {
        blame: 'README.md',
        apply(manifest) {
            manifest.areas = manifest.areas.filter((area) => area !== 'native')
        },
    },

    // The #1108 incident, reproduced from the side this file can reach. The
    // original ran the other way — `bootstrap/manifest.json` flipped three
    // B4/B5 keys to `working` while the claim went on saying the fixed point
    // was open — but the contradiction the checker sees is the same one, and
    // it is symmetric: a claim that does not rest on executable evidence may
    // not name a bootstrap gate that passes.
    'manifest-gate-contradiction': {
        blame: 'general-native-lowering',
        apply(manifest) {
            find(manifest, 'general-native-lowering').manifest_gates =
                ['diverse_double_compilation']
        },
    },
    // A key that no longer exists is a join that silently stopped joining.
    'unknown-manifest-gate': {
        blame: 'self-recompile',
        apply(manifest) {
            find(manifest, 'self-recompile').manifest_gates = ['a_gate_nobody_declares']
        },
    },
    // And a bootstrap gate no claim names is a status nobody has to keep true,
    // which is how `diverse_double_compilation` reached `working` unpublished.
    'unjoined-manifest-gate': {
        blame: 'bootstrap/manifest.json',
        apply(manifest) {
            delete find(manifest, 'diverse-double-compilation').manifest_gates
        },
    },
}

function find(manifest, id) {
    const claim = manifest.claims.find((candidate) => candidate.id === id)
    if (claim === undefined) {
        process.stderr.write(`release-claims-invalid: the manifest no longer contains \`${id}\`\n`)
        process.exit(2)
    }
    return claim
}

const [name, output] = process.argv.slice(2)

if (name === 'list') {
    for (const [mutation, { blame }] of Object.entries(MUTATIONS)) {
        process.stdout.write(`${mutation}\t${blame}\n`)
    }
    process.exit(0)
}

if (name === undefined || output === undefined) {
    process.stderr.write('release-claims-invalid: usage: make-invalid.mjs <mutation|list> <output.json>\n')
    process.exit(2)
}

const mutation = MUTATIONS[name]
if (mutation === undefined) {
    process.stderr.write(`release-claims-invalid: unknown mutation \`${name}\`\n`)
    process.exit(2)
}

const manifest = JSON.parse(readFileSync(MANIFEST_PATH, 'utf8'))
mutation.apply(manifest)
writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`)

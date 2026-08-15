#!/usr/bin/env node
// Negative-mutation fixtures for the RFC ledger.
//
// Each mutation is one way the accepted/implemented/enabled/amended distinction
// can collapse. `check-registry.sh` applies every one and requires the checker
// to refuse it, naming the decision. Without these, a checker that quietly
// stopped enforcing a rule would keep reporting PASS on the honest ledger.
//
//   node tests/rfc/make-invalid.mjs list
//   node tests/rfc/make-invalid.mjs <mutation> <output.json>

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const REGISTRY_PATH = join(ROOT, 'rfcs', 'index.json')

/*
 * A date strictly after the day this run treats as today, so a "future date"
 * fixture cannot expire. `KOFUN_RFC_TODAY` is read here for the same reason the
 * validator reads it: the two must agree about which day it is, or a mutation
 * lands on the wrong side of the boundary it is testing.
 */
function afterToday(days) {
    const today = process.env.KOFUN_RFC_TODAY ?? new Date().toISOString().slice(0, 10)
    const when = new Date(`${today}T00:00:00Z`)
    when.setUTCDate(when.getUTCDate() + days)
    const stamped = when.toISOString().slice(0, 10)
    /*
     * Past 9999-12-31 `toISOString` switches to the expanded form
     * (`+010000-01-01`), which is a different shape and would silently produce
     * a fixture the ledger rejects for the wrong reason — "not a date" rather
     * than "has not happened yet". Refusing here keeps the failure honest
     * rather than making the corpus mean something else at the boundary.
     */
    if (!/^\d{4}-\d{2}-\d{2}$/.test(stamped)) {
        throw new Error(
            `afterToday(${days}) from ${today} leaves the four-digit calendar: ${stamped}`,
        )
    }
    return stamped
}

const MUTATIONS = {
    // Acceptance is not implementation. Both directions of that confusion.
    'implemented-without-implementation': {
        blame: 'DD-010',
        apply(ledger) {
            delete find(ledger, 'DD-010').implementation
        },
    },
    'accepted-rendered-implemented': {
        blame: 'DD-013',
        apply(ledger) {
            find(ledger, 'DD-013').state = 'implemented'
        },
    },
    'accepted-carrying-implementation': {
        blame: 'DD-013',
        apply(ledger) {
            find(ledger, 'DD-013').implementation = {
                change: 'https://github.com/kofun-lang/kofun/issues/687',
                enablement: 'Enabled everywhere.',
                gate: 'task verify',
                claims: ['checked-int64-contract'],
            }
        },
    },

    // The join with the capability manifest: a decision cannot be implemented
    // on the strength of a claim that is not.
    'implementation-on-design-claim': {
        blame: 'DD-012',
        apply(ledger) {
            find(ledger, 'DD-012').implementation.claims = ['formatter-and-repl']
        },
    },
    'implementation-on-unknown-claim': {
        blame: 'DD-012',
        apply(ledger) {
            find(ledger, 'DD-012').implementation.claims = ['a-capability-nobody-manifests']
        },
    },
    'implementation-gate-missing': {
        blame: 'DD-010',
        apply(ledger) {
            find(ledger, 'DD-010').implementation.gate = 'sh tests/conformance/deleted.sh'
        },
    },

    // Amendments must be visible from the document a reader actually opens,
    // and the ledger may not record one the document never announces.
    'amendment-not-announced': {
        blame: 'DD-012/A01',
        apply(ledger) {
            find(ledger, 'DD-012').amendments = [
                {
                    id: 'A01',
                    recorded_on: '2026-07-26',
                    delta: 'Backends may now substitute a construct they cannot lower.',
                    original_semantics: 'A backend that cannot lower a construct fails with a source-located error.',
                    compatibility: {
                        category: 'breaking',
                        statement: 'Programs that previously failed would now silently change meaning.',
                    },
                },
            ]
        },
    },
    'amendment-dropped-from-ledger': {
        blame: 'DD-010/A01',
        apply(ledger) {
            delete find(ledger, 'DD-010').amendments
        },
    },
    'amendment-with-no-delta': {
        blame: 'DD-010/A01',
        apply(ledger) {
            const amendment = find(ledger, 'DD-010').amendments[0]
            amendment.original_semantics = amendment.delta
        },
    },

    // Compatibility analysis has to be a measurement, not an impression.
    'conditional-without-corpus': {
        blame: 'DD-010',
        apply(ledger) {
            const compatibility = find(ledger, 'DD-010').compatibility
            compatibility.category = 'conditional'
            delete compatibility.corpus_query
            delete compatibility.result
        },
    },
    'hedged-compatibility': {
        blame: 'DD-018',
        apply(ledger) {
            find(ledger, 'DD-018').compatibility.statement =
                'The change is likely compatible with everything anyone has written.'
        },
    },

    // Review windows are real for native RFCs and absent for migrated ones.
    // Neither may borrow the other's evidence.
    'migrated-with-invented-review': {
        blame: 'DD-013',
        apply(ledger) {
            find(ledger, 'DD-013').dates.opened_on = '2026-07-01'
        },
    },
    'review-closed-before-it-opened': {
        blame: 'DD-013',
        apply(ledger) {
            const rfc = find(ledger, 'DD-013')
            rfc.provenance = 'rfc'
            rfc.document = 'rfcs/TEMPLATE.md'
            rfc.dates = {
                opened_on: '2026-07-23',
                review_closed_on: '2026-07-20',
                decided_on: '2026-07-23',
            }
        },
    },
    // A scheduled date and a real one look identical once written down, so a
    // proposal that carries either closing date reads as closed to anything
    // that joins on that field.
    //
    // #1446. These two carried `2026-08-15`, chosen as "a date in the future"
    // when they were written. On 2026-08-15 it stopped being one, the
    // future-date rule stopped firing, and the first mutation was accepted —
    // the corpus failed because the calendar moved rather than because the
    // ledger changed.
    //
    // The dates are now relative to the pinned today, so there is no date at
    // which they stop being future. `KOFUN_RFC_TODAY` pins that for the whole
    // corpus, which is what makes the run deterministic; the harness sets it.
    'proposed-claiming-a-decision-date': {
        blame: 'RFC-0001',
        apply(ledger) {
            find(ledger, 'RFC-0001').dates.decided_on = afterToday(1)
        },
    },
    'proposed-claiming-a-closed-review': {
        blame: 'RFC-0001',
        apply(ledger) {
            find(ledger, 'RFC-0001').dates.review_closed_on = afterToday(1)
        },
    },
    // Every ledger date is a fact. One that has not happened yet is a promise
    // wearing a fact's clothes, and joins on it read as history.
    'decided-in-the-future': {
        blame: 'DD-013',
        apply(ledger) {
            const rfc = find(ledger, 'DD-013')
            rfc.provenance = 'rfc'
            rfc.document = 'rfcs/TEMPLATE.md'
            rfc.dates = {
                opened_on: '2026-07-20',
                review_closed_on: afterToday(2),
                decided_on: afterToday(3),
            }
        },
    },
    'native-rfc-without-document': {
        blame: 'DD-013',
        apply(ledger) {
            const rfc = find(ledger, 'DD-013')
            rfc.provenance = 'rfc'
            rfc.dates = {
                opened_on: '2026-06-01',
                review_closed_on: '2026-07-01',
                decided_on: '2026-07-02',
            }
        },
    },

    // Closed decisions stay discoverable; supersession points somewhere real.
    'superseded-without-successor': {
        blame: 'DD-018',
        apply(ledger) {
            find(ledger, 'DD-018').state = 'superseded'
        },
    },
    'unknown-successor': {
        blame: 'DD-018',
        apply(ledger) {
            const rfc = find(ledger, 'DD-018')
            rfc.state = 'superseded'
            rfc.superseded_by = 'RFC-9999'
        },
    },
    'rejected-without-rationale': {
        blame: 'DD-013',
        apply(ledger) {
            find(ledger, 'DD-013').state = 'rejected'
        },
    },

    // Ordinary registry integrity.
    'duplicate-id': {
        blame: 'DD-010',
        apply(ledger) {
            ledger.rfcs.push(structuredClone(find(ledger, 'DD-010')))
        },
    },
    'missing-normative-spec': {
        blame: 'DD-013',
        apply(ledger) {
            find(ledger, 'DD-013').normative_spec = ['docs/A_DOCUMENT_NOBODY_WROTE.md']
        },
    },
    'unknown-ledger-field': {
        blame: 'rfcs[0]',
        apply(ledger) {
            ledger.rfcs[0].ratified_by_acclamation = true
        },
    },
}

function find(ledger, id) {
    const rfc = ledger.rfcs.find((candidate) => candidate.id === id)
    if (rfc === undefined) {
        process.stderr.write(`rfc-ledger-invalid: the ledger no longer contains \`${id}\`\n`)
        process.exit(2)
    }
    return rfc
}

const [name, output] = process.argv.slice(2)

if (name === 'list') {
    for (const [mutation, { blame }] of Object.entries(MUTATIONS)) {
        process.stdout.write(`${mutation}\t${blame}\n`)
    }
    process.exit(0)
}

if (name === undefined || output === undefined) {
    process.stderr.write('rfc-ledger-invalid: usage: make-invalid.mjs <mutation|list> <output.json>\n')
    process.exit(2)
}

const mutation = MUTATIONS[name]
if (mutation === undefined) {
    process.stderr.write(`rfc-ledger-invalid: unknown mutation \`${name}\`\n`)
    process.exit(2)
}

const ledger = JSON.parse(readFileSync(REGISTRY_PATH, 'utf8'))
mutation.apply(ledger)
writeFileSync(output, `${JSON.stringify(ledger, null, 2)}\n`)

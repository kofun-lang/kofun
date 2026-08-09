#!/usr/bin/env node
// RFC ledger checker.
//
// The ledger records durable public semantic decisions. Its job is to keep four
// things from blurring together: a decision that was accepted, a decision that
// was implemented, a decision that was enabled, and a decision whose semantics
// later changed. `rfcs/index.json` is the authoritative record; nothing
// generated from it is a second editable source.
//
//   node tests/rfc/validate-registry.mjs schema
//   node tests/rfc/validate-registry.mjs validate [registry]
//
// Failures print one line per defect, each naming the decision and the repair,
// and exit 1. Usage errors exit 2.

import { execFileSync } from 'node:child_process'
import { readFileSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { validateAgainstSchema } from '../lib/json-schema.mjs'
import { taskfileTasks } from '../lib/taskfile.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const SCHEMA_PATH = 'spec/rfc-ledger.schema.json'
const REGISTRY_PATH = 'rfcs/index.json'
const CLAIMS_PATH = 'release/claims.json'

const PREFIX = 'rfc-ledger'

// An amendment is announced in the document that carries the decision text, so
// a reader of that document cannot miss that the semantics moved. The marker is
// the fully-qualified amendment id.
const AMENDMENT_MARKER = /\b((?:RFC-[0-9]{4}|DD-[0-9]{3})\/A[0-9]{2})\b/g

// Compatibility analysis is the one place where a guess is worth less than
// nothing, because it reads like a measurement. These phrases are refused so
// the field carries a query and a count instead.
const HEDGES = [
    'likely compatible', 'probably', 'presumably', 'we think', 'we believe',
    'seems compatible', 'mostly compatible', 'should be compatible',
    'largely compatible', 'more or less', 'roughly compatible',
]

function usage(message) {
    process.stderr.write(`${PREFIX}: ${message}\n`)
    process.exit(2)
}

function readRepositoryFile(relative) {
    return readFileSync(join(ROOT, relative), 'utf8')
}

function trackedFiles() {
    const output = execFileSync('git', ['-C', ROOT, 'ls-files', '-z'], {
        encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
    })
    return new Set(output.split('\0').filter((entry) => entry !== ''))
}

function daysBetween(earlier, later) {
    return (Date.parse(`${later}T00:00:00Z`) - Date.parse(`${earlier}T00:00:00Z`)) / 86400000
}

class Report {
    constructor() {
        this.errors = []
    }

    fail(subject, message, repair) {
        this.errors.push(`${PREFIX}: ${subject}: ${message}. Repair: ${repair}`)
    }

    get ok() {
        return this.errors.length === 0
    }
}

function checkPath(report, subject, field, value, tracked) {
    if (value.includes('..') || value.startsWith('/') || value.includes('//')) {
        report.fail(subject, `${field} \`${value}\` is not a normalized repository-relative path`,
            'write the path relative to the repository root without `..` or a leading slash')
        return false
    }
    if (!tracked.has(value)) {
        let hint = 'point the field at a tracked file, or `git add` the document you meant'
        try {
            if (statSync(join(ROOT, value)).isDirectory()) {
                hint = 'name a file inside that directory; a directory is not a decision record'
            }
        } catch {
            // Absent entirely: the default hint is the right one.
        }
        report.fail(subject, `${field} \`${value}\` is not a tracked repository file`, hint)
        return false
    }
    return true
}

function checkCompatibility(report, subject, label, compatibility, tracked) {
    const { category, statement, corpus_query: query, result, evidence } = compatibility

    if (category === 'conditional') {
        if (query === undefined || result === undefined) {
            report.fail(subject, `${label} is conditional but names no reproducible corpus query and result`,
                'state the command another person can run and the number it returns; a conditional claim without a count is a guess')
        }
    }
    if (category === 'none' && (query !== undefined || result !== undefined)) {
        report.fail(subject, `${label} is \`none\` but carries corpus evidence`,
            'classify the change, or drop the evidence that implies one')
    }
    if ((query === undefined) !== (result === undefined)) {
        report.fail(subject, `${label} has a corpus query without a result, or the reverse`,
            'a query and what it returned travel together')
    }
    for (const [field, text] of [['statement', statement], ['result', result]]) {
        if (text === undefined) continue
        const hedge = HEDGES.find((phrase) => text.toLowerCase().includes(phrase))
        if (hedge !== undefined) {
            report.fail(subject, `${label} ${field} hedges with "${hedge}"`,
                'replace the estimate with a reproducible query and the count it returned')
        }
    }
    if (evidence !== undefined) {
        checkPath(report, subject, `${label} evidence`, evidence, tracked)
    }
}

function checkCommand(report, subject, field, value, tracked, targets) {
    const task = /^task ([A-Za-z][A-Za-z0-9_-]*)$/.exec(value)
    if (task) {
        if (!targets.has(task[1])) {
            report.fail(subject, `${field} names the missing task \`${task[1]}\``,
                'name a task that exists in Taskfile.yml')
        }
        return
    }
    const script = /^sh (\S+)$/.exec(value)
    if (script) {
        checkPath(report, subject, `${field} script`, script[1], tracked)
        return
    }
    report.fail(subject, `${field} \`${value}\` is not a resolvable command`,
        'write it as `task <name>` or `sh <tracked-script>` so the checker can resolve it')
}

function claimStates() {
    const manifest = JSON.parse(readRepositoryFile(CLAIMS_PATH))
    return new Map(manifest.claims.map((claim) => [claim.id, claim.state]))
}

export function validateRegistry(registry, schema, registryPath = REGISTRY_PATH) {
    const report = new Report()

    const schemaErrors = []
    validateAgainstSchema(schema, schema, registry, registryPath, schemaErrors)
    for (const error of schemaErrors) {
        report.fail('ledger', error, `make the ledger satisfy ${SCHEMA_PATH}`)
    }
    if (!report.ok) return report

    const tracked = trackedFiles()
    const targets = taskfileTasks(ROOT)
    const claims = claimStates()
    // The day this run treats as today. `KOFUN_RFC_TODAY` pins it so the
    // mutation corpus stays deterministic and a fixture cannot start failing
    // because the calendar moved.
    const today = process.env.KOFUN_RFC_TODAY ?? new Date().toISOString().slice(0, 10)
    if (!/^\d{4}-\d{2}-\d{2}$/.test(today)) {
        report.fail('ledger', `KOFUN_RFC_TODAY is \`${today}\`, which is not a YYYY-MM-DD date`,
            'set KOFUN_RFC_TODAY to a calendar date, or unset it to use the system date')
        return report
    }

    const byId = new Map()
    let previous = ''
    for (const rfc of registry.rfcs) {
        const subject = `\`${rfc.id}\``
        if (byId.has(rfc.id)) {
            report.fail(subject, 'duplicate decision id',
                'every decision has one row; a changed decision is an amendment, not a second row')
        }
        byId.set(rfc.id, rfc)
        if (rfc.id < previous) {
            report.fail(subject, 'decisions are not in ascending id order',
                'sort `rfcs` by id so review diffs stay stable')
        }
        previous = rfc.id

        checkPath(report, subject, 'source', rfc.source, tracked)
        for (const path of rfc.normative_spec) {
            checkPath(report, subject, 'normative spec entry', path, tracked)
        }
        checkCompatibility(report, subject, 'compatibility', rfc.compatibility, tracked)

        // Acceptance is not implementation. This is the whole reason the ledger
        // exists: a merged proposal, or a closed issue, must never read as
        // shipped behaviour.
        if (rfc.state === 'implemented') {
            if (rfc.implementation === undefined) {
                report.fail(subject, 'is `implemented` but names no implementation',
                    'name the change, the enablement boundary, the gate and the capability claims, or lower the state to `accepted`')
            }
        } else if (rfc.implementation !== undefined) {
            report.fail(subject, `is \`${rfc.state}\` but carries an implementation record`,
                'only `implemented` may claim shipped behaviour; raise the state or remove the record')
        }

        if (rfc.implementation !== undefined) {
            checkCommand(report, subject, 'implementation gate',
                rfc.implementation.gate, tracked, targets)
            for (const claim of rfc.implementation.claims) {
                const state = claims.get(claim)
                if (state === undefined) {
                    report.fail(subject, `implementation names the unknown capability claim \`${claim}\``,
                        `add the claim to ${CLAIMS_PATH}, or name one that exists`)
                } else if (state !== 'implemented' && state !== 'checkpoint') {
                    report.fail(subject,
                        `implementation rests on claim \`${claim}\`, which ${CLAIMS_PATH} records as \`${state}\``,
                        'a decision cannot be implemented on the strength of a claim that is not; fix whichever record is wrong')
                }
            }
        }

        if (rfc.state === 'superseded') {
            if (rfc.superseded_by === undefined) {
                report.fail(subject, 'is `superseded` but names no successor',
                    'name the decision that replaced it, so the reasoning stays reachable')
            }
        } else if (rfc.superseded_by !== undefined) {
            report.fail(subject, `is \`${rfc.state}\` but names a successor`,
                'set the state to `superseded`, or remove the successor')
        }

        const closed = rfc.state === 'rejected' || rfc.state === 'withdrawn'
        if (closed && rfc.rationale === undefined) {
            report.fail(subject, `is \`${rfc.state}\` but records no rationale`,
                'a closed decision stays discoverable only if it says why it closed')
        }

        // A migrated decision predates this process. Inventing a review window
        // for it would be fabricated evidence, so the ledger records the date
        // its text entered the repository and says plainly that it is migrated.
        const dates = rfc.dates
        if (rfc.provenance === 'rfc') {
            if (rfc.document === undefined) {
                report.fail(subject, 'is a native RFC with no proposal document',
                    'name the immutable proposal document under `rfcs/`')
            } else {
                checkPath(report, subject, 'document', rfc.document, tracked)
            }
            // Every date here is a recorded fact, never a schedule. A
            // scheduled date is indistinguishable from a real one once
            // written down -- which is exactly the confusion this ledger
            // exists to prevent -- so a proposal under review carries the
            // day it opened and nothing else. Review closes when the
            // shepherd closes it, and that day is written down then,
            // beside the decision it produced.
            if (dates.opened_on === undefined) {
                report.fail(subject, 'is a native RFC missing `opened_on`',
                    'a native RFC records the day it opened')
            }
            if (rfc.state === 'proposed') {
                for (const field of ['review_closed_on', 'decided_on']) {
                    if (dates[field] !== undefined) {
                        report.fail(subject,
                            `is \`proposed\` but records \`${field}\``,
                            `review has not closed, so \`${field}\` would be a schedule rather than a fact; record it when the shepherd closes review`)
                    }
                }
            } else {
                for (const field of ['review_closed_on', 'decided_on']) {
                    if (dates[field] === undefined) {
                        report.fail(subject,
                            `is \`${rfc.state}\` but records no \`${field}\``,
                            'a decided native RFC records the day review closed and the day it was decided')
                    }
                }
            }
            if (dates.recorded_on !== undefined) {
                report.fail(subject, 'is a native RFC carrying `recorded_on`',
                    '`recorded_on` belongs to migrated decisions; use the review dates')
            }
            // Ordering between the three recorded days. The review window's
            // length is guidance in rfcs/README.md, not a rule here: a
            // shepherd who has read the responses may close early, and a
            // gate that refused that would only push the fiction into the
            // dates.
            if (dates.opened_on !== undefined && dates.review_closed_on !== undefined &&
                daysBetween(dates.opened_on, dates.review_closed_on) < 0) {
                report.fail(subject, 'closed review before it opened',
                    'record `review_closed_on` on or after `opened_on`')
            }
            if (dates.review_closed_on !== undefined && dates.decided_on !== undefined &&
                daysBetween(dates.review_closed_on, dates.decided_on) < 0) {
                report.fail(subject, 'was decided before review closed',
                    'record the decision on or after the day review closed')
            }
            // A recorded fact cannot be in the future. With the window's
            // length no longer gating, this is what keeps a date honest.
            for (const field of ['opened_on', 'review_closed_on', 'decided_on']) {
                if (dates[field] !== undefined && daysBetween(today, dates[field]) > 0) {
                    report.fail(subject,
                        `records \`${field}\` as ${dates[field]}, which has not happened yet`,
                        'every ledger date is a recorded fact; record it on the day it happens')
                }
            }
        } else {
            if (dates.recorded_on === undefined) {
                report.fail(subject, 'is migrated but records no `recorded_on`',
                    'record the date the decision text entered the repository')
            }
            for (const field of ['opened_on', 'review_closed_on', 'decided_on']) {
                if (dates[field] !== undefined) {
                    report.fail(subject, `is migrated but carries \`${field}\``,
                        'a decision that predates this process has no review window; do not invent one')
                }
            }
            if (rfc.document !== undefined) {
                report.fail(subject, 'is migrated but names a proposal document',
                    'a migrated decision points at its existing record through `source`')
            }
        }

        let previousAmendment = ''
        for (const amendment of rfc.amendments ?? []) {
            const amendmentSubject = `\`${rfc.id}/${amendment.id}\``
            if (amendment.id <= previousAmendment) {
                report.fail(amendmentSubject, 'amendments are not in ascending id order',
                    'number amendments in the order they were made')
            }
            previousAmendment = amendment.id
            if (amendment.original_semantics === amendment.delta) {
                report.fail(amendmentSubject, 'records a delta identical to the original semantics',
                    'state what changed; an amendment that changes nothing is not an amendment')
            }
            checkCompatibility(report, amendmentSubject, 'compatibility',
                amendment.compatibility, tracked)
        }
    }

    for (const rfc of registry.rfcs) {
        if (rfc.superseded_by === undefined) continue
        const successor = byId.get(rfc.superseded_by)
        if (successor === undefined) {
            report.fail(`\`${rfc.id}\``, `names the unknown successor \`${rfc.superseded_by}\``,
                'name a decision the ledger records')
        } else if (successor.superseded_by === rfc.id) {
            report.fail(`\`${rfc.id}\``, `and \`${successor.id}\` supersede each other`,
                'one decision replaces the other; a cycle records nothing')
        }
    }

    // The ledger and the documents that carry decision text must agree about
    // which semantics were amended. A reader of the document has to be able to
    // see that it moved, and the ledger may not record an amendment the
    // document never announces.
    const declared = new Set()
    for (const rfc of registry.rfcs) {
        for (const amendment of rfc.amendments ?? []) declared.add(`${rfc.id}/${amendment.id}`)
    }
    const sources = new Set(registry.rfcs.map((rfc) => rfc.source))
    const marked = new Set()
    for (const source of sources) {
        if (!tracked.has(source)) continue
        for (const match of readRepositoryFile(source).matchAll(AMENDMENT_MARKER)) {
            marked.add(match[1])
        }
    }
    for (const amendment of declared) {
        if (!marked.has(amendment)) {
            report.fail(`\`${amendment}\``,
                'is recorded in the ledger but announced in no decision document',
                `write \`${amendment}\` beside the amended decision so a reader of the document sees the semantics moved`)
        }
    }
    for (const amendment of marked) {
        if (!declared.has(amendment)) {
            report.fail(`\`${amendment}\``,
                'is announced in a decision document but recorded in no ledger amendment',
                'add the amendment to the ledger with its delta, the preserved original wording, and its compatibility analysis')
        }
    }

    return report
}

const [mode, argument] = process.argv.slice(2)
if (mode === undefined) usage('usage: validate-registry.mjs <schema|validate> [registry]')

let schema
try {
    schema = JSON.parse(readRepositoryFile(SCHEMA_PATH))
} catch (error) {
    usage(`cannot read ${SCHEMA_PATH}: ${error.message}`)
}

if (mode === 'schema') {
    if (schema.$id === undefined || schema.title === undefined) {
        usage(`${SCHEMA_PATH} must carry an $id and a title`)
    }
    const probe = []
    validateAgainstSchema(schema, schema.$defs.rfc, {}, 'probe', probe)
    if (probe.length === 0) usage('the schema no longer rejects an empty decision')
    process.stdout.write(`PASS: ${SCHEMA_PATH} is a supported schema\n`)
    process.exit(0)
}

if (mode === 'validate') {
    const registryPath = argument ?? REGISTRY_PATH
    let registryText
    try {
        registryText = registryPath.startsWith('/')
            ? readFileSync(registryPath, 'utf8')
            : readRepositoryFile(registryPath)
    } catch (error) {
        usage(`cannot read ${registryPath}: ${error.message}`)
    }
    let registry
    try {
        registry = JSON.parse(registryText)
    } catch (error) {
        process.stderr.write(`${PREFIX}: ${registryPath}: not valid JSON: ${error.message}. Repair: fix the syntax\n`)
        process.exit(1)
    }
    const report = validateRegistry(registry, schema, registryPath)
    if (!report.ok) {
        for (const error of report.errors) process.stderr.write(`${error}\n`)
        process.exit(1)
    }
    const states = registry.rfcs.reduce((counts, rfc) => {
        counts[rfc.state] = (counts[rfc.state] ?? 0) + 1
        return counts
    }, {})
    const summary = Object.entries(states).sort().map(([state, count]) => `${count} ${state}`).join(', ')
    process.stdout.write(`PASS: ${registry.rfcs.length} recorded decisions (${summary})\n`)
    process.exit(0)
}

usage(`unknown mode \`${mode}\``)

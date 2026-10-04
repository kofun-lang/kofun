#!/usr/bin/env node

/*
 * The runtime against the accepted model (#1164).
 *
 *     node tests/conformance/concurrency/runtime/check-model.mjs < driver.stdout
 *
 * The driver prints one `model FIXTURE ...` line per fixture: the scope
 * outcome, the primary failure, and every task's join (kind, outcome,
 * explicit result, discard). This file runs the accepted bounded model on the
 * same program and prints the line the model implies, in the same spelling.
 * The two must be equal.
 *
 * The model input for a fixture is `models/FIXTURE.json` beside this file,
 * or else the spec's own positive fixture of that name. The spec fixtures are
 * read, never copied, so the model and its inputs stay one fact.
 *
 * Joins are sorted as text on both sides. The model orders joins at one step
 * by task id; the runtime joins at scope exit in spawn order. That order is
 * pinned by the driver's golden, so this comparison checks which joins
 * happen and how they end, not their order.
 */

import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { analyzeScopedParallelism } from '../../../../spec/concurrency/scoped-parallelism-v1/model.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..', '..', '..', '..')
const SPEC_FIXTURES = join(ROOT, 'spec', 'concurrency', 'scoped-parallelism-v1', 'fixtures', 'positive')

function fail(message) {
    process.stderr.write(`FAIL: runtime/model: ${message}\n`)
    process.exit(1)
}

function modelInput(fixture) {
    if (!/^[a-z0-9-]+$/.test(fixture)) fail(`fixture name ${JSON.stringify(fixture)}`)
    const own = join(HERE, 'models', `${fixture}.json`)
    if (existsSync(own)) return own
    const spec = join(SPEC_FIXTURES, `${fixture}.json`)
    if (existsSync(spec)) return spec
    fail(`no model input for ${fixture}`)
}

function modelLine(fixture) {
    const result = analyzeScopedParallelism(JSON.parse(readFileSync(modelInput(fixture), 'utf8')))
    if (result.status !== 'accepted') {
        fail(`the model rejects ${fixture}: ${JSON.stringify(result.diagnostics)}`)
    }
    const primary = result.primary_failure === null
        ? '-'
        : result.primary_failure.kind === 'panic'
            ? `panic:${result.primary_failure.task}`
            : result.primary_failure.kind
    const joins = result.joins
        .map((entry) => [
            entry.task,
            entry.kind,
            entry.outcome,
            entry.result ?? '-',
            entry.discarded ? 'discarded' : 'kept',
        ].join(':'))
        .sort()
    return `model ${fixture} outcome=${result.scope_outcome} primary=${primary} joins=${joins.join(',')}`
}

const lines = readFileSync(0, 'utf8').split('\n').filter((line) => line.startsWith('model '))
if (lines.length === 0) fail('the driver printed no model line')
const seen = new Set()
for (const line of lines) {
    const fixture = line.split(' ')[1]
    if (seen.has(fixture)) fail(`two model lines for ${fixture}`)
    seen.add(fixture)
    const expected = modelLine(fixture)
    if (line !== expected) {
        fail(`${fixture} differs from the model\n  runtime: ${line}\n  model:   ${expected}`)
    }
}
process.stdout.write(`PASS: ${lines.length} runtime fixtures agree with the accepted model\n`)

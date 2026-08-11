#!/usr/bin/env node

// Validator and artifact writer for the scheduled-fuzz findings register.
// The tracked register and each failed-run artifact use the same schema, so a
// row cannot become less precise when it is copied from Actions into source.

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { validateAgainstSchema } from '../lib/json-schema.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const SCHEMA_PATH = resolve(ROOT, 'tests/fuzz/findings.schema.json')
const REGISTER_PATH = resolve(ROOT, 'tests/fuzz/findings.json')
const PREFIX = 'scheduled-fuzz-findings'

function fail(message, status = 1) {
    process.stderr.write(`${PREFIX}: ${message}\n`)
    process.exit(status)
}

function usage(message) {
    fail(`${message}\nusage: findings.mjs schema | validate [FILE] | validate-artifact FILE | init FILE | record FILE DATE GENERATOR SEED RUN_ID RUN_ATTEMPT EXIT_STATUS FAILURE_KIND REPRODUCTION EVIDENCE`, 2)
}

function readJson(path) {
    try {
        return JSON.parse(readFileSync(path, 'utf8'))
    } catch (error) {
        fail(`${path}: ${error.message}`)
    }
}

const schema = readJson(SCHEMA_PATH)

function calendarDate(value) {
    const parsed = new Date(`${value}T00:00:00Z`)
    return !Number.isNaN(parsed.valueOf()) && parsed.toISOString().slice(0, 10) === value
}

function validationErrors(document, label, options = {}) {
    const errors = []
    validateAgainstSchema(schema, schema, document, label, errors)
    if (errors.length !== 0) return errors

    const ids = new Set()
    let previousId = ''
    for (const finding of document.findings) {
        if (!calendarDate(finding.date)) {
            errors.push(`${label}: ${finding.id}: date is not a calendar date`)
        }
        const expectedId = `scheduled-fuzz/${finding.run_id}/${finding.run_attempt}/${finding.generator}`
        if (finding.id !== expectedId) {
            errors.push(`${label}: ${finding.id}: expected id ${expectedId}`)
        }
        if (ids.has(finding.id)) errors.push(`${label}: duplicate finding id ${finding.id}`)
        ids.add(finding.id)
        if (finding.id < previousId) {
            errors.push(`${label}: findings must be sorted by id`)
        }
        previousId = finding.id
        if (finding.severity === 'critical' && finding.resolution === 'unresolved') {
            errors.push(`${label}: ${finding.id}: unresolved critical finding blocks the register`)
        }
        if (!options.allowUntriaged && finding.severity === 'untriaged') {
            errors.push(`${label}: ${finding.id}: tracked findings must be triaged`)
        }
    }
    return errors
}

function validate(document, label, options = {}) {
    const errors = validationErrors(document, label, options)
    if (errors.length !== 0) {
        for (const error of errors) process.stderr.write(`${PREFIX}: ${error}\n`)
        process.exit(1)
    }
}

function emptyRegister() {
    return { schema: 'kofun.scheduled-fuzz-findings/v1', findings: [] }
}

function schemaSelfTest() {
    const valid = {
        schema: 'kofun.scheduled-fuzz-findings/v1',
        findings: [{
            id: 'scheduled-fuzz/42/1/grammar',
            date: '2026-08-11',
            generator: 'grammar',
            seed: 42,
            run_id: '42',
            run_attempt: 1,
            exit_status: 1,
            failure_kind: 'generator-exit',
            severity: 'low',
            resolution: 'unresolved',
            reproduction: 'KOFUN_GRAMMAR_FUZZ_SEED=42 sh tests/fuzz/grammar.sh',
            evidence: 'logs/grammar.log',
        }],
    }
    if (validationErrors(valid, 'valid-fixture').length !== 0) {
        fail('schema self-test rejected the valid fixture')
    }
    const missingSeed = structuredClone(valid)
    delete missingSeed.findings[0].seed
    if (!validationErrors(missingSeed, 'missing-seed').some((error) => error.includes('seed'))) {
        fail('schema self-test accepted a finding without a seed')
    }
    const resolvedWithoutNote = structuredClone(valid)
    resolvedWithoutNote.findings[0].resolution = 'resolved'
    if (!validationErrors(resolvedWithoutNote, 'missing-resolution-note').some((error) => error.includes('resolution_note'))) {
        fail('schema self-test accepted a resolved finding without a resolution note')
    }
    const critical = structuredClone(valid)
    critical.findings[0].severity = 'critical'
    if (!validationErrors(critical, 'critical').some((error) => error.includes('unresolved critical'))) {
        fail('validator self-test accepted an unresolved critical finding')
    }
    const untriaged = structuredClone(valid)
    untriaged.findings[0].severity = 'untriaged'
    if (!validationErrors(untriaged, 'untriaged').some((error) => error.includes('must be triaged'))) {
        fail('validator self-test accepted an untriaged row in the tracked register')
    }
    process.stdout.write('PASS: scheduled fuzz finding schema rejects incomplete and unresolved-critical rows\n')
}

const [command, ...args] = process.argv.slice(2)

if (command === 'schema') {
    if (args.length !== 0) usage('schema takes no arguments')
    schemaSelfTest()
} else if (command === 'validate') {
    if (args.length > 1) usage('validate takes at most one file')
    const path = resolve(args[0] ?? REGISTER_PATH)
    validate(readJson(path), path)
    process.stdout.write(`PASS: ${path} is a valid scheduled fuzz findings register\n`)
} else if (command === 'validate-artifact') {
    if (args.length !== 1) usage('validate-artifact requires one file')
    const path = resolve(args[0])
    validate(readJson(path), path, { allowUntriaged: true })
    process.stdout.write(`PASS: ${path} is a valid scheduled fuzz failure artifact\n`)
} else if (command === 'init') {
    if (args.length !== 1) usage('init requires one output file')
    const path = resolve(args[0])
    writeFileSync(path, `${JSON.stringify(emptyRegister(), null, 2)}\n`, { flag: 'wx' })
} else if (command === 'record') {
    if (args.length !== 10) usage('record requires ten arguments')
    const [pathArgument, date, generator, seedText, runId, attemptText, statusText,
        failureKind, reproduction, evidence] = args
    const path = resolve(pathArgument)
    const document = readJson(path)
    document.findings.push({
        id: `scheduled-fuzz/${runId}/${attemptText}/${generator}`,
        date,
        generator,
        seed: Number(seedText),
        run_id: runId,
        run_attempt: Number(attemptText),
        exit_status: Number(statusText),
        failure_kind: failureKind,
        severity: 'untriaged',
        resolution: 'unresolved',
        reproduction,
        evidence,
    })
    document.findings.sort((left, right) => left.id.localeCompare(right.id))
    validate(document, path, { allowUntriaged: true })
    writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`)
} else {
    usage(command === undefined ? 'missing command' : `unknown command ${command}`)
}

#!/usr/bin/env node

/*
 * The standing assertion #1205's last criterion asks for (#1485).
 *
 * What is asserted and what is only reported are deliberately different
 * quantities, and the reason is measured rather than assumed. On this machine
 * `task verify` has taken 3570 s and 1608 s on identical input. A ceiling on a
 * *share of suite wall time* would therefore be a coin flip dressed as a gate:
 * it would fail on a busy afternoon and pass on a quiet one, and the first
 * person to see it fail would raise the ceiling rather than look. So:
 *
 *   asserted  the number of repeated compiles under the codegen key, which is
 *             a function of the tree and of nothing else;
 *   reported  the wall time those repeats cost and its share, with the run's
 *             own suite wall beside it, because that is the quantity #1205
 *             tracked and dropping it would lose the series.
 *
 * The count is what actually catches the regression the criterion names — "a
 * later change that re-splits a shared object family" splits one group into
 * two and the count moves whatever the machine was doing.
 *
 * The ceiling fails in both directions, like
 * `tooling/machine-dependent`'s `unmeasured-ceiling` and
 * `tooling/forbidden-requirements`'s `unknown-ceiling`. Over it, a family was
 * re-split. Under it, the tree improved and nobody recorded the improvement,
 * so the next regression would be measured against a ceiling with slack in it.
 */

import fs from 'node:fs'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import { parseCensus, summarize } from './census.mjs'

export const CEILING_MARKER = '# repeated-ceiling:'

export function readCeiling(text, complain = () => {}) {
    const line = text.split('\n').find((row) => row.startsWith(CEILING_MARKER))
    if (!line) {
        complain(
            `the ledger declares no \`${CEILING_MARKER} N\` line, so a repeated ` +
            'compile has nothing to be too many of',
        )
        return null
    }
    const value = Number.parseInt(line.slice(CEILING_MARKER.length).trim(), 10)
    if (!Number.isInteger(value) || value < 0) {
        complain(`\`${CEILING_MARKER}\` must be a non-negative integer`)
        return null
    }
    return value
}

export const COLUMNS = ['count', 'profile', 'macros', 'sources', 'reason']

export function parseLedger(text, complain = () => {}) {
    const rows = []
    for (const [index, line] of text.split('\n').entries()) {
        if (!line || line.startsWith('#')) continue
        const fields = line.split('\t')
        if (fields.length !== COLUMNS.length) {
            complain(
                `ledger line ${index + 1} has ${fields.length} columns, ` +
                `expected ${COLUMNS.length}`,
            )
            continue
        }
        const row = {}
        COLUMNS.forEach((name, at) => { row[name] = fields[at] })
        rows.push(row)
    }
    return rows
}

/* The ledger's own key, rebuilt from its columns so a row can be matched
 * against a census group without the file having to carry the joined form. */
export function ledgerKey(row) {
    return [row.profile, row.macros, row.sources]
        .map((field) => (field === '-' ? '' : field))
        .join('|')
}

export function evaluate(summary, ledger, ceiling) {
    const problems = []
    const repeated = summary.codegen.repeatedCount
    /*
     * A warm `build/` under-reports, and by a known amount: `bin/kofun` reuses
     * `kofun-module-resolver` across runs, so its compile is missing and the
     * family it belongs to is short. Asserting anyway would tell every second
     * local run to lower a ceiling that is right, which is how a control
     * teaches people to edit it rather than read it. CI starts clean, so the
     * assertion still has somewhere it always runs.
     */
    if (summary.warmLauncherCache) {
        return [
            'SKIP: this census was taken with a warm `build/` — no compile of ' +
            '`kofun-module-resolver` is in it, so `bin/kofun` reused the one ' +
            `from an earlier run. ${repeated} repeats measured against a ` +
            `ceiling of ${ceiling}; the assertion is skipped rather than ` +
            'failed. Remove `build/` to measure, as CI does on every run.',
        ]
    }
    if (ceiling !== null && repeated > ceiling) {
        problems.push(
            `${repeated} repeated compiles under the codegen key, over the ` +
            `recorded ceiling of ${ceiling}; a shared object family was ` +
            're-split, or a new one arrived unshared',
        )
    }
    if (ceiling !== null && repeated < ceiling) {
        problems.push(
            `only ${repeated} repeated compiles against a ceiling of ` +
            `${ceiling}; the tree improved, so lower it and the improvement ` +
            'is recorded rather than becoming slack',
        )
    }
    if (summary.failures !== 0) {
        problems.push(
            `${summary.failures} compile(s) in the census reported a non-zero ` +
            'status; a census over a failed run measures a different tree',
        )
    }

    /* Both directions between the ledger and the run, so a family that stops
     * repeating is noticed as loudly as one that starts. */
    const observed = new Map()
    for (const [key, group] of summary.codegen.groups) {
        if (group.count > 1) observed.set(key, group)
    }
    const recorded = new Map()
    for (const row of ledger) recorded.set(ledgerKey(row), row)

    for (const [key, group] of observed) {
        const row = recorded.get(key)
        if (!row) {
            problems.push(
                `a family repeated ${group.count} times that the ledger does ` +
                `not record: ${key.split('|')[2] || '(no source)'}`,
            )
            continue
        }
        if (Number.parseInt(row.count, 10) !== group.count) {
            problems.push(
                `${key.split('|')[2] || '(no source)'} compiled ` +
                `${group.count} times; the ledger records ${row.count}`,
            )
        }
        if (!row.reason || row.reason === '-' || row.reason.startsWith('UNRECORDED')) {
            problems.push(
                `${key.split('|')[2] || '(no source)'} has no reason; say why ` +
                'this family is still compiled more than once',
            )
        }
    }
    for (const key of recorded.keys()) {
        if (!observed.has(key)) {
            problems.push(
                'the ledger records a repeated family that this run did not ' +
                `produce: ${key.split('|')[2] || '(no source)'}`,
            )
        }
    }
    return problems
}

export function report(summary, suiteWallNs) {
    const ms = (ns) => (ns / 1e6).toFixed(1)
    const lines = [
        `MEASURE: compile census ${summary.invocations} invocations, ` +
        `${summary.compiles} compiles, ${summary.ephemeral} of run-scoped ` +
        `sources, ${summary.links} pure links, ${summary.failures} failed, ` +
        `${summary.flagProfiles} codegen profiles`,
        `MEASURE: compile census codegen key ${summary.codegen.distinct} ` +
        `distinct, ${summary.codegen.repeatedCount} repeated, ` +
        `${ms(summary.codegen.repeatedWallNs)} ms repeated compiler wall`,
        `MEASURE: compile census verbatim-argv key ` +
        `${summary.verbatim.distinct} distinct, ` +
        `${summary.verbatim.repeatedCount} repeated, ` +
        `${ms(summary.verbatim.repeatedWallNs)} ms repeated compiler wall`,
    ]
    if (suiteWallNs && Number.isFinite(suiteWallNs) && suiteWallNs > 0) {
        const share = (summary.codegen.repeatedWallNs / suiteWallNs) * 100
        lines.push(
            `MEASURE: compile census repeated share ${share.toFixed(1)}% of ` +
            `${(suiteWallNs / 1e9).toFixed(1)} s suite wall on this run ` +
            '(reported, not asserted: suite wall on this machine has measured ' +
            '3570 s and 1608 s for identical input)',
        )
    } else {
        lines.push(
            'MEASURE: compile census repeated share unavailable; the run did ' +
            'not report its suite wall',
        )
    }
    /* The two keys side by side, always. The umbrella measured them 9x apart
     * and reported the understating one first. */
    const ratio = summary.verbatim.repeatedWallNs > 0
        ? summary.codegen.repeatedWallNs / summary.verbatim.repeatedWallNs
        : null
    lines.push(
        'MEASURE: compile census key disagreement ' +
        (ratio === null
            ? 'the verbatim key found no repeats at all'
            : `codegen/verbatim = ${ratio.toFixed(1)}x on this run`),
    )
    return lines
}

/*
 * The candidate ledger, derived from a census rather than typed.
 *
 * The reason column is derived too, and its derivation is the check: a family
 * repeats because more than one gate compiles that source set, so the reason
 * names the gate scripts that mention its driver. `tooling/gate-reachability`
 * and `tooling/forbidden-requirements` both regenerate this way and both
 * refuse a pasted row with no reason; this one cannot produce a reasonless row
 * because the derivation either finds owners or says it found none.
 */
export function candidateLedger(summary, ownersOf) {
    const rows = []
    const families = [...summary.codegen.groups.entries()]
        .filter(([, group]) => group.count > 1)
        .sort((a, b) => b[1].wallNs - a[1].wallNs)
    for (const [key, group] of families) {
        const [profile, macros, sources] = key.split('|')
        const owners = ownersOf(sources.split(' '))
        const reason = owners.length > 1
            ? `compiled by ${owners.length} gates: ${owners.join(' ')}`
            : owners.length === 1
                ? `compiled once per case by ${owners[0]}`
                : 'NO OWNER FOUND — name the gate that compiles this set'
        rows.push([
            String(group.count),
            profile || '-',
            macros || '-',
            sources,
            reason,
        ].join('\t'))
    }
    return rows
}

function main() {
    const censusPath = process.env.KOFUN_COMPILE_CENSUS_LOG
    if (!censusPath) {
        process.stdout.write(
            'SKIP: compile census: KOFUN_COMPILE_CENSUS_LOG is unset; this ' +
            'gate reads the completed census a full verify run produces\n',
        )
        return
    }
    if (!fs.existsSync(censusPath)) {
        process.stderr.write(
            `FAIL: compile census: no census at ${censusPath}\n`,
        )
        process.exit(1)
    }
    const rows = parseCensus(fs.readFileSync(censusPath, 'utf8'))
    /* The gates pass absolute `$ROOT/...` paths, so the key is relativized
     * against this checkout before it reaches the ledger. */
    const root = fileURLToPath(new URL('../..', import.meta.url)).replace(/\/$/, '')
    const summary = summarize(rows, root)

    if (process.argv.includes('--regenerate')) {
        const gateScripts = []
        const walk = (directory) => {
            for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
                const at = `${directory}/${entry.name}`
                if (entry.isDirectory()) walk(at)
                else if (entry.name === 'run.sh' || entry.name === 'check.sh') {
                    gateScripts.push(at)
                }
            }
        }
        walk(`${root}/tests`)
        const ownersOf = (sources) => {
            /* The driver is the source no other family shares — in practice
             * the one that is not a common role. Matching on every source and
             * keeping the gates that name the rarest one keeps this from
             * reporting "every gate that mentions sha256.c". */
            const rarest = sources
                .map((source) => ({
                    source,
                    gates: gateScripts.filter((script) =>
                        fs.readFileSync(script, 'utf8').includes(source.split('/').pop())),
                }))
                .filter((entry) => entry.gates.length > 0)
                .sort((a, b) => a.gates.length - b.gates.length)[0]
            return (rarest?.gates ?? []).map((gate) => gate.slice(root.length + 1))
        }
        for (const line of candidateLedger(summary, ownersOf)) {
            process.stdout.write(`${line}\n`)
        }
        return
    }

    const ledgerPath = new URL('./ledger.tsv', import.meta.url)
    const ledgerText = fs.readFileSync(ledgerPath, 'utf8')
    const problems = []
    const ceiling = readCeiling(ledgerText, (message) => problems.push(message))
    const ledger = parseLedger(ledgerText, (message) => problems.push(message))
    problems.push(...evaluate(summary, ledger, ceiling))

    const suiteWallNs = Number.parseInt(
        process.env.KOFUN_COMPILE_CENSUS_SUITE_WALL_NS ?? '',
        10,
    )
    for (const line of report(summary, suiteWallNs)) {
        process.stdout.write(`${line}\n`)
    }
    /* The warm-cache case is one entry and it is not a failure. It is
     * returned through the same channel so a caller cannot act on the numbers
     * without seeing it. */
    if (problems.length === 1 && problems[0].startsWith('SKIP:')) {
        process.stdout.write(`${problems[0].slice(6)}\n`)
        process.stdout.write(
            'SKIP: compile census: the ceiling is asserted on a clean tree\n',
        )
        return
    }
    if (problems.length) {
        for (const problem of problems) {
            process.stderr.write(`FAIL: compile census: ${problem}\n`)
        }
        process.exit(1)
    }
    process.stdout.write(
        `PASS: ${summary.compiles} compiles, ${summary.codegen.repeatedCount} ` +
        'repeated under the codegen key and every one of them recorded with a ' +
        'reason; the share of suite wall is reported beside the count that ' +
        'is asserted\n',
    )
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main()

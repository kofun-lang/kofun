#!/usr/bin/env node

/*
 * The ledger of bounds whose verdict can depend on how busy the machine is
 * (#1472), and the checker that keeps it true in both directions.
 *
 *     node tooling/machine-dependent/check.mjs              # check
 *     node tooling/machine-dependent/check.mjs --count      # regenerate rows
 *     node tooling/machine-dependent/check.mjs --predicates # print the searches
 *
 * FAILS IN BOTH DIRECTIONS, like `tooling/gate-reachability/unreachable.tsv`
 * and `tooling/forbidden-requirements/census.tsv`. A site with no row is a
 * bound that arrived unrecorded. A row with no site is the direction that
 * matters more: the fix for these rows is to stop being time-dependent, and
 * without the reverse check nothing notices when one does, so the ledger rots
 * into a list of things that used to be true.
 *
 * CLASSIFY BY MARGIN, NOT BY CLOCK. #1472 took three corrections to reach
 * that, and it is why this checker computes headroom rather than sorting on
 * the unit. `hover p95 < 2` reads a wall clock and has 66x headroom; the
 * `decode/index p95 < 75` assertion three lines below it reads the same clock
 * and has ranged 9.93 to 92.14ms in one day; `DIAGNOSTIC_MAX_CPU_MS = 145`
 * reads a CPU clock and still failed at 148.91. A ledger that sorted
 * wall-clock-bad and CPU-fine would mark the last one safe.
 *
 * So a `verdict` row must carry an observation, and the summary reports how
 * many verdicts have less than 2x headroom. That number is the finding; the
 * total is not.
 */

import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { DETECTORS, FILE_SET, detect, toMilliseconds } from './detect.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '../..')
const LEDGER = path.join(HERE, 'ledger.tsv')

/*
 * What a row may say about a site. Closed, so a typo is a failure rather than
 * a silently unenforced class.
 *
 *   verdict     the bound IS the assertion; exceeding it fails the gate. Must
 *               carry an observation, because "passed once" and "has margin"
 *               are different claims and only the second tolerates it.
 *   unmeasured  verdict-shaped, and nobody has recorded its range. NOT the safe
 *               cell: it means the category is unknown, and #1472's three
 *               categories cannot be told apart without a measurement. It
 *               exists so the honest answer is countable rather than forcing a
 *               number nobody took.
 *   backstop    a bound that exists to stop a hang, set far above the expected
 *               cost, and the reason says what that cost is.
 *   indirect    the bound here is a variable; another row holds the literal,
 *               and `evidence` names it.
 *   runtime     product code — a debounce, a poll interval, a lock wait. It
 *               cannot fail a build by being slow.
 *   domain      a duration in the problem domain rather than a measurement of
 *               this run. A UTC offset bound is not a machine dependency.
 */
export const CLASSES = Object.freeze([
    'verdict', 'unmeasured', 'backstop', 'indirect', 'runtime', 'domain',
])
const CLASS_SET = new Set(CLASSES)
const THIN_MARGIN = 2

export const COLUMNS = Object.freeze([
    'site', 'file', 'count', 'bound', 'observed', 'class', 'evidence', 'reason',
])

function die(message) {
    process.stderr.write(`FAIL: machine-dependent: ${message}\n`)
    process.exit(1)
}

/*
 * `92.14ms@load20` — a number, a unit, and the load average it was taken at.
 * The load is required rather than decorative: a single observation of a
 * load-sensitive quantity says nothing about its range, and one taken on a
 * quiet box says least of all. Recording the conditions is what stops a
 * favourable number from being read as a margin.
 */
export function parseObservation(text) {
    const match = /^(\d+(?:\.\d+)?(?:ms|s|m))@load(\d+(?:\.\d+)?)$/.exec(String(text))
    if (match === null) return null
    return { milliseconds: toMilliseconds(match[1]), load: Number(match[2]) }
}

export function marginOf(row) {
    const bound = toMilliseconds(row.bound)
    const observed = parseObservation(row.observed)
    if (bound === null || observed === null || observed.milliseconds === 0) return null
    return bound / observed.milliseconds
}

/*
 * A declared bound on the one class that means "nobody knows".
 *
 * Every other rule here catches a row that is *wrong*. None of them catches a
 * row that is honestly unclassifiable, because `unmeasured` is a legitimate
 * answer and a new row is the ordinary flow — so a verdict-shaped bound with
 * no measurement would arrive looking like every other addition while the
 * headline got quietly less true. That is the failure #1472 was filed about,
 * one level up, committed by the ledger meant to prevent it.
 *
 * Bounded in both directions the way `tooling/forbidden-requirements`'s
 * `unknown-ceiling` (#1474) and `tests/assertions/budget.tsv` are: over is
 * drift, under is an improvement nobody recorded. Measuring one of these and
 * leaving the ceiling alone is exactly the reverse-direction rot this ledger
 * exists to refuse.
 */
export function readCeiling(text, onError = die) {
    const match = /^#\s*unmeasured-ceiling:\s*(\d+)\s*$/m.exec(text)
    if (match === null) {
        onError('ledger.tsv declares no `# unmeasured-ceiling: N`, so the one class ' +
            'that means "nobody knows the range" has no bound and a new unmeasured ' +
            'bound would arrive as an ordinary row')
        return null
    }
    return Number(match[1])
}

export function parseLedger(text, onError = die) {
    const rows = new Map()
    for (const [index, line] of text.split('\n').entries()) {
        if (line.startsWith('#') || line.trim() === '') continue
        const fields = line.split('\t')
        if (fields.length !== COLUMNS.length) {
            onError(`ledger line ${index + 1} has ${fields.length} fields; expected ${COLUMNS.length}`)
            continue
        }
        const row = Object.fromEntries(COLUMNS.map((name, at) => [name, fields[at]]))
        row.line = index + 1
        const key = `${row.site}\t${row.file}\t${row.bound}`
        if (rows.has(key)) onError(`ledger has two rows for ${key.replace(/\t/g, ' ')}`)
        rows.set(key, row)
    }
    return rows
}

/*
 * Every rule in one exported function, so `self-test.mjs` drives them over
 * synthetic ledgers instead of the repository. A checker whose rules only run
 * against the real tree can only be tested by breaking the real tree.
 */
export function evaluate(found, ledger, ceiling = null) {
    const problems = []

    const unmeasured = [...ledger.values()].filter((row) => row.class === 'unmeasured')
    if (ceiling !== null && unmeasured.length > ceiling) {
        problems.push(
            `${unmeasured.length} rows are \`unmeasured\` and ledger.tsv declares a ` +
            `ceiling of ${ceiling}. A verdict-shaped bound nobody has measured may not ` +
            'arrive as an ordinary row: measure it and record the observation with its ' +
            'load, or raise the ceiling deliberately, in the same commit, with the reason',
        )
    }
    if (ceiling !== null && unmeasured.length < ceiling) {
        problems.push(
            `only ${unmeasured.length} rows are \`unmeasured\` and ledger.tsv still ` +
            `declares a ceiling of ${ceiling}; lower it so the measurement is recorded`,
        )
    }

    for (const [key, site] of found) {
        const row = ledger.get(key)
        if (row === undefined) {
            problems.push(
                `${site.path} bounds ${site.bound} at line ${site.lines.join(', ')} ` +
                `(${site.site}) and ledger.tsv does not record it. Regenerate with ` +
                '`--count`, then classify the new row — a bound whose verdict can ' +
                'depend on the machine may not arrive unrecorded',
            )
            continue
        }
        if (String(site.count) !== String(row.count)) {
            problems.push(
                `${row.file} has ${site.count} ${row.site} sites bounding ${row.bound}, ` +
                `and ledger.tsv line ${row.line} records ${row.count}`,
            )
        }
    }

    for (const [key, row] of ledger) {
        if (!found.has(key)) {
            problems.push(
                `ledger.tsv line ${row.line} records ${row.site} ${row.bound} in ` +
                `${row.file}, and no such site exists. If the time dependency was ` +
                'removed, remove the row: a ledger that keeps rows for bounds that ' +
                'are gone stops describing the tree',
            )
        }
    }

    for (const row of ledger.values()) {
        if (!CLASS_SET.has(row.class)) {
            problems.push(
                `ledger.tsv line ${row.line} has class \`${row.class}\`, not one of ` +
                `${CLASSES.join(', ')}`,
            )
        }
        if (row.reason.trim() === '' || row.reason.startsWith('UNCLASSIFIED')) {
            problems.push(`ledger.tsv line ${row.line} has no reason`)
        }
        if (row.class === 'verdict' && parseObservation(row.observed) === null) {
            problems.push(
                `ledger.tsv line ${row.line} is a verdict with no observation. A ` +
                'verdict claims the bound holds, and that claim needs a measurement ' +
                'and the load it was taken at — `92.14ms@load20`, not a bare number',
            )
        }
        if (row.class === 'indirect' && row.evidence.trim() === '-') {
            problems.push(
                `ledger.tsv line ${row.line} is indirect and names no row holding ` +
                'the literal bound',
            )
        }
    }

    return problems
}

/*
 * The counts that matter are named, not buried in the total. Thirty sites and
 * six findings are different facts, and a summary that says only "30 rows"
 * reports the wrong one.
 */
export function summarize(ledger, ceiling = null) {
    const byClass = new Map(CLASSES.map((name) => [name, 0]))
    for (const row of ledger.values()) byClass.set(row.class, (byClass.get(row.class) ?? 0) + 1)
    const verdicts = [...ledger.values()].filter((row) => row.class === 'verdict')
    const thin = verdicts.filter((row) => {
        const margin = marginOf(row)
        return margin !== null && margin < THIN_MARGIN
    })
    /*
     * "0 thin verdicts" is a good headline and an ambiguous one: it reads the
     * same whether every verdict has margin or whether there are no verdicts
     * left because they were all classified `unmeasured`. Naming the
     * denominator, and saying so outright when it is zero, keeps the two apart.
     */
    const thinLine = verdicts.length === 0
        ? 'PASS: no rows are classified `verdict`, so no headroom was computed — ' +
          'check the unmeasured count below before reading that as good news'
        : `PASS: ${thin.length} of ${verdicts.length} verdicts have less than ` +
          `${THIN_MARGIN}x headroom over their worst recorded observation` +
          (thin.length === 0 ? '' : `: ${thin.map((row) => `${row.file} ${row.bound}`).join(', ')}`)
    return [
        `PASS: ${ledger.size} bounds recorded — ` +
        CLASSES.map((name) => `${byClass.get(name)} ${name}`).join(', '),
        thinLine,
        `PASS: ${byClass.get('unmeasured')}${ceiling === null ? '' : ` of ${ceiling} allowed`} ` +
        'verdict-shaped bounds have no recorded range, so whether each is a backstop ' +
        'or a threshold without margin is unknown',
    ]
}

function repositoryFiles() {
    const paths = execFileSync(
        'git',
        ['ls-files', '*.sh', '*.mjs', '*.js'],
        { cwd: ROOT, encoding: 'utf8' },
    ).split('\n').filter(Boolean)
    return paths.map((file) => [file, readFileSync(path.join(ROOT, file), 'utf8')])
}

/*
 * Runs only when this file is the program. `self-test.mjs` imports the rules
 * to drive them over fixtures, and an import that scanned the repository and
 * called `process.exit` would make that impossible.
 */
function main() {
    if (process.argv.includes('--predicates')) {
        process.stdout.write(`${FILE_SET}\n\n`)
        for (const detector of DETECTORS) {
            process.stdout.write(
                `${detector.site} — ${detector.describes}\n  ${detector.predicate}\n`,
            )
        }
        return
    }

    const found = detect(repositoryFiles())

    if (process.argv.includes('--count')) {
        let previous = new Map()
        try {
            previous = parseLedger(readFileSync(LEDGER, 'utf8'), () => {})
        } catch {
            previous = new Map()
        }
        const lines = []
        for (const key of [...found.keys()].sort()) {
            const site = found.get(key)
            const kept = previous.get(key)
            lines.push([
                site.site,
                site.path,
                site.count,
                site.bound,
                kept?.observed ?? '-',
                kept?.class ?? 'unmeasured',
                kept?.evidence ?? '-',
                kept?.reason ?? 'UNCLASSIFIED — state what this bound is and why it is tolerated',
            ].join('\t'))
        }
        process.stdout.write(`${lines.join('\n')}\n`)
        return
    }

    const ledgerText = readFileSync(LEDGER, 'utf8')
    const ledger = parseLedger(ledgerText)
    const ceiling = readCeiling(ledgerText)
    const problems = evaluate(found, ledger, ceiling)
    if (problems.length > 0) {
        for (const problem of problems) {
            process.stderr.write(`FAIL: machine-dependent: ${problem}\n`)
        }
        process.exit(1)
    }
    for (const line of summarize(ledger, ceiling)) process.stdout.write(`${line}\n`)
}

if (process.argv[1] !== undefined &&
    path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    main()
}

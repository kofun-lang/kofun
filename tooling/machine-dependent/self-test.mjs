#!/usr/bin/env node

/*
 * Negative self-tests for the machine-dependent ledger (#1472).
 *
 * The ledger's whole value is that it fails in both directions, so both
 * directions are proved here rather than asserted in a comment. Every case
 * drives the real detectors and the real rules over a fixture, because a
 * checker tested only against the repository can only be tested by breaking
 * the repository.
 *
 * The detector cases exist because this file's own searches were wrong three
 * times before they were right, each time in a way that made the count smaller
 * and looked exactly like a clean tree:
 *
 *   - block-comment stripping swallowed 395 lines and with them all six CPU
 *     budgets, reporting zero of the sites the detector exists to find;
 *   - `MS` as a bare alternative matched `MAX_COMPLETION_ITEMS`;
 *   - `MILLISECONDS` ends in `SECONDS`, so a 2000 ms lock wait read as 2000 s;
 *   - a `${OVERRIDE:-10}` default was invisible, hiding the bound that governs
 *     every run nobody overrides.
 *
 * Each of those is pinned below. A search that silently narrows is the failure
 * this ledger is supposed to prevent, and it is the failure the ledger's own
 * tooling is most likely to commit.
 */

import assert from 'node:assert/strict'

import { detect, toMilliseconds, unitOf } from './detect.mjs'
import {
    COLUMNS, evaluate, marginOf, parseLedger, readCeiling, summarize,
} from './check.mjs'

let checks = 0
function check(name, fn) {
    fn()
    checks += 1
    process.stdout.write(`PASS [machine-dependent-negative] ${name}\n`)
}

const row = (fields) => COLUMNS.map((name) => fields[name] ?? '-').join('\t')
const ledgerOf = (...rows) => parseLedger(rows.join('\n'), (message) => {
    throw new Error(message)
})

// ---------------------------------------------------------------- detectors

check('a line comment containing a block-comment opener does not hide the code below it', () => {
    /*
     * The exact shape from `tests/lsp/performance_test.js`: a `//` comment
     * mentioning a glob path, and a budget many lines below it. Stripping block
     * comments first pairs that opener with a closer far below and deletes
     * everything between.
     */
    const body = [
        '// summing over task/* rather than reading the process entry',
        'const FILLER = 1;',
        'const DIAGNOSTIC_MAX_CPU_MS = 145;',
        'const TAIL = `/proc/<pid>/task/*/schedstat`;',
    ].join('\n')
    const found = detect([['probe.js', body]])
    const budgets = [...found.values()].filter((site) => site.site === 'duration-budget')
    assert.equal(budgets.length, 1, 'the budget below the comment must still be found')
    assert.equal(budgets[0].bound, '145ms')
    assert.deepEqual(budgets[0].lines, [3], 'line numbers must survive stripping')
})

check('a name that merely contains a unit is not a duration', () => {
    const found = detect([['probe.js', [
        'const MAX_COMPLETION_ITEMS = 50;',
        'const CABI_MAX_PARAMS = 16;',
    ].join('\n')]])
    assert.equal(found.size, 0, 'ITEMS and PARAMS end in MS but count things, not time')
})

check('MILLISECONDS is not SECONDS', () => {
    assert.equal(unitOf('LOCK_WAIT_MILLISECONDS'), 'ms')
    assert.equal(unitOf('TIMEOUT_SECONDS'), 's')
    const found = detect([['probe.js', 'const LOCK_WAIT_MILLISECONDS = 2000;']])
    assert.equal([...found.values()][0].bound, '2000ms', 'a 2 s bound would be 1000x wrong')
})

check('a shell default is a bound, not the absence of one', () => {
    const found = detect([['probe.sh', 'TIMEOUT_SECONDS=${KOFUN_SEMANTIC_TIMEOUT:-10}']])
    assert.equal([...found.values()][0].bound, '10s')
})

check('prose about a timeout is not a timeout', () => {
    const found = detect([['probe.sh', [
        '# expected exit 124 is reserved for the timeout harness',
        'printf "%s" "the timeout harness"',
    ].join('\n')]])
    assert.equal(found.size, 0)
})

check('a bare timeout number is seconds', () => {
    const found = detect([['probe.sh', 'timeout 120 "$KOFUN" run "$case"']])
    assert.equal([...found.values()][0].bound, '120s')
    assert.equal(toMilliseconds('120s'), 120000)
})

// ------------------------------------------------------------------- rules

const oneSite = () => detect([['probe.js', 'const HOVER_P95_MS = 2;']])

check('a site with no row is refused', () => {
    const problems = evaluate(oneSite(), ledgerOf())
    assert.equal(problems.length, 1)
    assert.match(problems[0], /does not record it/)
})

check('a row with no site is refused — the direction that keeps the ledger true', () => {
    const problems = evaluate(new Map(), ledgerOf(row({
        site: 'duration-budget',
        file: 'probe.js',
        count: '1',
        bound: '2ms',
        observed: '0.03ms@load20',
        class: 'verdict',
        reason: 'removed upstream',
    })))
    assert.equal(problems.length, 1)
    assert.match(problems[0], /no such site exists/)
})

check('a changed number of sites is refused', () => {
    const problems = evaluate(oneSite(), ledgerOf(row({
        site: 'duration-budget',
        file: 'probe.js',
        count: '4',
        bound: '2ms',
        observed: '0.03ms@load20',
        class: 'verdict',
        reason: 'four of them',
    })))
    assert.equal(problems.length, 1)
    assert.match(problems[0], /records 4/)
})

check('a class outside the vocabulary is refused', () => {
    const problems = evaluate(oneSite(), ledgerOf(row({
        site: 'duration-budget',
        file: 'probe.js',
        count: '1',
        bound: '2ms',
        observed: '0.03ms@load20',
        class: 'probably-fine',
        reason: 'a class nobody defined',
    })))
    assert.equal(problems.length, 1)
    assert.match(problems[0], /not one of/)
})

check('a verdict with no observation is refused', () => {
    const problems = evaluate(oneSite(), ledgerOf(row({
        site: 'duration-budget',
        file: 'probe.js',
        count: '1',
        bound: '2ms',
        class: 'verdict',
        reason: 'it passes',
    })))
    assert.equal(problems.length, 1)
    assert.match(problems[0], /verdict with no observation/)
})

check('an observation without its load is refused', () => {
    const problems = evaluate(oneSite(), ledgerOf(row({
        site: 'duration-budget',
        file: 'probe.js',
        count: '1',
        bound: '2ms',
        observed: '0.03ms',
        class: 'verdict',
        reason: 'measured once, conditions unrecorded',
    })))
    assert.equal(problems.length, 1)
    assert.match(problems[0], /needs a measurement/)
})

check('an indirect row naming no holder is refused', () => {
    const problems = evaluate(oneSite(), ledgerOf(row({
        site: 'duration-budget',
        file: 'probe.js',
        count: '1',
        bound: '2ms',
        class: 'indirect',
        reason: 'the literal is elsewhere',
    })))
    assert.equal(problems.length, 1)
    assert.match(problems[0], /names no row holding/)
})

check('an unreasoned row is refused', () => {
    const problems = evaluate(oneSite(), ledgerOf(row({
        site: 'duration-budget',
        file: 'probe.js',
        count: '1',
        bound: '2ms',
        observed: '0.03ms@load20',
        class: 'verdict',
        reason: 'UNCLASSIFIED — state what this bound is and why it is tolerated',
    })))
    assert.equal(problems.length, 1)
    assert.match(problems[0], /has no reason/)
})

/*
 * The unmeasured ceiling. `unmeasured` is the one class that is a legitimate
 * answer rather than a mistake, so no other rule here can catch a row that
 * arrives in it — which would make it the place wrong answers go, one level up
 * from the failure #1472 is about. Bounded in both directions, like
 * `tooling/forbidden-requirements`'s `unknown-ceiling`.
 */
const unmeasuredRow = (file) => row({
    site: 'duration-budget',
    file,
    count: '1',
    bound: '2ms',
    class: 'unmeasured',
    reason: 'nobody has measured this one',
})

check('more unmeasured rows than declared is refused', () => {
    const ledger = ledgerOf(unmeasuredRow('a.js'), unmeasuredRow('b.js'))
    const problems = evaluate(new Map(), ledger, 1)
    assert.equal(problems.some((p) => /2 rows are `unmeasured`.*ceiling of 1/.test(p)), true)
})

check('fewer unmeasured rows than declared is refused — the improvement must be recorded', () => {
    const ledger = ledgerOf(unmeasuredRow('a.js'))
    const problems = evaluate(new Map(), ledger, 3)
    assert.equal(problems.some((p) => /only 1 rows are `unmeasured`.*lower it/.test(p)), true)
})

check('a ledger declaring no ceiling is refused', () => {
    let complaint = null
    const value = readCeiling('# site\tfile\n', (message) => { complaint = message })
    assert.equal(value, null)
    assert.match(complaint, /declares no `# unmeasured-ceiling/)
})

check('the declared ceiling is read from the ledger text', () => {
    assert.equal(readCeiling('# unmeasured-ceiling: 5\n'), 5)
})

/*
 * The must-not-fire direction. Every rule above reports a problem; a checker
 * that reported one for a correct ledger would be useless in the other
 * direction, and none of the cases above can tell the difference.
 */
check('a consistent ledger is accepted', () => {
    const problems = evaluate(oneSite(), ledgerOf(row({
        site: 'duration-budget',
        file: 'probe.js',
        count: '1',
        bound: '2ms',
        observed: '0.03ms@load20',
        class: 'verdict',
        evidence: 'measured on a busy box',
        reason: '66x headroom on the worst recorded number',
    })))
    assert.deepEqual(problems, [])
})

// ------------------------------------------------------------------ margin

check('margin is computed across units and clocks alike', () => {
    assert.equal(marginOf({ bound: '10s', observed: '5000ms@load3' }), 2)
    assert.equal(marginOf({ bound: '145ms', observed: '148.91ms@load20.5' }) < 1, true)
    assert.equal(marginOf({ bound: '2ms', observed: '-' }), null)
})

check('the summary names the findings, not just the total', () => {
    const ledger = ledgerOf(
        row({
            site: 'duration-budget',
            file: 'thin.js',
            count: '1',
            bound: '145ms',
            observed: '148.91ms@load20.5',
            class: 'verdict',
            reason: 'has failed',
        }),
        row({
            site: 'duration-budget',
            file: 'roomy.js',
            count: '1',
            bound: '2ms',
            observed: '0.03ms@load20',
            class: 'verdict',
            reason: '66x headroom',
        }),
        row({
            site: 'timeout-command',
            file: 'hang.sh',
            count: '1',
            bound: '120s',
            class: 'backstop',
            reason: 'guards a non-terminating loop',
        }),
    )
    const lines = summarize(ledger, 0)
    assert.match(lines[0], /3 bounds recorded/)
    assert.match(lines[1], /1 of 2 verdicts/)
    assert.match(lines[1], /thin\.js 145ms/)
    assert.doesNotMatch(lines[1], /roomy\.js/)
    assert.match(lines[2], /0 of 0 allowed/)
})

check('a summary with no verdicts says so rather than reading as good news', () => {
    const lines = summarize(ledgerOf(unmeasuredRow('only.js')), 1)
    assert.match(lines[1], /no rows are classified `verdict`/)
    assert.doesNotMatch(lines[1], /^PASS: 0 of 0 verdicts/)
})

process.stdout.write(
    `PASS: ${checks} negative self-tests; the ledger fails in both directions ` +
    'and its searches refuse the four narrowings that produced a smaller count\n',
)

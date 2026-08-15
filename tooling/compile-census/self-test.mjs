#!/usr/bin/env node

/*
 * Negative self-tests for the compile census (#1485).
 *
 * The census is a key, and every way it can be wrong is a way of grouping
 * compiles that answers a different question while looking like an answer to
 * this one. #1205's own census measured its two candidate keys 9x apart on one
 * run — 1.8% against 16.0% — and reported the understating one first. So the
 * cases below are mostly about the key, and each names the mistake it pins:
 *
 *   - the output path is unique per gate, so a key that keeps it reports two
 *     identical objects as different work;
 *   - two invocations listing the same sources in a different order compile
 *     the same thing;
 *   - `-D` is the difference that must never be flattened, because it is what
 *     makes two otherwise identical compiles genuinely different objects;
 *   - a warning or include flag is not codegen, and folding it in re-splits
 *     families that share an object.
 *
 * The ceiling cases prove the gate fails in both directions, and the last case
 * proves it does not fire on a correct ledger — a checker that reported a
 * problem for an honest run would be useless in the other direction and none
 * of the cases above can tell the difference.
 */

import assert from 'node:assert/strict'

import {
    codegenKey, decodeArgv, isCompile, isSource, relativize, repeatedWork,
    summarize, verbatimKey,
} from './census.mjs'
import {
    COLUMNS, candidateLedger, evaluate, ledgerKey, parseLedger, readCeiling,
} from './check.mjs'

let checks = 0
function check(name, fn) {
    fn()
    checks += 1
    process.stdout.write(`PASS [compile-census-negative] ${name}\n`)
}

const hex = (argv) => Buffer.from(argv.map((a) => `${a}\0`).join(''), 'utf8')
    .toString('hex')

const row = (argv, wallNs = 1_000_000, status = '0') =>
    `cc\tclass=other\tstatus=${status}\targv_hex=${hex(argv)}\twall_ns=${wallNs}`

const ledgerRow = (fields) => COLUMNS.map((name) => fields[name] ?? '-').join('\t')

// ------------------------------------------------------------------- the key

check('the output path does not make two identical objects different work', () => {
    const a = ['cc', '-std=c11', '-O2', '-c', 'src/x.c', '-o', 'build/one/x.o']
    const b = ['cc', '-std=c11', '-O2', '-c', 'src/x.c', '-o', 'build/two/x.o']
    assert.equal(codegenKey(a), codegenKey(b), 'same object, same key')
    assert.notEqual(verbatimKey(a), verbatimKey(b),
        'the verbatim key is expected to disagree; that is the 9x')
})

check('an output path is not read as a source', () => {
    /* `-o out.c` is legal and the suffix matches. Without skipping the value
     * of `-o` the output would join the source set and every compile would
     * look unique — the same understatement as keeping the whole argv, but
     * arriving through a key that claims not to. */
    const key = codegenKey(['cc', '-c', 'src/x.c', '-o', 'build/generated.c'])
    assert.equal(key.split('|')[2], 'src/x.c')
})

check('an include directory is not read as a source or as codegen', () => {
    const withInclude = ['cc', '-std=c11', '-O2', '-I', 'vendor', '-c', 'src/x.c']
    const without = ['cc', '-std=c11', '-O2', '-c', 'src/x.c']
    assert.equal(codegenKey(withInclude), codegenKey(without))
})

check('source order does not split a family', () => {
    const a = ['cc', '-O2', 'a.c', 'b.c']
    const b = ['cc', '-O2', 'b.c', 'a.c']
    assert.equal(codegenKey(a), codegenKey(b))
})

check('a -D macro splits a family, and must', () => {
    const plain = ['cc', '-O2', '-c', 'src/p.c']
    const library = ['cc', '-O2', '-DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY', '-c', 'src/p.c']
    assert.notEqual(codegenKey(plain), codegenKey(library),
        'two objects with different macros are different objects')
})

check('optimisation, sanitizer, and analyzer settings split a family', () => {
    const base = ['cc', '-c', 'src/x.c']
    const keys = new Set([
        codegenKey([...base, '-O0']),
        codegenKey([...base, '-O2']),
        codegenKey([...base, '-O2', '-fsanitize=address,undefined']),
        codegenKey([...base, '-O0', '-fanalyzer']),
        codegenKey([...base, '-O2', '-fPIC']),
    ])
    assert.equal(keys.size, 5, 'each of these produces a different object')
})

check('a warning flag does not split a family', () => {
    const quiet = ['cc', '-std=c11', '-O2', '-c', 'src/x.c']
    const loud = ['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-pedantic', '-c', 'src/x.c']
    assert.equal(codegenKey(quiet), codegenKey(loud),
        'warnings change what is reported, not what is emitted')
})

check('an absolute path is keyed relative to the checkout', () => {
    /* The gates pass `$ROOT/...`, so an un-relativized key describes one
     * worktree: the ledger would be unreadable by anyone else and would change
     * when the checkout moved, which is a property of the reader. */
    const root = '/home/someone/kofun'
    const argv = ['cc', '-O2', '-c', `${root}/bootstrap/stage2/sha256.c`]
    assert.equal(codegenKey(argv, root).split('|')[2], 'bootstrap/stage2/sha256.c')
    assert.equal(relativize('/elsewhere/x.c', root), '/elsewhere/x.c')
})

check('a pure link is not counted as compilation', () => {
    /* Every link with the same codegen flags has the same empty source set,
     * so counting links would collapse unrelated links into one family and
     * put linker time into a number that reuse cannot move. */
    const link = ['cc', '-O2', 'a.o', 'b.o', '-o', 'prog']
    const compile = ['cc', '-O2', '-c', 'a.c', '-o', 'a.o']
    assert.equal(isCompile(link), false)
    assert.equal(isCompile(compile), true)
    const summary = summarize([
        { argv_hex: hex(link), wall_ns: '1000', status: '0' },
        { argv_hex: hex(link), wall_ns: '1000', status: '0' },
        { argv_hex: hex(compile), wall_ns: '1000', status: '0' },
    ])
    assert.equal(summary.compiles, 1)
    assert.equal(summary.links, 2)
    assert.equal(summary.codegen.repeatedCount, 0, 'the repeated link is not repeated compilation')
})

check('a header or table is a source, a bare word is not', () => {
    assert.equal(isSource('unicode/kofun_unicode_tables.inc'), true)
    assert.equal(isSource('bootstrap/stage2/sha256.h'), true)
    assert.equal(isSource('-Wall'), false)
    assert.equal(isSource('kofun-stage2'), false)
})

check('argv decoding rejects what it cannot decode instead of guessing', () => {
    assert.deepEqual(decodeArgv(hex(['cc', '-c', 'x.c'])), ['cc', '-c', 'x.c'])
    assert.equal(decodeArgv('odd'), null)
    assert.equal(decodeArgv('zz'), null)
})

// --------------------------------------------------------------- the counting

check('the first compile of a family is not counted as repeated work', () => {
    const argv = ['cc', '-O2', '-c', 'src/x.c', '-o', 'x.o']
    const once = repeatedWork([{ argv_hex: hex(argv), wall_ns: '5000000' }], codegenKey)
    assert.equal(once.repeatedCount, 0)
    assert.equal(once.repeatedWallNs, 0, 'first-time work is not removable by reuse')
})

check('repeated wall time excludes the first and totals the rest', () => {
    const argv = ['cc', '-O2', '-c', 'src/x.c']
    const rows = [
        { argv_hex: hex(argv), wall_ns: '5000000' },
        { argv_hex: hex(argv), wall_ns: '3000000' },
        { argv_hex: hex(argv), wall_ns: '2000000' },
    ]
    const work = repeatedWork(rows, codegenKey)
    assert.equal(work.repeatedCount, 2)
    assert.equal(work.repeatedWallNs, 5_000_000)
})

// ----------------------------------------------------------------- the rules

const asFields = (line) => {
    const fields = {}
    for (const field of line.split('\t').slice(1)) {
        const at = field.indexOf('=')
        fields[field.slice(0, at)] = field.slice(at + 1)
    }
    return fields
}

const oneRepeat = () => summarize([
    row(['cc', '-std=c11', '-O2', '-c', 'src/x.c', '-o', 'a.o']),
    row(['cc', '-std=c11', '-O2', '-c', 'src/x.c', '-o', 'b.o']),
].map(asFields))

const honestLedgerRow = ledgerRow({
    count: '2',
    profile: '-O2 -c -std=c11',
    macros: '-',
    sources: 'src/x.c',
    reason: 'two gates need it and neither can consume the other object',
})

check('more repeats than the ceiling is refused', () => {
    const problems = evaluate(oneRepeat(), parseLedger(honestLedgerRow), 0)
    assert.equal(problems.some((p) => /over the recorded ceiling/.test(p)), true)
})

check('fewer repeats than the ceiling is refused — the improvement must be recorded', () => {
    const problems = evaluate(oneRepeat(), parseLedger(honestLedgerRow), 5)
    assert.equal(problems.some((p) => /lower it/.test(p)), true)
})

check('a repeating family with no ledger row is refused', () => {
    const problems = evaluate(oneRepeat(), [], 1)
    assert.equal(problems.some((p) => /does not record/.test(p)), true)
})

check('a ledger row no run produced is refused — the direction that keeps it true', () => {
    const stale = ledgerRow({
        count: '2',
        profile: '-O2 -c -std=c11',
        macros: '-',
        sources: 'src/removed.c',
        reason: 'removed upstream',
    })
    const problems = evaluate(oneRepeat(), parseLedger(`${honestLedgerRow}\n${stale}`), 1)
    assert.equal(problems.some((p) => /did not produce/.test(p)), true)
})

check('a changed repeat count is refused', () => {
    const wrong = ledgerRow({
        count: '7',
        profile: '-O2 -c -std=c11',
        macros: '-',
        sources: 'src/x.c',
        reason: 'seven of them',
    })
    const problems = evaluate(oneRepeat(), parseLedger(wrong), 1)
    assert.equal(problems.some((p) => /the ledger records 7/.test(p)), true)
})

check('an unreasoned row is refused', () => {
    const unreasoned = ledgerRow({
        count: '2',
        profile: '-O2 -c -std=c11',
        macros: '-',
        sources: 'src/x.c',
        reason: 'UNRECORDED — say why this family is still compiled twice',
    })
    const problems = evaluate(oneRepeat(), parseLedger(unreasoned), 1)
    assert.equal(problems.some((p) => /has no reason/.test(p)), true)
})

check('a failed compile in the census is refused', () => {
    const failed = summarize([
        { argv_hex: hex(['cc', '-O2', '-c', 'src/x.c']), wall_ns: '1', status: '1' },
    ])
    const problems = evaluate(failed, [], 0)
    assert.equal(problems.some((p) => /non-zero status/.test(p)), true)
})

check('the candidate ledger cannot emit a row with no reason', () => {
    const summary = oneRepeat()
    const named = candidateLedger(summary, () => ['tests/a/run.sh', 'tests/b/run.sh'])
    assert.equal(named.length, 1)
    assert.match(named[0], /compiled by 2 gates: tests\/a\/run\.sh tests\/b\/run\.sh$/)
    const unowned = candidateLedger(summary, () => [])
    assert.match(unowned[0], /NO OWNER FOUND/,
        'an unexplained family says so rather than arriving with a blank reason')
    assert.equal(evaluate(summary, parseLedger(unowned.join('\n')), 1).length, 0,
        'NO OWNER FOUND is a reason a reader can act on, not an empty field')
})

check('a ledger declaring no ceiling is refused', () => {
    let complaint = null
    const value = readCeiling('count\tprofile\n', (message) => { complaint = message })
    assert.equal(value, null)
    assert.match(complaint, /declares no/)
})

check('the ceiling is read from the ledger text', () => {
    assert.equal(readCeiling('# repeated-ceiling: 12\n'), 12)
})

check('the ledger key round-trips through its columns', () => {
    const parsed = parseLedger(honestLedgerRow)[0]
    assert.equal(ledgerKey(parsed), '-O2 -c -std=c11||src/x.c')
})

check('a consistent run and ledger are accepted', () => {
    const problems = evaluate(oneRepeat(), parseLedger(honestLedgerRow), 1)
    assert.deepEqual(problems, [])
})

process.stdout.write(
    `PASS: ${checks} negative self-tests; the census key ignores the output ` +
    'path and source order, splits on macros and codegen settings, and the ' +
    'ceiling fails in both directions\n',
)

#!/usr/bin/env node

/*
 * What tooling/forbidden-requirements/check.mjs refuses.
 *
 *     node tooling/forbidden-requirements/self-test.mjs
 *
 * `check.mjs` run against the committed census is green, and a green run says
 * only that the rules pass on good input. It says nothing about what they
 * catch — and a census whose detectors quietly stopped matching would stay
 * green forever while reporting the tree as clean. That failure is the one this
 * subsystem exists to remove, so it may not be the one it ships with.
 *
 * Two halves, because the checker has two independent ways to be wrong:
 *
 *   1. the detectors, driven over `fixtures/`, where every case is a
 *      false positive or false negative this census actually had;
 *   2. the ledger diff, driven over a mutated copy of the real census, in
 *      both directions.
 */

import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { DETECTORS, dialectOf, withoutComments } from './detect.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..', '..')
const CENSUS = join(HERE, 'census.tsv')

let failures = 0
const fail = (message) => {
    process.stderr.write(`FAIL: forbidden requirements self-test: ${message}\n`)
    failures += 1
}

/* ------------------------------------------------------- 1. the detectors */

/*
 * Every expectation below is a case that was measured wrong before it was
 * written down. The zeroes are load-bearing: a rule with a near-miss shape has
 * two properties, and a suite that only proves it fires proves half of it.
 */
const FIXTURE_CASES = [
    ['mention-and-invoke.sh', 'node', 'invoke', 1,
        'one invocation; four mentions in comments, including a trailing one'],
    ['mention-and-invoke.sh', 'cc', 'invoke', 1,
        'one compile line, opened by an environment assignment and continued'],
    ['mention-and-invoke.sh', 'import-library', 'invoke', 0,
        "`-lt` and `-le` are shell comparisons, not libraries"],
    ['mention-and-invoke.sh', 'assembler', 'invoke', 0,
        '`as` in prose is not an assembler'],
    ['mention-and-invoke.sh', 'go-task', 'invoke', 0, 'nothing here runs the task runner'],
    ['mention-and-invoke.mjs', 'node', 'invoke', 1,
        'one child-process spawn; the import specifier and two comments are not invocations'],
    ['mention-and-invoke.mjs', 'go-task', 'invoke', 0,
        'a backtick opens a template literal in JavaScript, not a command substitution'],
    ['mention-and-invoke.mjs', 'cc', 'invoke', 0, 'nothing here compiles C'],
    ['mention-and-invoke.yml', 'go-task', 'invoke', 1,
        '`- run: task verify` is an invocation; the same words in prose are not'],
    ['mention-and-invoke.yml', 'node', 'invoke', 0, 'nothing here runs node'],
]

const bodies = new Map()
const bodyOf = (name) => {
    if (!bodies.has(name)) bodies.set(name, readFileSync(join(HERE, 'fixtures', name), 'utf8'))
    return bodies.get(name)
}

for (const [name, requirement, kind, expected, why] of FIXTURE_CASES) {
    const detector = DETECTORS.find((d) => d.requirement === requirement && d.kind === kind)
    if (detector === undefined) {
        fail(`no \`${requirement}\` (${kind}) detector, so the case cannot run`)
        continue
    }
    const stripped = withoutComments(name, bodyOf(name))
    const actual = detector.match(stripped, dialectOf(name)).length
    if (actual !== expected) {
        fail(`fixtures/${name}: \`${requirement}\` (${kind}) counted ${actual}, expected ` +
            `${expected} — ${why}`)
    }
}

/*
 * The fixture directory must stay outside the scan. It contains deliberate
 * invocations, so a checker that walked into it would census its own test data
 * and the exclusion would be indistinguishable from a bug in the file set.
 */
const censusPaths = new Set(
    readFileSync(CENSUS, 'utf8').split('\n')
        .filter((l) => l !== '' && !l.startsWith('#'))
        .map((l) => l.split('\t')[4]),
)
for (const name of ['mention-and-invoke.sh', 'mention-and-invoke.mjs', 'mention-and-invoke.yml']) {
    const path = `tooling/forbidden-requirements/fixtures/${name}`
    if (censusPaths.has(path)) fail(`${path} is in the census; the fixture directory must be excluded`)
}

/*
 * `detect.mjs` is exempt from `invoke` detection and from nothing else, and
 * both halves are asserted. Only the first half would let the exemption widen
 * to the whole directory — which is how a census stops counting its own
 * instrument, the surface most likely to grow.
 */
const censusRows = readFileSync(CENSUS, 'utf8').split('\n')
    .filter((l) => l !== '' && !l.startsWith('#'))
    .map((l) => l.split('\t'))
const patternSource = 'tooling/forbidden-requirements/detect.mjs'
const patternInvokes = censusRows.filter((f) => f[4] === patternSource && f[1] === 'invoke')
if (patternInvokes.length !== 0) {
    fail(`${patternSource} has ${patternInvokes.length} invoke row(s); it spells the patterns ` +
        'out as string literals and runs nothing, so counting them reports the vocabulary as a finding')
}
if (!censusRows.some((f) => f[4] === patternSource && f[0] === 'node' && f[1] === 'source')) {
    fail(`${patternSource} has no \`node source\` row; the invoke exemption has widened into ` +
        'the whole file, and the census no longer counts its own instrument')
}
for (const name of ['check.mjs', 'self-test.mjs']) {
    const path = `tooling/forbidden-requirements/${name}`
    if (!censusRows.some((f) => f[4] === path && f[0] === 'node' && f[1] === 'source')) {
        fail(`${path} is missing from the census; the exemption has widened to the directory`)
    }
}

/* ------------------------------------------------------- 2. the ledger diff */

const work = mkdtempSync(join(tmpdir(), 'forbidden-census-'))
const original = readFileSync(CENSUS, 'utf8')
const rows = original.split('\n').filter((l) => l !== '' && !l.startsWith('#'))

/* A row with a real, nonzero count, to mutate. Chosen by predicate rather than
 * by position, so re-sorting the census cannot silently pick a zero row. */
const victim = rows.find((l) => {
    const f = l.split('\t')
    return f[1] === 'invoke' && Number(f[2]) > 0
})
if (victim === undefined) fail('the census carries no invoke row, so the diff cannot be exercised')

const run = (ledger) => {
    const path = join(work, 'census.tsv')
    writeFileSync(path, ledger)
    try {
        execFileSync(process.execPath, [join(HERE, 'check.mjs')], {
            cwd: ROOT,
            env: { ...process.env, KOFUN_FORBIDDEN_CENSUS: path },
            stdio: 'pipe',
        })
        return { status: 0, stderr: '' }
    } catch (error) {
        return { status: error.status, stderr: String(error.stderr ?? '') }
    }
}

const CASES = victim === undefined ? [] : [
    {
        name: 'a use that is not in the ledger',
        why: 'this is what adding a `node` invocation to a gate looks like from inside the checker',
        ledger: original.replace(`${victim}\n`, ''),
        expect: 'and census.tsv does not record it',
    },
    {
        name: 'a ledger row whose use is gone',
        why: 'the #1395 direction: the removal happened and the record did not follow',
        ledger: `${original.trimEnd()}\ncc\tinvoke\t1\trequired-today\ttooling/forbidden-requirements/no-such-file.sh\n`,
        expect: 'and it is not there now',
    },
    {
        name: 'a count that drifted',
        why: 'a second invocation added to a file that already had one moves no row, only the number',
        ledger: original.replace(victim, victim.split('\t').map((f, i) => (i === 2 ? String(Number(f) + 1) : f)).join('\t')),
        expect: 'records',
    },
    {
        name: 'a requirement dropped from the ledger entirely',
        why: 'absent and clean must not look the same',
        ledger: original.split('\n').filter((l) => !l.startsWith('zig\t')).join('\n'),
        expect: 'has no row in census.tsv',
    },
    {
        name: 'an unknown class',
        why: 'the classification is the half that measures the gap, so it may not be free text',
        ledger: original.replace(victim, victim.replace('\trequired-today\t', '\tsomeday\t')),
        expect: 'is not required-today or removable',
    },
]

for (const testCase of CASES) {
    const { status, stderr } = run(testCase.ledger)
    if (status === 0) {
        fail(`the checker accepted ${testCase.name} — ${testCase.why}`)
        continue
    }
    if (!stderr.includes(testCase.expect)) {
        fail(`${testCase.name} was refused, but the diagnostic never says ` +
            `\`${testCase.expect}\`; it said: ${stderr.trim().split('\n')[0]}`)
    }
}

/* The must-not-fire half: the committed census itself passes. A suite in which
 * every case fails would also pass every assertion above. */
const clean = run(original)
if (clean.status !== 0) {
    fail(`the committed census does not pass its own checker: ${clean.stderr.trim().split('\n')[0]}`)
}

if (failures !== 0) process.exit(1)

process.stdout.write(
    `PASS: ${FIXTURE_CASES.length} detector cases over 3 fixtures, ` +
    `${FIXTURE_CASES.filter((c) => c[3] === 0).length} of them asserting a near miss counts zero\n`)
process.stdout.write(
    `PASS: ${CASES.length} ledger mutations each refused with a diagnostic that names the drift\n`)
process.stdout.write('PASS: the committed census passes the same checker unmutated\n')

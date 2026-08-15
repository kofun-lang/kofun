#!/usr/bin/env node

/*
 * Measure the distance between the contract and the tree.
 *
 *     node tooling/forbidden-requirements/check.mjs
 *     node tooling/forbidden-requirements/check.mjs --count
 *     node tooling/forbidden-requirements/check.mjs --predicates
 *
 * `spec/native-toolchain-v1/contract.json` names fourteen
 * `forbidden_core_build_requirements`, and `task native-toolchain-contract`
 * proves the contract still says so by mutating it and watching each profile
 * refuse. That check never looks at the repository. So a green contract gate
 * reads as progress toward a target nobody is measuring — the contract states
 * an end state, the tree is somewhere else, and nothing reports the gap (#1451).
 *
 * `census.tsv` is that gap, one row per (requirement, kind, file). It is a
 * ledger, not a suppression list, and it fails in BOTH directions:
 *
 *   - a use that is not in the ledger is a dependency that arrived silently;
 *   - a ledger row whose use is gone is an improvement that was not recorded.
 *
 * The second direction is the one that is usually missing, and this repository
 * has already paid for its absence. #1213 replaced GNU `sha256sum` with
 * `bin/kofun-digest` so digests depend on nothing the project does not own, and
 * #1395 then found a release claim still asserting the removed dependency. The
 * removal happened; the record did not follow. A one-directional sweep would
 * not have caught it.
 *
 * This checker is itself written in JavaScript, so it appears in its own
 * census under `node`. That is not an oversight — a census that exempted its
 * own instrument would be measuring everything except the thing most likely to
 * grow.
 */

import { execFileSync } from 'node:child_process'
import { readFileSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { DETECTORS, FILE_SET, dialectOf, withoutComments } from './detect.mjs'
import { NEEDS, needOf, reachability } from './reach.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..', '..')
/*
 * The ledger path is overridable so `self-test.mjs` can point the checker at a
 * mutated copy and watch it refuse. Mutating the ledger down is what mutating
 * the tree up looks like from in here — both directions of the diff are
 * exercised that way without editing a real gate script.
 */
const LEDGER = process.env.KOFUN_FORBIDDEN_CENSUS ?? join(HERE, 'census.tsv')
const CONTRACT = join(ROOT, 'spec', 'native-toolchain-v1', 'contract.json')

/*
 * The fixture directory is the one place excluded from the scan, because it
 * contains a deliberate invocation whose whole purpose is to be detected by the
 * self-test. Excluding it is stated here and asserted in the self-test, so the
 * hole cannot quietly widen into "anything under tooling/".
 */
const EXCLUDED = 'tooling/forbidden-requirements/fixtures/'

/*
 * The file that spells the patterns out is exempt from `invoke` detection, and
 * from nothing else. `detect.mjs` writes `-Wl,`, `--sysroot`, `-Wa,` and
 * `dlltool` as string literals, and the first census counted them: four
 * assembler invocations, seven linker invocations and six SDK lookups, in a
 * file that runs nothing at all. A rule that reports its own vocabulary reads
 * exactly like a finding.
 *
 * Its `source` rows stay — it is 300 lines of JavaScript and belongs in the
 * `node` count like every other file here. The self-test asserts both halves,
 * because an exemption that quietly widened to cover the whole directory would
 * look identical in the output.
 */
const PATTERN_SOURCE = new Set([
    'tooling/forbidden-requirements/detect.mjs',
    'tooling/forbidden-requirements/reach.mjs',
])

const CLASSES = new Set(['required-today', 'removable'])

const fail = (message) => {
    process.stderr.write(`FAIL: forbidden requirements: ${message}\n`)
    process.exitCode = 1
}

/* ------------------------------------------------------------------ the tree */

function trackedFiles() {
    const out = execFileSync('git', ['ls-files', '-z'], { cwd: ROOT, maxBuffer: 64 * 1024 * 1024 })
    return out.toString('utf8').split('\0').filter(Boolean)
}

const RUNNABLE = ['.sh', '.mjs', '.js', '.yml', '.yaml']

function universe() {
    const files = []
    for (const path of trackedFiles()) {
        if (path.startsWith(EXCLUDED)) continue
        const full = join(ROOT, path)
        try {
            if (!statSync(full).isFile()) continue
        } catch {
            continue
        }
        let body
        try {
            body = readFileSync(full, 'utf8')
        } catch {
            continue
        }
        const named = RUNNABLE.some((ext) => path.endsWith(ext))
        /*
         * A NUL rules out a *candidate* discovered by shebang sniffing, which
         * has to read every tracked file including binary fixtures. It does not
         * rule out a file whose extension already says it is a script:
         * `tests/interop/bindgen-c/check-report.mjs` embeds four NUL bytes in a
         * fixture string, and skipping it dropped a real Node.js source file
         * from the census with nothing to show for it.
         */
        if (!named && body.indexOf(String.fromCharCode(0)) !== -1) continue
        if (!named && !body.startsWith('#!')) continue
        files.push({ path, body })
    }
    return files.sort((a, b) => (a.path < b.path ? -1 : 1))
}

/* One row per (requirement, kind, path), with the number of occurrences and
 * the derived answer to "must an independent builder obtain this?" (#1459). */
function detect(files) {
    const rows = new Map()
    const { where } = reachability(ROOT, files)
    const key = (r, k, p) => `${r}\t${k}\t${p}`
    for (const { path, body } of files) {
        const stripped = withoutComments(path, body)
        const dialect = dialectOf(path)
        for (const detector of DETECTORS) {
            let count = 0
            if (detector.kind === 'source') {
                if (detector.selects(path, body)) count = 1
            } else if (!PATTERN_SOURCE.has(path)) {
                count = detector.match(stripped, dialect).length
            }
            if (count === 0) continue
            rows.set(key(detector.requirement, detector.kind, path), {
                requirement: detector.requirement,
                kind: detector.kind,
                count,
                path,
                need: needOf({
                    path, body, requirement: detector.requirement, kind: detector.kind,
                }, where),
            })
        }
    }
    return rows
}

/* ---------------------------------------------------------------- the ledger */

/*
 * A declared bound on the one value that means "the rules could not tell".
 *
 * The stored-and-recomputed `need` already catches a rule that *stops* working:
 * removing one of the four naming rules moves 39 rows into `unknown` and every
 * one of them contradicts its stored value and fails by name. What it does not
 * catch is a use *arriving* unclassifiable — a new file produces a new row, and
 * a new row is the ordinary flow, so in a 635-row ledger it reads like every
 * other addition while the headline gets quietly less true (#1474).
 *
 * So the count is declared, and checked in both directions the way
 * `tests/assertions/budget.tsv` is: over is drift, under is an improvement that
 * was not recorded.
 */
function readCeiling() {
    const raw = readFileSync(LEDGER, 'utf8')
    const match = /^#\s*unknown-ceiling:\s*(\d+)\s*$/m.exec(raw)
    if (match === null) {
        fail('census.tsv declares no `# unknown-ceiling: N`, so the one value that means ' +
            '"the rules could not tell" has no bound and a new unclassifiable use would ' +
            'arrive as an ordinary row')
        return null
    }
    return Number(match[1])
}

function readLedger(quiet = false) {
    const complain = quiet ? () => {} : fail
    const rows = new Map()
    const raw = readFileSync(LEDGER, 'utf8')
    let lineNumber = 0
    for (const line of raw.split('\n')) {
        lineNumber += 1
        const trimmed = line.trim()
        if (trimmed === '' || trimmed.startsWith('#')) continue
        const fields = line.split('\t')
        if (fields.length !== 6) {
            complain(`census.tsv line ${lineNumber} has ${fields.length} fields, expected 6 ` +
                '(requirement, kind, count, class, need, path)')
            continue
        }
        const [requirement, kind, count, klass, need, path] = fields.map((f) => f.trim())
        rows.set(`${requirement}\t${kind}\t${path}`, {
            requirement, kind, count: Number(count), class: klass, need, path, lineNumber,
        })
    }
    return rows
}

/* ---------------------------------------------------------------------- main */

const contract = JSON.parse(readFileSync(CONTRACT, 'utf8'))
const requirements = contract.objective.forbidden_core_build_requirements

/*
 * The vocabulary is the contract's, never a copy. A requirement added there
 * with no detector here fails immediately rather than going unmeasured, which
 * is the difference between a census and a list of the things someone
 * remembered.
 */
const detected = new Set(DETECTORS.map((d) => d.requirement))
for (const requirement of requirements) {
    if (!detected.has(requirement)) {
        fail(`\`${requirement}\` is a forbidden core build requirement in ` +
            'spec/native-toolchain-v1/contract.json and no detector in ' +
            'tooling/forbidden-requirements/detect.mjs measures it, so its count ' +
            'would silently read as zero')
    }
}
for (const detector of DETECTORS) {
    if (!requirements.includes(detector.requirement)) {
        fail(`detect.mjs measures \`${detector.requirement}\`, which the contract does ` +
            'not forbid; remove the detector or add the requirement to the contract')
    }
}
if (process.exitCode === 1) process.exit(1)

if (process.argv.includes('--predicates')) {
    process.stdout.write(`file set:\n  ${FILE_SET}\n\n`)
    for (const d of DETECTORS) {
        process.stdout.write(`${d.requirement} (${d.kind}) — ${d.describes}\n  ${d.predicate}\n`)
    }
    process.exit(0)
}

const files = universe()
const found = detect(files)

if (process.argv.includes('--count')) {
    const previous = (() => {
        try {
            return readLedger(true)
        } catch {
            return new Map()
        }
    })()
    const lines = []
    for (const requirement of requirements) {
        const mine = [...found.values()]
            .filter((r) => r.requirement === requirement)
            .sort((a, b) => (a.kind + a.path < b.kind + b.path ? -1 : 1))
        if (mine.length === 0) {
            lines.push(`${requirement}\t-\t0\t-\t-\t-`)
            continue
        }
        for (const row of mine) {
            const kept = previous.get(`${row.requirement}\t${row.kind}\t${row.path}`)
            const klass = kept && CLASSES.has(kept.class) ? kept.class : 'required-today'
            lines.push(
                `${row.requirement}\t${row.kind}\t${row.count}\t${klass}\t${row.need}\t${row.path}`,
            )
        }
    }
    process.stdout.write(`${lines.join('\n')}\n`)
    process.exit(0)
}

const ledger = readLedger()
if (process.exitCode === 1) process.exit(1)

/* A requirement is censused when it has at least one row: a real use, or the
 * explicit zero row. "Absent" and "clean" must not look the same. */
const rowsFor = (requirement) => [...ledger.values()].filter((r) => r.requirement === requirement)

for (const requirement of requirements) {
    const rows = rowsFor(requirement)
    if (rows.length === 0) {
        fail(`\`${requirement}\` has no row in census.tsv. A requirement with no uses ` +
            'must be stated as zero (`' + requirement + '\t-\t0\t-\t-`), not left out, ' +
            'or the ledger cannot distinguish clean from unexamined')
        continue
    }
    const zero = rows.filter((r) => r.kind === '-' && r.count === 0)
    const real = rows.filter((r) => r.kind !== '-')
    const live = [...found.values()].filter((r) => r.requirement === requirement)
    if (zero.length !== 0 && real.length !== 0) {
        fail(`\`${requirement}\` carries both a zero row and ${real.length} use rows; ` +
            'one of them is false')
    }
    if (zero.length !== 0 && live.length !== 0) {
        fail(`\`${requirement}\` is recorded as unused, but ${live.length} use(s) were ` +
            `found, starting at ${live[0].path}; remove the zero row and record them`)
    }
    if (zero.length === 0 && real.length === 0 && live.length === 0) {
        fail(`\`${requirement}\` has rows that are neither a zero row nor a use`)
    }
}

for (const row of ledger.values()) {
    if (!requirements.includes(row.requirement)) {
        fail(`census.tsv line ${row.lineNumber} names \`${row.requirement}\`, which is not a ` +
            'forbidden core build requirement in the contract')
        continue
    }
    if (row.kind === '-') {
        if (row.count !== 0 || row.path !== '-' || row.class !== '-' || row.need !== '-') {
            fail(`census.tsv line ${row.lineNumber}: a zero row must read ` +
                `\`${row.requirement}\t-\t0\t-\t-\t-\``)
        }
        continue
    }
    if (row.kind !== 'invoke' && row.kind !== 'source') {
        fail(`census.tsv line ${row.lineNumber}: kind \`${row.kind}\` is not \`invoke\`, ` +
            '`source`, or `-`')
    }
    if (!CLASSES.has(row.class)) {
        fail(`census.tsv line ${row.lineNumber}: class \`${row.class}\` is not ` +
            `${[...CLASSES].join(' or ')}`)
    }
    if (!NEEDS.has(row.need)) {
        fail(`census.tsv line ${row.lineNumber}: need \`${row.need}\` is not one of ` +
            `${[...NEEDS].join(', ')}`)
    }
}

/* Direction 1: a use the ledger does not carry. */
for (const [key, row] of found) {
    const recorded = ledger.get(key)
    if (!recorded) {
        fail(`${row.path} uses \`${row.requirement}\` (${row.kind}, ${row.count}) and ` +
            'census.tsv does not record it. Regenerate with `--count`, then classify the ' +
            'new row — a forbidden core build requirement may not arrive unrecorded')
        continue
    }
    if (recorded.count !== row.count) {
        fail(`${row.path} uses \`${row.requirement}\` ${row.count} time(s); census.tsv ` +
            `line ${recorded.lineNumber} records ${recorded.count}`)
    }
    /*
     * `need` is derived, so a hand-edited value is not a preference — it is a
     * claim the tree contradicts. This is what keeps the column from becoming a
     * suppression list: `bin/kofun`'s cc rows cannot be moved to `optional`,
     * because its invocations are unguarded and this recomputes that.
     */
    if (recorded.need !== row.need) {
        fail(`${row.path}: \`${row.requirement}\` is \`${row.need}\`; census.tsv line ` +
            `${recorded.lineNumber} records \`${recorded.need}\`. The need column is ` +
            'derived from task reachability and the availability guards — edit the tree, not the row')
    }
}

/* Direction 2: a ledger row whose use is gone. This is the #1395 direction. */
for (const [key, row] of ledger) {
    if (row.kind === '-') continue
    if (found.has(key)) continue
    fail(`census.tsv line ${row.lineNumber} records \`${row.requirement}\` (${row.kind}) in ` +
        `${row.path} and it is not there now; remove the row so the improvement is recorded`)
}

if (process.exitCode === 1) process.exit(1)

/* ------------------------------------------------------------------- reports */

const uses = [...ledger.values()].filter((r) => r.kind !== '-')
const censused = requirements.filter((r) => rowsFor(r).length !== 0)
const clean = requirements.filter((r) => rowsFor(r).some((row) => row.kind === '-'))
const removable = uses.filter((r) => r.class === 'removable')
const occurrences = uses.reduce((sum, r) => sum + r.count, 0)

process.stdout.write(
    `PASS: ${censused.length} of ${requirements.length} forbidden core build requirements are ` +
    `censused, ${clean.length} of them at zero\n`)
process.stdout.write(
    `PASS: ${uses.length} of ${found.size} detected uses are in the ledger, and every ` +
    'ledger row still describes a use\n')
process.stdout.write(
    `PASS: ${removable.length} of ${uses.length} recorded uses are classified removable today; ` +
    `${uses.length - removable.length} are required\n`)

/*
 * The number B6 and B7 are stated in terms of. A count of uses is not what an
 * independent builder must obtain, and the two differ in both directions —
 * `scripts/graphify.sh` invokes `python` six times and no gate runs it, while
 * `examples/rust-shim/check.sh` exits 1 without `cargo` and is in the verify
 * list. Every value is printed even at zero: a category that disappears when
 * empty cannot be seen to have grown (#1459).
 */
const byNeed = (value) => uses.filter((r) => r.need === value)
const onPath = byNeed('required')
const ceiling = readCeiling()
const unknowns = byNeed('unknown')
if (ceiling !== null && unknowns.length > ceiling) {
    fail(`${unknowns.length} rows are \`unknown\` and census.tsv declares a ceiling of ` +
        `${ceiling}. A use the rules cannot classify may not arrive as an ordinary row: ` +
        `classify it — see the four naming rules in reach.mjs — or raise the ceiling ` +
        'deliberately, in the same commit, with the reason')
}
if (ceiling !== null && unknowns.length < ceiling) {
    fail(`only ${unknowns.length} rows are \`unknown\` and census.tsv still declares a ` +
        `ceiling of ${ceiling}; lower it so the improvement is recorded`)
}
if (process.exitCode === 1) process.exit(1)
process.stdout.write(
    `PASS: ${onPath.length} of ${uses.length} uses are on the path \`task verify\` runs and ` +
    'cannot be skipped — this is what an independent builder must obtain\n')
for (const value of ['optional', 'off-path', 'unknown']) {
    const rows = byNeed(value)
    const bound = value === 'unknown' ? ` of ${ceiling} allowed` : ''
    process.stdout.write(
        `      ${value.padEnd(26)} ${rows.length}${bound}` +
        (rows.length === 0 ? '' : ` (${[...new Set(rows.map((r) => r.requirement))].join(', ')})`) +
        '\n')
}

/* The distance itself, per requirement, so the contract and the gap to it are
 * reported together rather than one of them alone reading as the other. */
for (const requirement of requirements) {
    const mine = uses.filter((r) => r.requirement === requirement)
    if (mine.length === 0) {
        process.stdout.write(`      ${requirement.padEnd(26)} 0\n`)
        continue
    }
    const invoke = mine.filter((r) => r.kind === 'invoke')
    const source = mine.filter((r) => r.kind === 'source')
    const parts = []
    if (source.length !== 0) parts.push(`${source.length} file(s) written in it`)
    if (invoke.length !== 0) {
        parts.push(`${invoke.reduce((s, r) => s + r.count, 0)} invocation(s) in ${invoke.length} file(s)`)
    }
    process.stdout.write(`      ${requirement.padEnd(26)} ${parts.join(', ')}\n`)
}

/*
 * The residue the file set does not reach, printed rather than dropped. A C
 * source file requires a C compiler and contains no line that invokes one, so
 * a scan of runnable files reports zero for it and would read as clean.
 */
const cSources = trackedFiles().filter((p) => p.endsWith('.c') || p.endsWith('.h')).length
process.stdout.write(
    `NOTE: outside the scanned file set: ${cSources} tracked *.c/*.h files, which require a C ` +
    'compiler to build though no line in them invokes one (#32 seed and C11 backend)\n')
process.stdout.write(`NOTE: ${occurrences} recorded occurrences across ${uses.length} rows\n`)

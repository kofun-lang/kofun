// The independent expectation for the #1311 model gate.
//
// Nothing here reimplements the summaries: `summarize` and `outlierFlags` come
// from `spec/benchmark-report-v1/model.mjs`, the merged #1310 oracle, which
// computes them from a plain array with arbitrary-precision comparisons. The
// Kofun model computes them from two bounded segments with a merge selector
// and no concatenation, and the gate requires the two to agree.
//
// The sample values are read out of `corpus.kofun` rather than copied here, so
// editing the corpus cannot silently move the expectation with it. The shorter
// corpus literals are checked to be prefixes of the long ones for the same
// reason: three copies of one series is three chances to disagree.

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { summarize, outlierFlags, compareReports } from '../../../spec/benchmark-report-v1/model.mjs'
import { LIMITS } from '../../../spec/benchmark-report-v1/contract.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
// Both inputs are overridable for one reason: the gate proves the coverage
// check bites by pointing them at a manifest with one extra vector and at a
// corpus with one case removed. Production reads the tracked files.
const CORPUS = readFileSync(
    process.env.KOFUN_COMPARISON_CORPUS ?? join(HERE, 'corpus.kofun'), 'utf8')

function literal(name) {
    const match = new RegExp(
        `fn ${name}\\(\\) -> List\\[Int\\] \\{\\s*let values: List\\[Int\\] = \\[([^\\]]*)\\]`,
    ).exec(CORPUS)
    if (match === null) throw new Error(`corpus.kofun has no ${name} literal`)
    return match[1]
        .split(',')
        .map((piece) => piece.trim())
        .filter((piece) => piece.length > 0)
        .map((piece) => {
            if (!/^\d+$/.test(piece)) throw new Error(`${name} has a non-integer element ${piece}`)
            return Number(piece)
        })
}

const segment0 = literal('corpus_segment0_64')
const segment1 = literal('corpus_segment1_36')
const series = [...segment0, ...segment1]

function requirePrefix(name, values, length) {
    const expected = series.slice(0, length)
    const actual = name === 'corpus_segment1_35' || name === 'corpus_segment1_1'
        ? values
        : values
    const target = name.startsWith('corpus_segment1_')
        ? series.slice(LIMITS.segment0Samples, LIMITS.segment0Samples + values.length)
        : expected
    if (JSON.stringify(actual) !== JSON.stringify(target)) {
        throw new Error(`${name} is not the matching prefix of the corpus series`)
    }
}

requirePrefix('corpus_segment0_63', literal('corpus_segment0_63'), 63)
requirePrefix('corpus_segment1_35', literal('corpus_segment1_35'), 35)
requirePrefix('corpus_segment1_1', literal('corpus_segment1_1'), 1)

if (segment0.length !== LIMITS.segment0Samples) throw new Error('segment 0 is not 64 values')
if (segment1.length !== LIMITS.segment1Samples) throw new Error('segment 1 is not 36 values')

// The named cases the tracked corpus runs, in the order `run_group` runs them.
// `fence` carries its own eight samples because its point is a value exactly on
// the Tukey fence, which the main series does not contain.
const CASES = [
    { name: 'n1', count: 1, group: 0 },
    { name: 'n2', count: 2, group: 0 },
    { name: 'n63', count: 63, group: 0 },
    { name: 'n64', count: 64, group: 0 },
    { name: 'fence', group: 0, samples: literal('corpus_fence_8') },
    { name: 'n65', count: 65, group: 1 },
    { name: 'n99', count: 99, group: 1 },
    { name: 'n100', count: 100, group: 1 },
    { name: 'timecap', count: 63, group: 1 },
]

function split(count) {
    const samples = series.slice(0, count)
    return {
        samples,
        first: samples.slice(0, LIMITS.segment0Samples),
        second: samples.slice(LIMITS.segment0Samples),
    }
}

function caseLines(name, count, provided) {
    const { samples, first, second } = provided === undefined
        ? split(count)
        : {
            samples: provided,
            first: provided.slice(0, LIMITS.segment0Samples),
            second: provided.slice(LIMITS.segment0Samples),
        }
    const summary = summarize(samples)
    const flags = outlierFlags(samples)
    const total = samples.length
    const lines = [
        `${name} 0 ${total} ${summary.minimum} ${summary.maximum} ${summary.median} ` +
            `${summary.p25} ${summary.p75} ${summary.median_absolute_deviation}`,
    ]
    flags.forEach((flag, index) => {
        if (flag) lines.push(`${name} outlier ${index}`)
    })
    const set = flags.filter(Boolean).length
    lines.push(`${name} flags ${first.length} ${second.length} ${set}`)
    return lines
}

function expectGroup(group) {
    const chosen = CASES.filter((entry) => entry.group === group)
    const lines = chosen.flatMap((entry) => caseLines(entry.name, entry.count, entry.samples))
    lines.push(`cases ${chosen.length}`)
    return lines
}

// The sweep counts. Every residue class the nearest-rank arithmetic can turn
// on is covered by consecutive runs rather than by sampling: `ceil(n/4)`,
// `ceil(n/2)` and `ceil(3n/4)` all change with `n mod 4`, so eight consecutive
// counts at the bottom, four in the middle, eight across the segment boundary,
// and five at the ceiling cover each residue at each structural position.
const LADDER = [
    1, 2, 3, 4, 5, 6, 7, 8,
    15, 16, 17, 18,
    31, 32, 33, 34,
    61, 62, 63, 64, 65, 66, 67, 68,
    96, 97, 98, 99, 100,
]

function sweepCounts() {
    if (process.env.KOFUN_BENCHMARK_REPORT_MODEL_SWEEP === 'all') {
        return Array.from({ length: LIMITS.samples }, (_, index) => index + 1)
    }
    return LADDER
}

function kofunList(values) {
    if (values.length === 0) return '[]'
    const rows = []
    for (let start = 0; start < values.length; start += 8) {
        rows.push('        ' + values.slice(start, start + 8).join(', '))
    }
    return '[\n' + rows.join(',\n') + '\n    ]'
}

function sweepSource(counts) {
    const parts = [
        '# Generated by oracle.mjs from corpus.kofun. Not tracked: the counts it',
        '# covers are chosen by the gate, and every literal below is a prefix of the',
        '# tracked corpus series.',
        '',
        'fn count_flags(flags: List[Int]) -> Int {',
        '    let mut set = 0',
        '    let mut i = 0',
        '    while i < len(flags) {',
        '        if flags[i] == 1 {',
        '            set = set + 1',
        '        }',
        '        i = i + 1',
        '    }',
        '    return set',
        '}',
        '',
        '# One printing site for every count. Building the line inside each',
        '# generated case instead costs about a dozen Text temporary sites each,',
        '# and the compiler admits 256 in a program (E2S156), so a sweep of more',
        '# than twenty counts stops compiling.',
        'fn print_sweep(count: Int, summary: ReportSummary, set: Int) -> Int {',
        '    let head: Text = "sweep " + to_text(count) + " " + to_text(summary.minimum) +',
        '        " " + to_text(summary.maximum) + " " + to_text(summary.median)',
        '    let tail: Text = to_text(summary.p25) + " " + to_text(summary.p75) + " " +',
        '        to_text(summary.median_absolute_deviation) + " " + to_text(set)',
        '    print(head + " " + tail)',
        '    return 1',
        '}',
        '',
    ]
    for (const count of counts) {
        const { first, second } = split(count)
        parts.push(
            `fn sweep_${count}() -> Int {`,
            `    let first: List[Int] = ${kofunList(first)}`,
            `    let second: List[Int] = ${kofunList(second)}`,
            '    let summary: ReportSummary = summarize_segments(first, second)',
            '    let flags0: List[Int] = outlier_segment(first, summary.p25, summary.p75)',
            '    let flags1: List[Int] = outlier_segment(second, summary.p25, summary.p75)',
            '    let set = count_flags(flags0) + count_flags(flags1)',
            `    return print_sweep(${count}, summary, set)`,
            '}',
            '',
        )
    }
    parts.push(
        'fn main() {',
        '    # Group 6 matches no branch, so this runs no case and prints nothing.',
        '    # The call is here because every function in model.kofun and',
        '    # corpus.kofun must be *referenced* or the build fails at `cc` with',
        '    # -Werror=unused-function (#1358), and `run_group` names them all.',
        '    let mut ran = run_group(6) + run_comparison_group(6)',
    )
    for (const count of counts) parts.push(`    ran = ran + sweep_${count}()`)
    parts.push('    print("sweep cases " + to_text(ran))', '}', '')
    return parts.join('\n')
}

function sweepExpect(counts) {
    const lines = []
    for (const count of counts) {
        const samples = series.slice(0, count)
        const summary = summarize(samples)
        const set = outlierFlags(samples).filter(Boolean).length
        lines.push(
            `sweep ${count} ${summary.minimum} ${summary.maximum} ${summary.median} ` +
                `${summary.p25} ${summary.p75} ${summary.median_absolute_deviation} ${set}`,
        )
    }
    lines.push(`sweep cases ${counts.length}`)
    return lines
}

// ------------------------------------------------------------- comparison
//
// The #1313 expectation. `compareReports` is the same frozen oracle, and it
// takes the nested wire document rather than the flat Stage 2 outcome, so each
// case is built by overriding the tracked `minimal.json` vector — the smallest
// valid report there is — and letting `summarize`/`outlierFlags` fill the
// derived fields. Building the document by hand here would be a second
// implementation of the thing under test.

const MINIMAL = JSON.parse(readFileSync(
    join(HERE, '..', '..', '..', 'spec/benchmark-report-v1/vectors/positive/minimal.json'), 'utf8'))

const STATUS = Object.freeze({ BR006: 6, BR007: 7, BR008: 8, BR009: 9 })
const RESULT = Object.freeze({ equivalent: 0, improved: 1, regressed: 2 })

function reportWith(options) {
    const report = JSON.parse(JSON.stringify(MINIMAL))
    const samples = options.samples ?? [options.median]
    report.identity.suite = options.suite ?? 'kofun.core'
    report.identity.case = 'list_int_sum'
    report.identity.metric = options.metric ?? 'duration'
    report.identity.direction = options.direction ?? 'lower-is-better'
    if (options.parameterAbsent === true) {
        delete report.identity.parameter
    } else {
        report.identity.parameter = 'n=64'
    }
    report.clock = options.clock ?? 'monotonic'
    report.budget = { warmup_cap_ns: 1000000, sampling_cap_ns: 2000000000, sample_cap: samples.length }
    report.measurement = {
        warmup_iterations: 32,
        warmup_stop: 'steady',
        iterations_per_sample: options.iterations ?? 8,
        sample_count: samples.length,
        sampling_stop: 'sample-cap',
        harness_overhead_ns: 12,
    }
    report.samples = samples
    report.outliers = [...outlierFlags(samples)]
    report.summary = { ...summarize(samples) }
    return report
}

// Each case names the two sides the Kofun corpus builds and the threshold it
// passes, in `run_comparison_group` order.
const COMPARISONS = Object.freeze({
    0: [
        ['equal', { median: 1000 }, { median: 1000 }, 0],
        ['halfup', { median: 32 }, { median: 33 }, 0],
        ['halfdown', { median: 32 }, { median: 31 }, 0],
        ['exact', { median: 8 }, { median: 9 }, 0],
    ],
    1: [
        ['atthreshold', { median: 1000 }, { median: 1100 }, 1000],
        ['overthreshold', { median: 1000 }, { median: 1100 }, 999],
        ['higherworse', { median: 1000, direction: 'higher-is-better' },
            { median: 900, direction: 'higher-is-better' }, 0],
        ['higherbetter', { median: 1000, direction: 'higher-is-better' },
            { median: 1100, direction: 'higher-is-better' }, 0],
    ],
    2: [
        ['zeroboth', { median: 0 }, { median: 0 }, 0],
        ['zerobase', { median: 0 }, { median: 5 }, 0],
        ['overflow', { median: 1 }, { median: LIMITS.integer }, 0],
        ['thresholdlow', { median: 1000 }, { median: 1000 }, -1],
        ['thresholdhigh', { median: 1000 }, { median: 1000 }, LIMITS.thresholdBps + 1],
    ],
    3: [
        ['suite', { median: 1000 }, { median: 1000, suite: 'other.suite' }, 0],
        ['metric', { median: 1000 }, { median: 1000, metric: 'throughput' }, 0],
        ['direction', { median: 1000 }, { median: 1000, direction: 'higher-is-better' }, 0],
    ],
    4: [
        ['clock', { median: 1000 }, { median: 1000, clock: 'process-cpu' }, 0],
        ['batch', { median: 1000 }, { median: 1000, iterations: 16 }, 0],
        ['parameter', { median: 1000 }, { median: 1000, parameterAbsent: true }, 0],
    ],
    5: [
        // The invalid-baseline case has no oracle document: an empty series is
        // not a report, so the model refuses it before comparison and the
        // expectation is the model's own BR006. Stated rather than computed.
        ['invalidbase', null, null, STATUS.BR006],
        ['thresholdfirst', { median: 1000 }, { median: 1000, suite: 'other.suite' }, -1],
        ['alloweddelta', { median: 1000 }, { samples: [900, 1000, 1100] }, 0],
    ],
})

function comparisonLine(name, baseline, candidate, threshold) {
    if (baseline === null) return `${name} ${threshold} 0 0 0`
    try {
        const result = compareReports(reportWith(baseline), reportWith(candidate), threshold)
        if (result.kind === 'indeterminate') return `${name} 0 3 0 ${result.threshold_bps}`
        return `${name} 0 ${RESULT[result.verdict]} ${result.change_bps} ${result.threshold_bps}`
    } catch (error) {
        const code = error?.code ?? error?.details?.code
        const status = STATUS[code]
        if (status === undefined) throw error
        return `${name} ${status} 0 0 0`
    }
}

export function comparisonGroup(group) {
    const cases = COMPARISONS[group]
    if (cases === undefined) throw new Error(`no comparison group ${group}`)
    const lines = cases.map(([name, baseline, candidate, threshold]) =>
        comparisonLine(name, baseline, candidate, threshold))
    lines.push(`cases ${cases.length}`)
    return lines
}


// -------------------------------------------------- frozen boundary vectors
//
// #1310's thirteen comparison boundaries, run by name against the Kofun
// implementation (#1367). Coverage is asserted from the manifest's side: a
// vector with no case in `corpus.kofun` fails here rather than going unrun,
// which is the whole point — the corpus can be complete today and silently
// incomplete the moment a boundary is added upstream.

// The manifest path is overridable so the gate can prove the coverage check
// bites: it points this at a copy carrying one extra vector and requires the
// refusal. Production reads the tracked file.
const VECTORS_PATH = process.env.KOFUN_COMPARISON_VECTORS ??
    join(HERE, '..', '..', '..', 'spec/benchmark-report-v1/vectors/comparison.json')
const VECTORS = JSON.parse(readFileSync(VECTORS_PATH, 'utf8'))

// Which vectors each group runs, read out of the corpus rather than restated,
// so the two cannot disagree about what ran.
function corpusVectorNames() {
    const names = []
    for (const match of CORPUS.matchAll(/run_vector\("([^"]+)"/g)) names.push(match[1])
    return names
}

function vectorCoverage() {
    const declared = VECTORS.vectors.map((vector) => vector.name)
    const covered = corpusVectorNames()
    const missing = declared.filter((name) => !covered.includes(name))
    const unknown = covered.filter((name) => !declared.includes(name))
    if (missing.length > 0) {
        throw new Error(
            `corpus.kofun has no case for frozen comparison ${missing.length === 1 ? 'vector' : 'vectors'}: ` +
            `${missing.join(', ')}`)
    }
    if (unknown.length > 0) {
        throw new Error(`corpus.kofun runs vectors the manifest does not declare: ${unknown.join(', ')}`)
    }
    const duplicated = covered.filter((name, index) => covered.indexOf(name) !== index)
    if (duplicated.length > 0) {
        throw new Error(`corpus.kofun runs a vector more than once: ${duplicated.join(', ')}`)
    }
    return declared
}

// The groups the corpus splits them into, in `run_vector_group` order. The
// split exists for the bounded Text arena (#1359), not for meaning.
const VECTOR_GROUPS = Object.freeze([
    ['lower-below-threshold', 'lower-equal-threshold', 'lower-above-threshold',
        'lower-improvement', 'lower-improvement-equal-threshold'],
    ['higher-regression', 'higher-improvement', 'half-away-from-zero',
        'negative-half-away-from-zero'],
    ['maximum-threshold', 'zero-equals-zero', 'zero-baseline', 'checked-overflow'],
])

function vectorLine(vector) {
    if (vector.error !== undefined) {
        const status = STATUS[vector.error]
        if (status === undefined) throw new Error(`unmapped vector error ${vector.error}`)
        return `${vector.name} ${status} 0 0 0`
    }
    const expected = vector.expected
    if (expected.kind === 'indeterminate') {
        return `${vector.name} 0 3 0 ${expected.threshold_bps}`
    }
    return `${vector.name} 0 ${RESULT[expected.verdict]} ${expected.change_bps} ${expected.threshold_bps}`
}

export function vectorGroup(group) {
    vectorCoverage()
    const names = VECTOR_GROUPS[group]
    if (names === undefined) throw new Error(`no vector group ${group}`)
    const lines = names.map((name) => {
        const vector = VECTORS.vectors.find((entry) => entry.name === name)
        if (vector === undefined) throw new Error(`group ${group} names an unknown vector ${name}`)
        return vectorLine(vector)
    })
    lines.push(`cases ${names.length}`)
    return lines
}

export function vectorNames() {
    return vectorCoverage()
}

// --------------------------------------------------------------------- cli
//
// Last, so every mode it dispatches to is defined above it.

const [mode, argument] = process.argv.slice(2)

if (mode === 'group') {
    process.stdout.write(expectGroup(Number(argument)).join('\n') + '\n')
} else if (mode === 'sweep-source') {
    process.stdout.write(sweepSource(sweepCounts()))
} else if (mode === 'sweep-expect') {
    process.stdout.write(sweepExpect(sweepCounts()).join('\n') + '\n')
} else if (mode === 'vectors') {
    process.stdout.write(vectorGroup(Number(argument)).join('\n') + '\n')
} else if (mode === 'vector-names') {
    process.stdout.write(vectorNames().join(' ') + '\n')
} else if (mode === 'comparison') {
    process.stdout.write(comparisonGroup(Number(argument)).join('\n') + '\n')
} else if (mode === 'sweep-counts') {
    process.stdout.write(sweepCounts().join(' ') + '\n')
} else {
    process.stderr.write('usage: oracle.mjs <group N|sweep-source|sweep-expect|sweep-counts>\n')
    process.exit(2)
}

#!/usr/bin/env node
// Release claim manifest checker and evidence-pack generator.
//
// The manifest joins every published capability claim to the executable
// evidence that bounds it. This program is the only thing that decides whether
// that join still holds; `release/claims.json` is data and the generated pack
// under `artifacts/release-evidence/` is a presentation. Neither is a second
// editable source.
//
//   node tests/release/validate-claims.mjs schema
//   node tests/release/validate-claims.mjs validate [manifest]
//   node tests/release/validate-claims.mjs evidence <output-directory>
//
// Failures print one line per defect, each naming the claim and the repair, and
// exit 1. Usage errors exit 2.

import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { validateAgainstSchema } from '../lib/json-schema.mjs'
import { taskfileTasks, taskfileCommands } from '../lib/taskfile.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const SCHEMA_PATH = 'spec/release-claim.schema.json'
const MANIFEST_PATH = 'release/claims.json'
const README_PATH = 'README.md'
const BOOTSTRAP_MANIFEST_PATH = 'bootstrap/manifest.json'

// The second status registry (#1108). `bootstrap/manifest.json` records
// whether each bootstrap gate works; `release/claims.json` records what the
// repository publishes about the same capabilities. On 2026-08-09 the first
// flipped three B4/B5 keys to `working` while the second went on saying the
// fixed point was open, every gate stayed green, and review — not a gate —
// caught it.
//
// The gate vocabulary is exactly two words, so agreement is binary: a gate is
// `working` or it is `open`, and a claim either rests on executable evidence
// (`implemented`, `checkpoint`) or does not. Nothing here interprets the
// wording; a claim states which keys it depends on, and this asserts the two
// registries answer "does it work?" the same way.
const EXECUTABLE_STATES = new Set(['implemented', 'checkpoint'])

const PREFIX = 'release-claims'

function usage(message) {
    process.stderr.write(`${PREFIX}: ${message}\n`)
    process.exit(2)
}

function readRepositoryFile(relative) {
    return readFileSync(join(ROOT, relative), 'utf8')
}

function sha256(text) {
    return createHash('sha256').update(text).digest('hex')
}

// ---------------------------------------------------------------------------
// Repository facts
// ---------------------------------------------------------------------------

function trackedFiles() {
    const output = execFileSync('git', ['-C', ROOT, 'ls-files', '-z'], {
        encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
    })
    return new Set(output.split('\0').filter((entry) => entry !== ''))
}

// Capability rows published in a Markdown table. The first column is the
// wording this manifest must own, the second its status. Each row carries the
// header of its own table so a `Claim` column can be recognised and checked.
function publicRows(relative) {
    const rows = []
    let header = null
    let previous = null
    readRepositoryFile(relative).split('\n').forEach((line, index) => {
        if (!line.startsWith('|')) {
            header = null
            previous = null
            return
        }
        const cells = line.slice(1, -1).split(' | ').map((cell) => cell.trim())
        if (/^\|[\s:|-]+\|$/.test(line)) {
            header = previous
            return
        }
        if (header === null) {
            previous = cells
            return
        }
        rows.push({ cells, header, line: index + 1 })
    })
    return rows
}

// ---------------------------------------------------------------------------
// Semantic rules
// ---------------------------------------------------------------------------

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
        let hint = 'point the field at a tracked file, or `git add` the evidence you meant'
        try {
            if (statSync(join(ROOT, value)).isDirectory()) {
                hint = 'name a file inside that directory; a directory is not evidence'
            }
        } catch {
            // Not on disk at all: the default hint is the right one.
        }
        report.fail(subject, `${field} \`${value}\` is not a tracked repository file`, hint)
        return false
    }
    return true
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

// Every script a reproduction command can reach, as one string.
//
// The pack publishes each claim's `prerequisites` as an external dependency a
// reader is told to install. Nothing used to check that list against the
// commands it describes, so #1213 could migrate every call site off GNU
// `sha256sum` and leave three claims still demanding it -- a declared fact with
// a publisher and no reader. Reachability is followed transitively because a
// task names a check script and the real invocation is usually a level or two
// below that.
const SCRIPT_REFERENCE = /[A-Za-z0-9_@./-]+\.(?:sh|mjs|js)\b/g
const ROOT_VARIABLE = /^(?:PWD|ROOT|REPO_ROOT|SCRIPT_DIR)\//
// A script can dispatch by glob instead of by name: `for adapter in
// "$BACKENDS"/*.sh` names no adapter, so following explicit references alone
// concludes that `task decimal-arithmetic` never runs a C compiler when five
// backend adapters do.
//
// Resolving the glob's variable is deliberate rather than sweeping every
// directory the text mentions. The sweep was tried first and pulled 1,152 files
// and 15 MB into the reachable set for `task bootstrap`, which runs one script:
// at that size almost any tool name appears somewhere and the rule stops being
// able to fail.
const SHELL_ASSIGNMENT = /^\s*([A-Za-z_][A-Za-z0-9_]*)=(.+)$/gm
const SCRIPT_GLOB = /"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?\/\*\.(?:sh|mjs|js)/g

// The repo-relative directory a shell assignment's value points at, if any.
// Handles the `${VAR-"$ROOT/path"}` default spelling these scripts use.
function assignedDirectory(value) {
    const path = /\$\{?(?:PWD|ROOT|REPO_ROOT|SCRIPT_DIR)\}?\/([A-Za-z0-9_@.\/-]+)/.exec(value)
    return path ? path[1].replace(/["'}].*$/, '') : null
}

// Claims share reproduction commands -- `task native` backs three of them --
// and the walk reads a few hundred files, so without this the same traversal
// runs once per claim and the gate takes a minute instead of a second.
const reachableCache = new Map()

function reachableScriptText(command, taskCommands) {
    const cached = reachableCache.get(command)
    if (cached !== undefined) return cached
    const text = computeReachableScriptText(command, taskCommands)
    reachableCache.set(command, text)
    return text
}

function computeReachableScriptText(command, taskCommands) {
    const seeds = []
    const visitedTasks = new Set()
    const addTask = (name) => {
        if (visitedTasks.has(name)) return
        visitedTasks.add(name)
        const entry = taskCommands.get(name)
        if (entry === undefined) return
        for (const dependency of entry.deps) addTask(dependency)
        for (const call of entry.calls) addTask(call)
        seeds.push(...entry.cmds)
    }
    const task = /^task ([A-Za-z][A-Za-z0-9_-]*)$/.exec(command)
    if (task) addTask(task[1])
    else seeds.push(command)

    const seen = new Set()
    const pending = []
    const collected = []
    const consider = (reference) => {
        // Strip the shell spellings a script uses to reach its own root. `$` is
        // not part of a path match, so `"$ROOT/tests/x.sh"` arrives here as
        // `ROOT/tests/x.sh` and the variable name comes off by name rather than
        // by its sigil.
        const relative = reference.replace(ROOT_VARIABLE, '').replace(/^\.\//, '')
        if (relative === '' || relative.startsWith('/') || relative.includes('$')) return
        if (seen.has(relative)) return
        seen.add(relative)
        pending.push(relative)
    }
    const enqueue = (text) => {
        collected.push(text)
        // Directory-valued variables the script sets, so a reference written as
        // `"$NATIVE/check-pe32plus.sh"` resolves. `bootstrap/native/check.sh`
        // reaches every one of its sub-gates that way and names none of them
        // literally, so without this the walk stops at the first file.
        const assignments = new Map()
        for (const [, name, value] of text.matchAll(SHELL_ASSIGNMENT)) {
            const directory = assignedDirectory(value)
            if (directory !== null && !assignments.has(name)) assignments.set(name, directory)
        }
        for (const reference of text.match(SCRIPT_REFERENCE) ?? []) {
            const prefixed = /^([A-Za-z_][A-Za-z0-9_]*)\/(.+)$/.exec(reference)
            if (prefixed && assignments.has(prefixed[1])) {
                consider(`${assignments.get(prefixed[1])}/${prefixed[2]}`)
                continue
            }
            consider(reference)
        }
        // Resolve `"$VAR"/*.sh` against the same assignments, and enqueue that
        // directory for one level of expansion.
        for (const [, name] of text.matchAll(SCRIPT_GLOB)) {
            const directory = assignments.get(name)
            if (directory !== undefined) consider(directory)
        }
    }
    for (const seed of seeds) enqueue(seed)
    while (pending.length > 0) {
        const relative = pending.shift()
        const absolute = join(ROOT, relative)
        let stats
        try {
            stats = statSync(absolute)
        } catch {
            continue
        }
        if (stats.isDirectory()) {
            // One level only. A directory named by a script is a plausible
            // dispatch target; its whole subtree is not.
            let entries
            try {
                entries = readdirSync(absolute)
            } catch {
                continue
            }
            for (const entry of entries) {
                if (/\.(?:sh|mjs|js)$/.test(entry)) consider(`${relative}/${entry}`)
            }
            continue
        }
        if (!stats.isFile()) continue
        try {
            enqueue(readFileSync(absolute, 'utf8'))
        } catch {
            continue
        }
    }
    return collected.join('\n')
}

// A declared prerequisite must appear in something the command can actually
// run. This is deliberately a static reachability check rather than a sandboxed
// execution: it is cheap enough to run on every claim, and it catches the drift
// that matters -- a dependency that was removed from the scripts and left in
// the manifest.
function checkPrerequisites(report, subject, claim, taskCommands) {
    const prerequisites = claim.reproduction.prerequisites ?? []
    if (prerequisites.length === 0) return
    const text = reachableScriptText(claim.reproduction.command, taskCommands)
    for (const prerequisite of prerequisites) {
        // A plain word boundary, so `${CC:-cc}` counts as naming `cc`. Treating
        // `-` as a word character instead would miss exactly the shell default
        // spelling these scripts use to reach their tools.
        const pattern = new RegExp(`\\b${
            prerequisite.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
        }\\b`)
        if (!pattern.test(text)) {
            report.fail(subject,
                `declares the external prerequisite \`${prerequisite}\`, which no script reachable from \`${claim.reproduction.command}\` names`,
                `drop the prerequisite if the command no longer needs it, or name the tool in the script that uses it`)
        }
    }
}

// Reads the bootstrap gate statuses this manifest joins against. A missing or
// malformed file is reported once, as a manifest-level failure, rather than
// once per claim that names a key from it.
function bootstrapGateStatuses(report) {
    let parsed
    try {
        parsed = JSON.parse(readRepositoryFile(BOOTSTRAP_MANIFEST_PATH))
    } catch (error) {
        report.fail('manifest', `${BOOTSTRAP_MANIFEST_PATH} is missing or is not JSON (${error.message})`,
            `restore ${BOOTSTRAP_MANIFEST_PATH}; claims join its gate statuses`)
        return null
    }
    const gates = parsed.gates
    if (gates === null || typeof gates !== 'object' || Array.isArray(gates)) {
        report.fail('manifest', `${BOOTSTRAP_MANIFEST_PATH} has no \`gates\` object`,
            'keep the bootstrap gate statuses under a `gates` object')
        return null
    }
    return new Map(Object.entries(gates))
}

function validateManifest(manifest, schema, manifestPath = MANIFEST_PATH) {
    const report = new Report()

    const schemaErrors = []
    validateAgainstSchema(schema, schema, manifest, manifestPath, schemaErrors)
    for (const error of schemaErrors) {
        report.fail('manifest', error, `make the manifest satisfy ${SCHEMA_PATH}`)
    }
    if (!report.ok) return report

    const tracked = trackedFiles()
    const targets = taskfileTasks(ROOT)
    const taskCommands = taskfileCommands(ROOT)
    const bootstrapGates = bootstrapGateStatuses(report)
    const areas = new Set(manifest.areas)
    const declaredTargets = new Set(manifest.targets)

    for (const list of ['areas', 'targets']) {
        const values = manifest[list]
        const sorted = [...values].sort()
        if (JSON.stringify(values) !== JSON.stringify(sorted)) {
            report.fail('manifest', `\`${list}\` is not in sorted order`,
                `sort \`${list}\` so review diffs stay stable`)
        }
    }

    const seen = new Set()
    let previous = ''
    for (const claim of manifest.claims) {
        const subject = `claim \`${claim.id}\``

        if (seen.has(claim.id)) {
            report.fail(subject, 'duplicate claim id',
                'give every claim a unique id; two rows may not describe the same capability')
        }
        seen.add(claim.id)
        if (claim.id < previous) {
            report.fail(subject, 'claims are not in ascending id order',
                'sort `claims` by id so review diffs stay stable')
        }
        previous = claim.id

        if (!areas.has(claim.area)) {
            report.fail(subject, `unknown area \`${claim.area}\``,
                'declare the area in the manifest `areas` list, or use a declared one')
        }
        for (const target of claim.targets) {
            if (!declaredTargets.has(target)) {
                report.fail(subject, `unknown target \`${target}\``,
                    'declare the target in the manifest `targets` list, or use a declared one')
            }
        }

        for (const path of claim.specification) {
            checkPath(report, subject, 'specification entry', path, tracked)
        }

        const executable = claim.state === 'implemented' || claim.state === 'checkpoint'

        if (executable && claim.positive_gate === undefined) {
            report.fail(subject, `state \`${claim.state}\` has no positive gate`,
                'name the command and observation that prove it, or lower the state to `open`')
        }
        if (!executable && claim.positive_gate !== undefined) {
            report.fail(subject, `state \`${claim.state}\` carries a positive gate`,
                'a design, open or unsupported claim may not assert a passing gate; remove it or raise the state')
        }
        if (executable && claim.negative_boundary === undefined) {
            report.fail(subject, `state \`${claim.state}\` has no negative or limit boundary`,
                'name the fixture that fails outside the claim, so the boundary is observable')
        }
        if (claim.state === 'unsupported') {
            const kind = claim.negative_boundary?.kind
            if (kind !== 'rejection' && kind !== 'skip') {
                report.fail(subject, 'an unsupported claim needs an explicit rejection or skip observation',
                    'set `negative_boundary.kind` to `rejection` or `skip` and name what is observed')
            }
        }

        if (claim.positive_gate !== undefined) {
            checkCommand(report, subject, 'positive gate command',
                claim.positive_gate.command, tracked, targets)
        }
        if (claim.negative_boundary !== undefined) {
            checkPath(report, subject, 'negative boundary evidence',
                claim.negative_boundary.evidence, tracked)
        }
        if (claim.evidence_artifact !== undefined) {
            checkPath(report, subject, 'evidence artifact', claim.evidence_artifact.path, tracked)
        }

        const safety = claim.safety
        if (safety.classification === 'none') {
            for (const field of ['threat_model', 'negative_test']) {
                if (safety[field] !== undefined) {
                    report.fail(subject, `safety is \`none\` but declares ${field}`,
                        'classify the safety promise, or drop the field that implies one')
                }
            }
        } else {
            for (const field of ['threat_model', 'negative_test']) {
                if (safety[field] === undefined) {
                    report.fail(subject, `safety \`${safety.classification}\` is missing ${field}`,
                        'a safety claim must link a threat model and a negative test')
                } else {
                    checkPath(report, subject, `safety ${field}`, safety[field], tracked)
                }
            }
        }

        const performance = claim.performance
        if (performance.classification === 'budgeted') {
            for (const field of ['benchmark', 'environment', 'budget']) {
                if (performance[field] === undefined) {
                    report.fail(subject, `a budgeted performance claim is missing ${field}`,
                        'link a reproducible benchmark, its environment, and the budget it must hold')
                }
            }
            if (performance.benchmark !== undefined) {
                checkPath(report, subject, 'performance benchmark', performance.benchmark, tracked)
            }
        } else {
            for (const field of ['benchmark', 'environment', 'budget']) {
                if (performance[field] !== undefined) {
                    report.fail(subject, `performance is \`none\` but declares ${field}`,
                        'classify the claim as `budgeted`, or drop the field that implies a published number')
                }
            }
        }

        checkCommand(report, subject, 'reproduction command',
            claim.reproduction.command, tracked, targets)
        checkPrerequisites(report, subject, claim, taskCommands)

        // The join itself. `executable` above is already the claim's answer to
        // "does it work?"; each named gate must give the same answer.
        for (const key of claim.manifest_gates ?? []) {
            if (bootstrapGates === null) break
            const status = bootstrapGates.get(key)
            if (status === undefined) {
                report.fail(subject, `manifest gate \`${key}\` is not in ${BOOTSTRAP_MANIFEST_PATH}`,
                    `name a gate the bootstrap manifest declares, or drop the key if the gate was removed`)
                continue
            }
            if (status !== 'working' && status !== 'open') {
                report.fail(subject, `manifest gate \`${key}\` has unknown status ${JSON.stringify(status)}`,
                    'a bootstrap gate is `working` or `open`; teach this checker a new word before using one')
                continue
            }
            const gateWorks = status === 'working'
            if (gateWorks !== executable) {
                report.fail(subject,
                    `state \`${claim.state}\` contradicts ${BOOTSTRAP_MANIFEST_PATH} gate \`${key}\` (\`${status}\`)`,
                    gateWorks
                        ? `the bootstrap gate passes, so raise this claim to \`checkpoint\` or \`implemented\` — or flip \`${key}\` back to \`open\``
                        : `the bootstrap gate is open, so lower this claim to \`open\` — or flip \`${key}\` to \`working\` once it passes`)
            }
        }
    }

    // Coverage, the direction the incident ran in: a bootstrap gate that no
    // claim joins is a status nobody has to keep true. B7's
    // `diverse_double_compilation` landed as `working` with no published claim
    // at all, which is the same drift with the registries swapped.
    if (bootstrapGates !== null) {
        const joined = new Set()
        for (const claim of manifest.claims) {
            for (const key of claim.manifest_gates ?? []) joined.add(key)
        }
        for (const key of bootstrapGates.keys()) {
            if (!joined.has(key)) {
                report.fail(BOOTSTRAP_MANIFEST_PATH, `gate \`${key}\` is joined by no claim`,
                    'add the key to the `manifest_gates` of the claim it bounds, so flipping it cannot go unpublished')
            }
        }
    }

    // Coverage: every published capability row joins exactly one claim, and no
    // claim describes a row that is no longer published.
    const byWording = new Map()
    for (const claim of manifest.claims) {
        if (!byWording.has(claim.public_wording)) byWording.set(claim.public_wording, [])
        byWording.get(claim.public_wording).push(claim)
    }
    const publishedWordings = new Set()

    for (const source of manifest.public_sources) {
        if (!checkPath(report, 'manifest', 'public source', source, tracked)) continue
        for (const row of publicRows(source)) {
            const [wording, status] = row.cells
            publishedWordings.add(wording)
            const claims = byWording.get(wording) ?? []
            if (claims.length === 0) {
                report.fail(`${source}:${row.line}`,
                    `published capability ${JSON.stringify(wording)} has no manifest row`,
                    'add a claim owning this wording, or stop publishing it')
                continue
            }
            if (claims.length > 1) {
                report.fail(`${source}:${row.line}`,
                    `published capability ${JSON.stringify(wording)} joins ${claims.length} claims`,
                    `keep exactly one claim per published capability (${claims.map((c) => c.id).join(', ')})`)
                continue
            }
            if (claims[0].public_status !== status) {
                report.fail(`claim \`${claims[0].id}\``,
                    `public_status has drifted from ${source}:${row.line}`,
                    `set public_status to ${JSON.stringify(status)}, or correct the published row`)
            }

            // A published `Claim` column makes the join visible to a reader
            // rather than only to this checker, so it is held to the same
            // standard as the wording itself.
            const claimColumn = row.header.indexOf('Claim')
            if (claimColumn === -1) {
                report.fail(source,
                    'the published capability table has no `Claim` column',
                    'add a `Claim` column naming each row\'s stable claim id')
            } else if (row.cells[claimColumn] !== `\`${claims[0].id}\``) {
                report.fail(`${source}:${row.line}`,
                    `the published claim id ${JSON.stringify(row.cells[claimColumn])} does not match \`${claims[0].id}\``,
                    `set the Claim cell to \`${claims[0].id}\``)
            }
        }
    }

    for (const claim of manifest.claims) {
        if (!publishedWordings.has(claim.public_wording)) {
            report.fail(`claim \`${claim.id}\``,
                'public_wording matches no row in any public source',
                'restore the published wording, or remove the orphaned claim')
        }
    }

    // README states the same areas in prose. It may name fewer areas than the
    // manifest declares, but never one the manifest does not know.
    for (const row of publicRows(README_PATH)) {
        const area = row.cells[0].toLowerCase().replaceAll(' ', '-')
        if (!areas.has(area) && !row.cells[0].startsWith('[')) {
            report.fail(`${README_PATH}:${row.line}`,
                `published area ${JSON.stringify(row.cells[0])} is not a manifest area`,
                `add \`${area}\` to the manifest \`areas\` list, or rename the README row`)
        }
    }

    return report
}

// ---------------------------------------------------------------------------
// Evidence pack
//
// Deterministic by construction: rows are emitted in manifest order and every
// digest binds a repository input. Nothing here records a wall-clock time,
// because a timestamp would look like freshness without proving any.
// ---------------------------------------------------------------------------

function evidenceIndex(manifest, manifestText, schemaText) {
    const digests = new Map()
    const remember = (path) => {
        if (path !== undefined && !digests.has(path)) {
            digests.set(path, sha256(readRepositoryFile(path)))
        }
    }

    for (const source of manifest.public_sources) remember(source)
    for (const claim of manifest.claims) {
        claim.specification.forEach(remember)
        remember(claim.negative_boundary?.evidence)
        remember(claim.evidence_artifact?.path)
        remember(claim.safety.threat_model)
        remember(claim.safety.negative_test)
        remember(claim.performance.benchmark)
    }

    return {
        schema: 'kofun.release-evidence/v1',
        manifest_version: manifest.manifest_version,
        // The version this pack describes. A pack that did not say which
        // version it was generated for could be read as current for any of
        // them, which is the same defect as a claim without a gate: a true
        // statement with nothing binding it to what it is true of.
        version: readRepositoryFile('VERSION').trim(),
        inputs: {
            'VERSION': sha256(readRepositoryFile('VERSION')),
            [MANIFEST_PATH]: sha256(manifestText),
            [SCHEMA_PATH]: sha256(schemaText),
            // Claims now join this file's gate statuses (#1108), so it is an
            // input to the pack: editing a bootstrap gate moves the pack, the
            // way editing a claim already does.
            [BOOTSTRAP_MANIFEST_PATH]: sha256(readRepositoryFile(BOOTSTRAP_MANIFEST_PATH)),
        },
        states: manifest.claims.reduce((counts, claim) => {
            counts[claim.state] = (counts[claim.state] ?? 0) + 1
            return counts
        }, {}),
        claims: manifest.claims.map((claim) => ({
            id: claim.id,
            state: claim.state,
            area: claim.area,
            targets: claim.targets,
            positive_gate: claim.positive_gate?.command ?? null,
            negative_boundary: claim.negative_boundary?.evidence ?? null,
            reproduction: claim.reproduction.command,
            prerequisites: claim.reproduction.prerequisites,
        })),
        evidence_digests: Object.fromEntries([...digests].sort(([a], [b]) => (a < b ? -1 : 1))),
    }
}

function claimsPage(manifest) {
    const lines = [
        '# Release claims',
        '',
        `Generated from \`${MANIFEST_PATH}\` by \`task release-evidence\`. Do not edit.`,
        '',
        '| Claim | State | Area | Capability |',
        '|---|---|---|---|',
    ]
    for (const claim of manifest.claims) {
        lines.push(`| \`${claim.id}\` | ${claim.state} | ${claim.area} | ${claim.bounded_capability} |`)
    }
    lines.push('')
    return lines.join('\n')
}

function evidencePage(manifest) {
    const lines = [
        '# Release evidence',
        '',
        `Generated from \`${MANIFEST_PATH}\` by \`task release-evidence\`. Do not edit.`,
        '',
        '| Claim | Positive gate | Observation |',
        '|---|---|---|',
    ]
    for (const claim of manifest.claims) {
        if (claim.positive_gate === undefined) continue
        lines.push(`| \`${claim.id}\` | \`${claim.positive_gate.command}\` | ${claim.positive_gate.observation} |`)
    }
    lines.push('')
    return lines.join('\n')
}

function limitsPage(manifest) {
    const lines = [
        '# Release limits',
        '',
        `Generated from \`${MANIFEST_PATH}\` by \`task release-evidence\`. Do not edit.`,
        '',
        '## Claims with no executable gate',
        '',
        '| Claim | State | What is absent |',
        '|---|---|---|',
    ]
    for (const claim of manifest.claims) {
        if (claim.positive_gate !== undefined) continue
        lines.push(`| \`${claim.id}\` | ${claim.state} | ${claim.bounded_capability} |`)
    }
    lines.push('', '## Boundaries that fail outside a claim', '',
        '| Claim | Kind | Evidence | Observation |', '|---|---|---|---|')
    for (const claim of manifest.claims) {
        const boundary = claim.negative_boundary
        if (boundary === undefined) continue
        lines.push(`| \`${claim.id}\` | ${boundary.kind} | \`${boundary.evidence}\` | ${boundary.observation} |`)
    }
    lines.push('')
    return lines.join('\n')
}

function reproPage(manifest) {
    const prerequisites = new Set()
    for (const claim of manifest.claims) {
        for (const prerequisite of claim.reproduction.prerequisites) prerequisites.add(prerequisite)
    }
    const lines = [
        '# Reproducing the release evidence',
        '',
        `Generated from \`${MANIFEST_PATH}\` by \`task release-evidence\`. Do not edit.`,
        '',
        'From a clean checkout:',
        '',
        '```sh',
        'task verify',
        'task release-evidence',
        '```',
        '',
        '## External prerequisites',
        '',
        'A gate whose prerequisite is missing must report a skip. It must never',
        'report a pass it did not observe.',
        '',
        '| Prerequisite | Claims that need it |',
        '|---|---|',
    ]
    for (const prerequisite of [...prerequisites].sort()) {
        const users = manifest.claims
            .filter((claim) => claim.reproduction.prerequisites.includes(prerequisite))
            .map((claim) => `\`${claim.id}\``)
        lines.push(`| \`${prerequisite}\` | ${users.join(', ')} |`)
    }
    lines.push('', '## Per-claim reproduction', '', '| Claim | Command |', '|---|---|')
    for (const claim of manifest.claims) {
        lines.push(`| \`${claim.id}\` | \`${claim.reproduction.command}\` |`)
    }
    lines.push('')
    return lines.join('\n')
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

const [mode, argument] = process.argv.slice(2)
if (mode === undefined) usage('usage: validate-claims.mjs <schema|validate|evidence> [argument]')

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
    // Exercise every branch of the interpreter against the schema's own shape,
    // so an unsupported keyword is caught here rather than silently skipped
    // during a manifest run.
    const probe = []
    validateAgainstSchema(schema, schema.$defs.claim, {}, 'probe', probe)
    if (probe.length === 0) usage('the schema no longer rejects an empty claim')
    process.stdout.write(`PASS: ${SCHEMA_PATH} is a supported schema\n`)
    process.exit(0)
}

if (mode === 'validate') {
    const manifestPath = argument ?? MANIFEST_PATH
    let manifestText
    try {
        manifestText = manifestPath.startsWith('/')
            ? readFileSync(manifestPath, 'utf8')
            : readRepositoryFile(manifestPath)
    } catch (error) {
        usage(`cannot read ${manifestPath}: ${error.message}`)
    }
    let manifest
    try {
        manifest = JSON.parse(manifestText)
    } catch (error) {
        process.stderr.write(`${PREFIX}: ${manifestPath}: not valid JSON: ${error.message}. Repair: fix the syntax\n`)
        process.exit(1)
    }
    const report = validateManifest(manifest, schema, manifestPath)
    if (!report.ok) {
        for (const error of report.errors) process.stderr.write(`${error}\n`)
        process.exit(1)
    }
    process.stdout.write(
        `PASS: ${manifest.claims.length} release claims join their published wording and evidence\n`)
    process.exit(0)
}

if (mode === 'evidence') {
    if (argument === undefined) usage('usage: validate-claims.mjs evidence <output-directory>')
    const manifestText = readRepositoryFile(MANIFEST_PATH)
    const schemaText = readRepositoryFile(SCHEMA_PATH)
    const manifest = JSON.parse(manifestText)
    const report = validateManifest(manifest, schema)
    if (!report.ok) {
        for (const error of report.errors) process.stderr.write(`${error}\n`)
        process.stderr.write(`${PREFIX}: refusing to generate an evidence pack from an invalid manifest\n`)
        process.exit(1)
    }

    const outputDirectory = resolve(ROOT, argument)
    mkdirSync(outputDirectory, { recursive: true })
    const index = evidenceIndex(manifest, manifestText, schemaText)
    const pages = {
        'index.json': `${JSON.stringify(index, null, 2)}\n`,
        'CLAIMS.md': claimsPage(manifest),
        'EVIDENCE.md': evidencePage(manifest),
        'LIMITS.md': limitsPage(manifest),
        'REPRO.md': reproPage(manifest),
    }
    for (const [name, content] of Object.entries(pages)) {
        writeFileSync(join(outputDirectory, name), content)
    }
    const written = readdirSync(outputDirectory).sort()
    process.stdout.write(`PASS: release evidence pack written to ${argument} (${written.join(', ')})\n`)
    process.exit(0)
}

usage(`unknown mode \`${mode}\``)

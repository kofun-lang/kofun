#!/usr/bin/env node

// A grouped view over go-task's own JSON inventory. Taskfile.yml remains the
// source of truth for names and descriptions; this file owns only the smaller
// presentation taxonomy that go-task does not model. New visible tasks fail
// `--check` until a contributor puts them in exactly one group.

import { spawnSync } from 'node:child_process'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

export const GROUPS = Object.freeze([
    {
        title: 'Start here',
        hint: 'The shortest paths for learning, a focused change, and the final gate.',
        tasks: ['help', 'check', 'test', 'examples', 'tour', 'verify']
    },
    {
        title: 'Compiler and self-hosting',
        hint: 'Bootstrap seeds, Stage 2, fixed-point evidence, code generation, and ABIs.',
        tasks: [
            'compiler', 'bootstrap', 'selfhost-profile', 'selfhost-hir-identifiers',
            'selfhost-self-compile',
            'selfhost-driver-diagnostics', 'selfhost-generations',
            'selfhost-fixed-point', 'selfhost-diverse-double-compilation',
            'selfhost-declared-inputs', 'selfhost-b6-report',
            'selfhost-b6-policy', 'selfhost-b6-acquisition-identity',
            'selfhost-native', 'stage1-adapter', 'stage2', 'stage2-events', 'sha256-pair',
            'stage2-pair-coverage', 'stage2-pair-calls', 'stage2-pair-mirror',
            'native', 'native-host-evidence', 'wasm',
            'wasm-host-abi', 'wasm-host-profile', 'wasi-command-profile',
            'wasi-host-matrix-policy', 'atomic-write-authority-contract',
            'wasi-command-projection-contract', 'wasi-command-backend-shell', 'adt-match-v2-contract',
            'native-toolchain-contract', 'forbidden-requirements-census', 'machine-dependent-bounds',
            'wasm-object-arena',
            'wasm-list-v1', 'c-abi', 'bindgen-c', 'bindgen-c-import-boundary'
        ]
    },
    {
        title: 'Language semantics',
        hint: 'Syntax, typing, diagnostics, data types, numerics, and deterministic fuzzing.',
        tasks: [
            'diagnostics', 'fuzz', 'fuzz-sanitizer-reuse', 'unicode', 'patterns', 'adt', 'records',
            'aggregate-bridge',
            'move-assertion', 'usability-corpus', 'call-arguments',
            'call-arguments-spec',
            'call-arguments-surface',
            'affine-resumption', 'affine-resource-handle',
            'scoped-parallelism', 'concurrency-capture-contract',
            'schedule-trace', 'type-reduction-trace',
            'generics', 'const-generics', 'hm-levels', 'effect-inference',
            'pure-boundary', 'traits',
            'trait-dictionary-c11',
            'fixed-decimal-profile', 'decimal-backend-profiles',
            'generics-execution-profile', 'generic-proof-kernel-profile',
            'optional', 'optional-narrowing',
            'optional-construction', 'optional-coalescing', 'optional-pair',
            'text-results', 'int-bits', 'int-bits-lowering', 'list-int-values', 'record-values', 'text-escapes', 'unused-function', 'bounded-bytes', 'bytes-carrier', 'bytes-mutation', 'authority-type-carrier', 'while-list-int', 'else-if-chain',
            'list-int-signatures',
            'adt-exhaustiveness', 'adt-usefulness-v2',
            'enum-match-value', 'module-constants',
            'decimal', 'decimal-arithmetic',
            'date-time', 'syntax'
        ]
    },
    {
        title: 'Modules and interfaces',
        hint: 'Stable identities, imports, visibility, KIF, layout, and invalidation.',
        tasks: [
            'extern-c', 'module-inventory', 'module-symbols', 'imports-qualified', 'import-aliases', 'imports-selective', 'raw-imports', 'raw-re-exports',
            're-exports', 'kif-v1', 'stage2-kif-producer', 'visibility-filtering',
            'visibility-api-leaks', 'module-interface-artifact', 'incremental',
            'package-roots', 'source-file-mapping', 'namespaces', 'module-identity',
            'semantic-identity',
            'kif-module-trust-profile', 'kif-generics-profile', 'kif-generics-codec',
            'visibility-spec', 'visibility-syntax', 'visibility-access',
            're-exports-spec', 'aggregate-layout', 'reuse-candidate'
        ]
    },
    {
        title: 'Tooling and developer UX',
        hint: 'Discovery, sidecars, editors, frameworks, packages, and evidence adapters.',
        tasks: [
            'preflight',
            'task-help', 'gate-reachability', 'optional-tool-skips', 'discovery', 'discovery-sanitizer-reuse',
            'cli-framework', 'tui-framework', 'build-system',
            'verify-object-reuse', 'compile-census', 'packages', 'typed-sidecar-spec', 'typed-sidecar-codec',
            'typed-sidecar-captures', 'typed-sidecar-projector', 'upgrade-patch', 'documentation-index', 'ownership-view',
            'workspace-upgrade-transaction-decision',
            'artifact-qualification', 'lsp', 'roadmap',
            'graphify-setup', 'graphify-update'
        ]
    },
    {
        title: 'Runtime and standard library',
        hint: 'Host integration, measured costs, and the executable standard-library capability surface.',
        tasks: [
            'rust-shim', 'http', 'http-client-model', 'stdlib',
            'alloc-contract', 'kotest', 'tzdb', 'clock-adapters',
            'environment-authority-compiler-contract', 'host-process-authority-contract',
            'directory-authority-contract', 'http-carrier-profile',
            'stdlib-partial-target-support-decision',
            'process-capture-carrier-decision', 'directory-enumeration-carrier-decision',
            'benchmark-summary', 'benchmark-report-spec', 'benchmark-report-model',
            'benchmark-report-comparison', 'kofun-digest-model',
            'capabilities'
        ]
    },
    {
        title: 'Repository and release',
        hint: 'Repository policy, claim/evidence joins, decisions, generated evidence, and cleanup.',
        tasks: [
            'repository-check', 'assertions', 'audited-claim', 'digest',
            'tests-kofun',
            'example-law-evidence',
            'backlog', 'backlog-refresh',
            'release-claims', 'release-evidence', 'release-procedure',
            'rfc-registry', 'clean'
        ]
    }
])

function taskInventory(flag) {
    const result = spawnSync(
        'task', [flag, '--json', '--sort', 'none'],
        { cwd: ROOT, encoding: 'utf8', env: { ...process.env, NO_COLOR: '1' } }
    )
    if (result.status !== 0) {
        const detail = (result.stderr || result.stdout || 'no diagnostic').trim()
        throw new Error(`go-task ${flag} failed (${result.status}): ${detail}`)
    }
    let payload
    try {
        payload = JSON.parse(result.stdout)
    } catch (error) {
        throw new Error(`go-task ${flag} returned invalid JSON: ${error.message}`)
    }
    if (!Array.isArray(payload.tasks)) {
        throw new Error(`go-task ${flag} JSON has no tasks array`)
    }
    return payload.tasks
}

export function groupedTasks(visibleTasks) {
    const byName = new Map()
    for (const task of visibleTasks) {
        if (byName.has(task.name)) throw new Error(`duplicate visible task: ${task.name}`)
        if (typeof task.desc !== 'string' || task.desc.trim() === '') {
            throw new Error(`visible task has no description: ${task.name}`)
        }
        byName.set(task.name, task)
    }

    const assigned = new Set()
    const groups = GROUPS.map((group) => ({
        ...group,
        tasks: group.tasks.map((name) => {
            if (assigned.has(name)) throw new Error(`task appears in two help groups: ${name}`)
            const task = byName.get(name)
            if (task === undefined) throw new Error(`help group names a missing task: ${name}`)
            assigned.add(name)
            return task
        })
    }))

    const unassigned = [...byName.keys()].filter((name) => !assigned.has(name))
    if (unassigned.length !== 0) {
        throw new Error(`visible task is not in a help group: ${unassigned.join(', ')}`)
    }
    return groups
}

function words(text, width) {
    const lines = []
    let line = ''
    for (const word of text.trim().split(/\s+/u)) {
        if (line === '') line = word
        else if (line.length + 1 + word.length <= width) line += ` ${word}`
        else {
            lines.push(line)
            line = word
        }
    }
    if (line !== '') lines.push(line)
    return lines
}

function paint(enabled, code, text) {
    return enabled ? `\u001b[${code}m${text}\u001b[0m` : text
}

export function renderHelp(groups, options = {}) {
    const columns = Math.max(52, options.columns ?? process.stdout.columns ?? 100)
    const color = options.color ?? Boolean(
        process.stdout.isTTY && process.env.NO_COLOR === undefined && process.env.TERM !== 'dumb'
    )
    const taskWidth = Math.max(...groups.flatMap((group) => group.tasks.map((task) => task.name.length)))
    const output = [
        paint(color, '1;36', 'Kofun task guide'),
        paint(color, '2', 'Choose the smallest gate that proves your change.'),
        paint(color, '2', '─'.repeat(Math.min(columns, 72)))
    ]

    for (const group of groups) {
        output.push('', paint(color, '1;35', group.title))
        for (const line of words(group.hint, columns - 2)) {
            output.push(paint(color, '2', `  ${line}`))
        }
        for (const task of group.tasks) {
            const prefix = `  task ${task.name.padEnd(taskWidth)}  `
            const descriptionWidth = Math.max(20, columns - prefix.length)
            const descriptionLines = words(task.desc, descriptionWidth)
            const command = [
                paint(color, '2', '  task '),
                paint(color, '1;36', task.name.padEnd(taskWidth)),
                '  '
            ].join('')
            output.push(`${command}${descriptionLines[0]}`)
            for (const line of descriptionLines.slice(1)) {
                output.push(`${' '.repeat(prefix.length)}${line}`)
            }
        }
    }

    output.push(
        '',
        paint(color, '1;35', 'More detail'),
        '  task --list             Official flat list from go-task',
        '  task <name> --summary   Detailed metadata for one task',
        '  VERIFY_JOBS=1 task verify   Serialize the full gate when debugging'
    )
    return `${output.join('\n')}\n`
}

export function buildHelp() {
    const visible = taskInventory('--list')
    const all = taskInventory('--list-all')
    const visibleNames = new Set(visible.map((task) => task.name))
    const hidden = all.filter((task) => !visibleNames.has(task.name)).map((task) => task.name)
    if (hidden.length !== 1 || hidden[0] !== 'default') {
        throw new Error(`only default may omit desc; hidden tasks: ${hidden.join(', ') || '(none)'}`)
    }
    return { groups: groupedTasks(visible), count: visible.length }
}

function main() {
    const args = process.argv.slice(2)
    if (args.some((arg) => arg !== '--check')) {
        throw new Error(`usage: node tooling/task-help.mjs [--check]`)
    }
    const { groups, count } = buildHelp()
    if (args.includes('--check')) {
        process.stdout.write(`PASS: ${count} documented tasks belong to exactly one help group\n`)
    } else {
        process.stdout.write(renderHelp(groups))
    }
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    try {
        main()
    } catch (error) {
        process.stderr.write(`task help: ${error.message}\n`)
        process.exitCode = 1
    }
}

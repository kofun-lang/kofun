#!/usr/bin/env node
/*
 * Derive the shard partition from measured per-task wall time (#1684).
 *
 * `tests/verify-shards/timings.tsv` is the measurement: one `task<TAB>ns` row
 * per task `verify` runs, produced by a run with `KOFUN_VERIFY_TASK_TIMES` set.
 * This bins those rows into N shards with longest-processing-time first, the
 * greedy rule whose makespan is within 4/3 of optimal and, unlike a
 * name-ordered split, actually reads the numbers.
 *
 * A task and every verify task it lists in `deps:` form one cluster that is
 * binned whole. go-task runs a dependency inside whichever shard runs its
 * dependent task, so splitting a dependency across shards makes each of them
 * run it: the concatenated census would then count work twice that a single
 * `verify` invocation runs once (`run: once`), and the aggregate's contract
 * that the union reproduces the single-run census would not hold.
 *
 * The partition is a derived artifact, so it is regenerated, never hand-edited;
 * `--check` re-derives it and fails if the committed copy differs, which is the
 * same regenerate-never-merge rule `artifacts/release-evidence/index.json`
 * carries. The coverage half (every verify task named exactly once) is
 * `check.sh`'s, and stays independent of this generator.
 *
 * Usage:
 *   node partition.mjs                 # write partition.tsv from timings.tsv
 *   node partition.mjs --shards 4
 *   node partition.mjs --check         # fail if partition.tsv is stale
 */

import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { taskfileCommands } from '../lib/taskfile.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '..', '..')

const args = process.argv.slice(2)
function flagValue(name, fallback) {
    const at = args.indexOf(name)
    if (at === -1) return fallback
    const value = args[at + 1]
    if (value === undefined) {
        process.stderr.write(`partition.mjs: ${name} needs a value\n`)
        process.exit(2)
    }
    return value
}

const check = args.includes('--check')
const shards = Number.parseInt(flagValue('--shards', '4'), 10)
const timingsPath = flagValue('--timings', path.join(HERE, 'timings.tsv'))
const outPath = flagValue('--out', path.join(HERE, 'partition.tsv'))

if (!Number.isInteger(shards) || shards < 1) {
    process.stderr.write('partition.mjs: --shards must be a positive integer\n')
    process.exit(2)
}

const listed = spawnSync('sh', [
    path.join(ROOT, 'tests', 'pair-coverage', 'measure.sh'),
    '--print-verify-tasks',
], { encoding: 'utf8' })
if (listed.status !== 0) {
    process.stderr.write(listed.stderr || 'partition.mjs: verify task list unreadable\n')
    process.exit(1)
}
const verifyTasks = listed.stdout.split('\n').filter(Boolean)

if (!fs.existsSync(timingsPath)) {
    process.stderr.write(
        `partition.mjs: missing ${timingsPath}\n` +
        '  Record it first with KOFUN_VERIFY_TASK_TIMES set on a verify run.\n',
    )
    process.exit(1)
}

const timing = new Map()
for (const line of fs.readFileSync(timingsPath, 'utf8').split('\n')) {
    if (!line || line.startsWith('#')) continue
    const [task, ns] = line.split('\t')
    if (!task || ns === undefined) {
        process.stderr.write(`partition.mjs: malformed timing row: ${line}\n`)
        process.exit(1)
    }
    const value = Number(ns)
    if (!Number.isFinite(value) || value < 0) {
        process.stderr.write(`partition.mjs: non-numeric timing for ${task}\n`)
        process.exit(1)
    }
    timing.set(task, value)
}

const missing = verifyTasks.filter((task) => !timing.has(task))
if (missing.length > 0) {
    process.stderr.write('partition.mjs: these verify tasks have no measured time:\n')
    for (const task of missing) process.stderr.write(`  ${task}\n`)
    process.exit(1)
}
const extra = [...timing.keys()].filter((task) => !verifyTasks.includes(task))
if (extra.length > 0) {
    process.stderr.write('partition.mjs: timings name tasks outside the verify set:\n')
    for (const task of extra) process.stderr.write(`  ${task}\n`)
    process.exit(1)
}

// Longest processing time first over dependency clusters, deterministic
// tie-break by the cluster's first task name.
const commands = taskfileCommands(ROOT)
const verifySet = new Set(verifyTasks)
const parent = new Map(verifyTasks.map((task) => [task, task]))
const find = (task) => {
    let root = task
    while (parent.get(root) !== root) root = parent.get(root)
    while (parent.get(task) !== root) {
        const next = parent.get(task)
        parent.set(task, root)
        task = next
    }
    return root
}
for (const task of verifyTasks) {
    for (const dep of commands.get(task)?.deps ?? []) {
        if (!verifySet.has(dep)) continue
        const a = find(task)
        const b = find(dep)
        if (a !== b) parent.set(a, b)
    }
}
const clusters = new Map()
for (const task of verifyTasks) {
    const root = find(task)
    const cluster = clusters.get(root) ?? { members: [], time: 0 }
    cluster.members.push(task)
    cluster.time += timing.get(task)
    clusters.set(root, cluster)
}
const ordered = [...clusters.values()].sort((a, b) => {
    const byTime = b.time - a.time
    if (byTime !== 0) return byTime
    return [...a.members].sort()[0].localeCompare([...b.members].sort()[0])
})
const loads = new Array(shards).fill(0)
const assignment = new Map()
for (const cluster of ordered) {
    let target = 0
    for (let i = 1; i < shards; i += 1) {
        if (loads[i] < loads[target]) target = i
    }
    for (const task of cluster.members) assignment.set(task, target)
    loads[target] += cluster.time
}

const header = [
    '# The shard partition `verify` runs under (#1684).',
    '#',
    '# Generated by `node tests/verify-shards/partition.mjs` from',
    '# `tests/verify-shards/timings.tsv`, the per-task wall time a measured run',
    '# recorded. Do not hand-edit: `--check` re-derives it and the coverage gate',
    '# `tests/verify-shards/check.sh` refuses a task in no shard, a shard task',
    '# outside the verify set, and a task in two shards.',
    '#',
    `# shards: ${shards}`,
    ...loads.map((ns, i) =>
        `# shard ${i}: ${(ns / 1e9).toFixed(1)} s`),
    '# task\tshard',
].join('\n')

const rows = [...verifyTasks].sort().map(
    (task) => `${task}\t${assignment.get(task)}`,
)
const rendered = `${header}\n${rows.join('\n')}\n`

if (check) {
    const current = fs.existsSync(outPath) ? fs.readFileSync(outPath, 'utf8') : ''
    if (current !== rendered) {
        process.stderr.write(
            `FAIL: ${outPath} is stale; regenerate with ` +
            '`node tests/verify-shards/partition.mjs`\n',
        )
        process.exit(1)
    }
    process.stdout.write('PASS: the shard partition matches its measured timings\n')
    process.exit(0)
}

fs.writeFileSync(outPath, rendered)
const worst = Math.max(...loads)
const best = Math.min(...loads)
process.stdout.write(
    `PASS: wrote ${rows.length} tasks across ${shards} shards ` +
    `(longest ${(worst / 1e9).toFixed(1)} s, shortest ${(best / 1e9).toFixed(1)} s)\n`,
)

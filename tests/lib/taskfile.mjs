// The task set the repository's manifests resolve their commands against.
//
// `release/claims.json` and `rfcs/index.json` both name the gate that proves a
// claim or an implementation, and both must reject a command naming a task
// that does not exist. They carried an identical copy of this reader while the
// entry point was a Makefile; identical copies cannot disagree, so no gate
// could catch a drift between them (DD-022). One reader, imported twice.
//
// The Taskfile this parses is generated to a fixed shape: task names are the
// only two-space-indented `name:` keys under the top-level `tasks:` mapping.
// Parsing that shape directly keeps the validators dependency-free, which is
// the same reason `json-schema.mjs` exists beside this file.

import { readFileSync } from 'node:fs'

const TASKFILE = 'Taskfile.yml'

export function taskfileTasks(repositoryRoot) {
    const source = readFileSync(`${repositoryRoot}/${TASKFILE}`, 'utf8')
    const tasks = new Set()
    let inTasks = false
    for (const line of source.split('\n')) {
        if (/^tasks:\s*$/.test(line)) {
            inTasks = true
            continue
        }
        if (!inTasks) continue
        // A non-indented, non-blank line ends the mapping.
        if (line.trim() !== '' && !/^\s/.test(line)) break
        const match = /^ {2}([A-Za-z][A-Za-z0-9_-]*):\s*$/.exec(line)
        if (match) tasks.add(match[1])
    }
    if (tasks.size === 0) {
        throw new Error(`${TASKFILE} declares no tasks; the parser or the file is wrong`)
    }
    return tasks
}

// What each task actually runs: its `cmds:` in declaration order, and the
// `deps:` that run before them.
//
// `taskfileTasks` above answers "does this task exist?". Answering "what does
// running it execute?" needs both lists, and #1395 needs that to check a
// declared external prerequisite against the scripts it is claimed to be
// required by. `deps:` is not optional detail: `task records` compiles nothing
// itself and reaches its C11 bridge entirely through `aggregate-bridge`.
// Same fixed generated shape, same parser, so the two readers cannot disagree
// about where a task begins and ends.
export function taskfileCommands(repositoryRoot) {
    const source = readFileSync(`${repositoryRoot}/${TASKFILE}`, 'utf8')
    const commands = new Map()
    const lines = source.split('\n')
    let inTasks = false
    let current = null
    let inCommands = false
    for (let index = 0; index < lines.length; index += 1) {
        const line = lines[index]
        if (/^tasks:\s*$/.test(line)) {
            inTasks = true
            continue
        }
        if (!inTasks) continue
        if (line.trim() !== '' && !/^\s/.test(line)) break
        const task = /^ {2}([A-Za-z][A-Za-z0-9_-]*):\s*$/.exec(line)
        if (task) {
            current = task[1]
            commands.set(current, { cmds: [], deps: [] })
            inCommands = false
            continue
        }
        if (current === null) continue
        const deps = /^ {4}deps:\s*\[(.*)\]\s*$/.exec(line)
        if (deps) {
            for (const name of deps[1].split(',')) {
                const trimmed = unquote(name.trim())
                if (trimmed !== '') commands.get(current).deps.push(trimmed)
            }
            inCommands = false
            continue
        }
        if (/^ {4}cmds:\s*$/.test(line)) {
            inCommands = true
            continue
        }
        // Any other four-space key ends the `cmds:` list.
        if (/^ {4}[A-Za-z]/.test(line)) {
            inCommands = false
            continue
        }
        if (!inCommands) continue
        const entry = /^ {6}- (.*)$/.exec(line)
        if (!entry) continue
        const text = entry[1].trim()
        // `- cmd: |-` opens a block scalar whose body is indented under it. A
        // parser that stopped at the marker would record the literal `cmd: |-`
        // as the command and silently see none of the script it runs.
        const block = /^cmd:\s*[|>][-+]?\s*$/.test(text)
        if (block) {
            const body = []
            while (index + 1 < lines.length) {
                const next = lines[index + 1]
                if (next.trim() !== '' && !/^ {8,}/.test(next)) break
                body.push(next.trim())
                index += 1
            }
            commands.get(current).cmds.push(body.join('\n'))
            continue
        }
        const inline = /^cmd:\s*(.+)$/.exec(text)
        commands.get(current).cmds.push(unquote(inline ? inline[1].trim() : text))
    }
    if (commands.size === 0) {
        throw new Error(`${TASKFILE} declares no tasks; the parser or the file is wrong`)
    }
    return commands
}

function unquote(value) {
    const quoted = /^"(.*)"$/.exec(value) ?? /^'(.*)'$/.exec(value)
    return quoted ? quoted[1] : value
}

export const TASKFILE_PATH = TASKFILE

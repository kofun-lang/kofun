/*
 * Does an independent builder need this tool to run `task verify`?
 *
 * The census counts uses. A count of uses is not the number B6 and B7 are
 * stated in terms of — those ask what someone reproducing a release must
 * obtain — and the two differ in both directions:
 *
 *   - `scripts/graphify.sh` invokes `python` six times and no gate runs it;
 *   - `examples/rust-shim/check.sh` invokes `cargo`, and `rust-shim` is in the
 *     149-name verify list, and the script exits 1 when cargo is absent. A
 *     reading of that row as "the permitted foreign-adapter boundary, exercised
 *     on purpose" survived two sessions before anyone opened the file (#1459).
 *
 * So each use gets a derived `need`:
 *
 *   `required`   on the verify path, and not skippable
 *   `optional`   on the verify path, but every use is behind an availability
 *                guard whose failure branch skips instead of exiting non-zero
 *   `off-path`   every task naming the file is one nothing runs
 *   `unknown`    the rules below could not tell
 *
 * `unknown` is a value, not a default that means `optional`. A rule that
 * resolved its hard cases downward would shrink the headline number for the
 * reason least connected to the tree, which is the failure this whole
 * subsystem exists to remove.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import { withoutComments } from './detect.mjs'

export const NEEDS = new Set(['required', 'optional', 'off-path', 'unknown'])

/*
 * This tool names other files for a living — in its fixtures, in its
 * assertions, and in the sentence you are reading. None of that runs them.
 *
 * The census's self-test pins the derivation with
 * `['python', 'scripts/graphify.sh', 'off-path']`, in code rather than in a
 * comment, so comment-stripping does not remove it — and that one array
 * element made `scripts/graphify.sh` reachable and flipped the very row the
 * assertion was checking. The test asserting a fact was what made it false.
 *
 * So a file here may reach its own neighbours — `check.mjs` really does import
 * `reach.mjs` — and may reach nothing outside this directory.
 */
const THIS_TOOL = 'tooling/forbidden-requirements/'
const crossesOutOfThisTool = (from, to) =>
    from.startsWith(THIS_TOOL) && !to.startsWith(THIS_TOOL)

/* ------------------------------------------------------- the verify path */

/*
 * Task reachability is `tooling/gate-reachability/`'s subject and its ledger is
 * the answer, so it is read rather than recomputed. A task in `unreachable.tsv`
 * is one that verify, CI, another task, and every script all fail to run —
 * which is exactly the predicate this column needs, already measured and
 * already gated in both directions.
 */
function unreachableTasks(root) {
    const body = readFileSync(join(root, 'tooling', 'gate-reachability', 'unreachable.tsv'), 'utf8')
    const names = new Set()
    for (const line of body.split('\n')) {
        if (line.trim() === '' || line.startsWith('#')) continue
        names.add(line.split('\t')[0].trim())
    }
    return names
}

/* Every task the Taskfile defines, with the text of its own block. */
function taskBlocks(root) {
    const lines = readFileSync(join(root, 'Taskfile.yml'), 'utf8').split('\n')
    const blocks = new Map()
    let current = null
    for (const line of lines) {
        const start = /^ {2}([a-z][a-z0-9-]*):\s*$/.exec(line)
        if (start !== null) {
            current = start[1]
            blocks.set(current, '')
            continue
        }
        if (current !== null) blocks.set(current, `${blocks.get(current)}${line}\n`)
    }
    return blocks
}

/*
 * A file is on the verify path when a task that something runs names it, or
 * when a script that is itself on the path names it. The second clause is not
 * optional: `tests/interop/bindgen-c/check-sanitizers.sh` is named by no task
 * at all and runs on every verify, because `check.sh` runs it.
 *
 * Naming is matched three ways, each added because the previous one missed a
 * real caller: the repository-relative path, that path with any one segment
 * replaced by a variable, and a bare basename from a file in the same
 * directory. All three are substring matches, which also catches `. lib.sh`
 * sourcing — the shape a `sh <file>` pattern misses.
 */
export function reachability(root, rawFiles) {
    const unreachable = unreachableTasks(root)
    const blocks = taskBlocks(root)

    /*
     * Reachability reads code, not prose, for the same reason the detectors do.
     * This file's own comments name `scripts/graphify.sh` as the example of an
     * off-path script — and with comments left in, that sentence made it
     * reachable and the `off-path` count went to zero. Third time today that a
     * rule reported its own documentation as a finding.
     */
    const files = rawFiles.map((f) => ({ ...f, body: withoutComments(f.path, f.body) }))

    const namedBy = new Map()        /* path -> set of tasks naming it */
    for (const { path } of files) namedBy.set(path, new Set())
    for (const [task, text] of blocks) {
        for (const { path } of files) {
            if (text.includes(path)) namedBy.get(path).add(task)
        }
    }

    const onPath = new Set()
    for (const [path, tasks] of namedBy) {
        if ([...tasks].some((task) => !unreachable.has(task))) onPath.add(path)
    }

    /*
     * A workflow is run by GitHub, not by anything in the tree, so no task and
     * no script will ever name it. Left out, the four workflows read as
     * `unnamed` — and they are where `task` itself is invoked, which would put
     * the runner's own most important callers in the column's "could not tell"
     * bucket.
     */
    for (const { path } of files) {
        if (/^\.github\/workflows\/[^/]+\.ya?ml$/.test(path)) onPath.add(path)
    }

    /*
     * A JavaScript module names its neighbour relatively — `from './reach.mjs'`
     * — so the repository-relative path never appears in the importer and a
     * substring search sees nothing. Left out, every `model.mjs` under `spec/`
     * beside its `check.mjs` reads as `unnamed`, including this file, imported
     * by the checker four lines from where its verdict is used.
     */
    const importsOf = (file) => {
        const dir = file.path.includes('/') ? file.path.slice(0, file.path.lastIndexOf('/')) : ''
        const out = []
        for (const m of file.body.matchAll(/['"](\.{1,2}\/[^'"]+)['"]/g)) {
            const parts = `${dir}/${m[1]}`.split('/')
            const stack = []
            for (const part of parts) {
                if (part === '.' || part === '') continue
                if (part === '..') stack.pop()
                else stack.push(part)
            }
            out.push(stack.join('/'))
        }
        return out
    }

    const quote = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const dirOf = (p) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '')
    const baseOf = (p) => p.slice(p.lastIndexOf('/') + 1)

    /*
     * One segment of the path may be anything. That single allowance covers
     * every shape a caller actually writes:
     *
     *     sh "$stdlib_dir/testing/tests/verify.sh"     leading segment
     *     sh "$ROOT/tests/diagnostics/$suite/run.sh"   interior segment
     *
     * Exactly one, and never the basename, because two wildcards or a free
     * basename would let `run.sh` match thirty different callers and the
     * reachability would be decided by a filename.
     */
    const patterns = new Map()
    const pathPattern = (path) => {
        if (patterns.has(path)) return patterns.get(path)
        const segments = path.split('/')
        const alternatives = []
        for (let i = 0; i < segments.length - 1; i += 1) {
            const copy = segments.slice()
            copy[i] = '[^/"\'\\s]+'
            alternatives.push(copy.map((s, j) => (j === i ? s : quote(s))).join('/'))
        }
        const re = new RegExp(`(^|[/"'\\s])(${[quote(path), ...alternatives].join('|')})`)
        patterns.set(path, re)
        return re
    }

    /*
     * And a caller in the same directory names its neighbour by basename alone
     * — `node "$HERE/check.mjs"`. Scoped to one directory, that is unambiguous;
     * unscoped it would match everything.
     */
    const namesFile = (caller, path) =>
        pathPattern(path).test(caller.body) ||
        (dirOf(caller.path) === dirOf(path) && caller.body.includes(`/${baseOf(path)}`))

    /*
     * Two indexes, both built once, because the closure below used to rebuild
     * their work on every pass (#1493).
     *
     * The loop was `for each unresolved candidate, scan every on-path body`,
     * so the cost was iterations x candidates x files x body length and each
     * body was re-scanned for each candidate. Measured on a quiet machine, that
     * one loop was 2.47 s of the checker's 3.01 s — 82%.
     *
     * The filter is exact rather than approximate, which is what lets it change
     * the cost without changing an answer: **every rule above requires the
     * basename to appear literally.** Only a non-final segment may be
     * wildcarded, the same-directory rule tests `/` + basename, and a resolved
     * relative import ends in it. So a file whose text does not contain the
     * basename cannot name the candidate under any of the three, and skipping
     * it is not a heuristic.
     */
    /*
     * The needles are the candidate basenames themselves, not a guess at what a
     * filename looks like. The first version of this index extracted
     * `[\w.@+-]+\.(sh|mjs|js|ya?ml)` and lost every file that has no
     * extension — `bin/kofun-digest` and `tooling/lsp/kofun-lsp` are found by
     * shebang, and three rows flipped to `unknown`. The census caught it in one
     * diff, which is what a both-directions ledger is for.
     *
     * Longest first, so a candidate whose basename is a suffix of another's is
     * not consumed by it.
     */
    const needles = [...new Set(files.map((f) => baseOf(f.path)))]
        .sort((a, b) => b.length - a.length)
    const needleRe = new RegExp(needles.map(quote).join('|'), 'g')
    const basenamesIn = (body) => new Set(body.match(needleRe) ?? [])
    const callersByBasename = new Map()
    const importsCache = new Map()
    for (const file of files) {
        importsCache.set(file.path, importsOf(file))
        for (const base of basenamesIn(file.body)) {
            if (!callersByBasename.has(base)) callersByBasename.set(base, [])
            callersByBasename.get(base).push(file)
        }
        for (const target of importsCache.get(file.path)) {
            const base = baseOf(target)
            if (!callersByBasename.has(base)) callersByBasename.set(base, [])
            if (!callersByBasename.get(base).includes(file)) callersByBasename.get(base).push(file)
        }
    }

    for (;;) {
        let grew = false
        for (const { path } of files) {
            if (onPath.has(path)) continue
            /*
             * The Taskfile may not propagate. It names every script in the
             * tree, so treating it as an on-path caller marks everything
             * on-path and silently undoes the `unreachable.tsv` filtering one
             * step above — `scripts/graphify.sh` came back as `required`
             * because `Taskfile.yml` mentions it, which is exactly the fact
             * that step had already decided did not count.
             */
            const candidates = callersByBasename.get(baseOf(path)) ?? []
            const reached = candidates.some(
                (f) => f.path !== path && onPath.has(f.path) &&
                    !/(^|\/)Taskfile\.ya?ml$/.test(f.path) &&
                    !crossesOutOfThisTool(f.path, path) &&
                    (namesFile(f, path) || importsCache.get(f.path).includes(path)),
            )
            if (reached) {
                onPath.add(path)
                grew = true
            }
        }
        if (!grew) break
    }

    /*
     * Three outcomes, and the third is the one a careless version loses.
     *
     *   `on`        something that runs, runs it
     *   `off-path`  a task names it and every such task is one nothing runs
     *   `unnamed`   nothing names it textually
     *
     * `unnamed` must not collapse into `off-path`. A file invoked through a
     * variable path is invisible to a substring search, and calling it
     * off-path would shrink the "required" count for a reason that is about
     * the search rather than about the tree
     * — a negative search result is a fact about the search.
     */
    const where = new Map()
    for (const { path } of files) {
        if (onPath.has(path)) where.set(path, 'on')
        else if (namedBy.get(path).size !== 0) where.set(path, 'off-path')
        else where.set(path, 'unnamed')
    }
    return { where, namedBy, unreachable }
}

/* ------------------------------------------------------------ the guards */

/*
 * `command -v` is how every script in this tree asks whether a tool exists.
 * Two shapes, and they mean opposite things:
 *
 *     command -v "$required" >/dev/null 2>&1 || {      # rust-shim
 *         printf '…' >&2
 *         exit 1                                       #  -> required
 *     }
 *
 *     if command -v rustc >/dev/null 2>&1; then        # usability corpus
 *         …
 *     else
 *         printf '…SKIP: no rustc…'                    #  -> optional
 *     fi
 *
 * The failure branch is read within a bounded window rather than parsed. That
 * is a heuristic, and the honest consequence is `unknown` when the window
 * decides nothing — never a quiet fallback to `optional`.
 */
const WINDOW = 12
/*
 * `fail` is matched as a substring rather than a word, because the house
 * helper is `assert_fail` and `\bfail\b` does not match inside it — `_` is a
 * word character. That one boundary put 143 rows into `unknown` on the first
 * run, every one of them an ordinary `command -v "$tool" || assert_fail`.
 *
 * The looseness is deliberate and one-directional: a skip branch whose message
 * happens to contain "fail" is read as required, which over-counts what a
 * builder must obtain. That is the safe direction for this particular number.
 */
const FAILS_CLOSED = /\bexit\s+[1-9]|\breturn\s+[1-9]|fail|\bdie\b|\babort\b/
const SKIPS = /\bSKIP\b|\bskip(ped|ping)?\b|\bcontinue\b/

/* The tool names a requirement is spelled with, for guard matching only. */
const SPELLINGS = {
    cc: ['cc', 'gcc', 'clang', '\\$CC', 'CC'],
    'c++': ['c\\+\\+', 'g\\+\\+', 'clang\\+\\+', 'CXX'],
    assembler: ['as', 'nasm', 'yasm'],
    'system-linker': ['ld', 'lld'],
    rustc: ['rustc'],
    cargo: ['cargo'],
    zig: ['zig'],
    node: ['node'],
    python: ['python3?'],
    'go-task': ['task'],
    'system-sdk': ['xcrun', 'xcodebuild', 'pkg-config'],
    'import-library': ['dlltool'],
    'shell-build-driver': [],
    'non-kofun-build-language': [],
}

/*
 * Which lines are the *failure* branch depends on the shape, and reading the
 * wrong ones inverts the answer. For `guard || { … }` the failure branch
 * follows immediately. For `if guard; then … else … fi` it is the `else`, and
 * reading forward from the guard lands in the **success** branch instead —
 * which is where the tool actually gets used, so it is full of the tool's own
 * error handling. That mistake read `tests/usability/check.sh` as `required`
 * when it prints `SKIP: no rustc` and carries on.
 *
 * An `if` with no `else` is a skip by construction: the block simply does not
 * run.
 */
function readFailureBranch(lines, i) {
    const guard = lines[i]
    if (/^\s*(el)?if\s/.test(guard) || /;\s*then\s*$/.test(guard)) {
        for (let j = i + 1; j < Math.min(lines.length, i + 60); j += 1) {
            if (/^\s*fi\b/.test(lines[j])) return 'optional'
            if (/^\s*else\b/.test(lines[j])) {
                /*
                 * The else-branch ends at its `fi`, and the window must end
                 * there too. A fixed 12 lines ran past the `fi` in
                 * `tests/usability/check.sh` into the *next* guard's body,
                 * picked up its `fail`, and reported a branch that prints
                 * `SKIP: no rustc` as failing closed.
                 */
                let end = j + 1
                while (end < lines.length && end < j + WINDOW && !/^\s*fi\b/.test(lines[end])) {
                    end += 1
                }
                const branch = lines.slice(j, end).join('\n')
                if (FAILS_CLOSED.test(branch)) return 'required'
                if (SKIPS.test(branch)) return 'optional'
                return 'unknown'
            }
        }
        return 'unknown'
    }
    const branch = lines.slice(i, i + WINDOW).join('\n')
    if (FAILS_CLOSED.test(branch)) return 'required'
    if (SKIPS.test(branch)) return 'optional'
    return 'unknown'
}

export function guardVerdict(body, requirement) {
    const spellings = SPELLINGS[requirement] ?? []
    if (spellings.length === 0) return 'required'

    const lines = body.split('\n')
    const verdicts = []
    for (let i = 0; i < lines.length; i += 1) {
        if (!/command\s+-v/.test(lines[i])) continue
        /*
         * The guard must name this tool. `for required in cargo rustc "$CC"` puts
         * the names on the `for` line and the check one line down, so the two
         * preceding lines count as part of the guard.
         */
        const context = lines.slice(Math.max(0, i - 2), i + 1).join('\n')
        const names = spellings.some((s) => new RegExp(`(^|[^\\w-])${s}([^\\w-]|$)`).test(context))
        if (!names) continue

        verdicts.push(readFailureBranch(lines, i))
    }

    if (verdicts.length === 0) return 'required'
    if (verdicts.includes('required')) return 'required'
    if (verdicts.includes('unknown')) return 'unknown'
    return 'optional'
}

/* --------------------------------------------------------------- the join */

export function needOf({ path, body, requirement, kind }, where) {
    const place = where.get(path)
    if (place === 'off-path') return 'off-path'
    if (place === 'unnamed') return 'unknown'
    /*
     * A `source` row is the file's own language. Nothing guards being written
     * in shell, so on the verify path it is required and there is no third
     * possibility.
     */
    if (kind === 'source') return 'required'
    return guardVerdict(body, requirement)
}

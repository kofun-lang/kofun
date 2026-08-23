/*
 * docs/RELEASING.md's blocks cannot report PASS while failing (#1603).
 *
 * Cutting v0.11.0-seed, step 7's block reported
 *
 *     PASS: remote tag v0.11.0-seed = 41251110cffb36abed1c61a13a31ddae798de441
 *
 * while no such tag existed on the remote. Two causes stacked. The block ran in
 * a shell where `set -eu` was not in effect, so every `test` in it was advisory
 * and the summary line ran regardless; and zsh read `:r` out of
 * `"refs/tags/$tag:refs/tags/$tag"`, expanding it to
 * `refs/tags/v0.11efs/tags/v0.11.0-seed`, which is the push that failed and was
 * then covered.
 *
 * The document already warns, in step 1, that a pipeline ending in `tail`
 * reports `tail`'s status and makes a failing run read as green. This gate is
 * that warning applied to the file that carries it.
 *
 * WHAT IT ENFORCES, and why neither half is enough alone:
 *
 *   1. every `sh` block sources `release/fail-closed.sh` before it runs
 *      anything else, so a shell that would swallow failures is refused at the
 *      first line rather than at the summary;
 *   2. every `test` and every top-level `git`, `gh` or `task` in those blocks
 *      carries its own failure action, because the guard alone cannot help a
 *      wrapper that starts a fresh shell per command -- which is what the
 *      measurement below says actually happened;
 *   3. no `$name` is interpolated immediately before a colon;
 *   4. every block parses -- nothing else in the tree asks whether this
 *      document's shell is shell, and a mangled quote would otherwise be found
 *      by the operator mid-release;
 *   5. the guard is executed, in both directions, rather than merely located.
 *
 * WHAT IT DOES NOT ENFORCE, said here rather than left to be discovered: a
 * command that is neither `test` nor one of those three names, and an
 * assignment whose `$(...)` does not close on its own line, are not required to
 * carry a failure action. `actual_assets=$(for asset in ...; do` opens a
 * command substitution that closes three lines later, and a rule that read it
 * line by line would either demand a failure action in the middle of a `for`
 * body or need a shell parser to know better. The document writes those with
 * `|| fail` anyway; this gate does not police them.
 *
 * WHY `$-` AND NOT A BEHAVIOUR PROBE, since that is the first thing a reader
 * will want to change: `( set -e; false; true )` returns 0 in all six
 * configurations measured here -- sh, bash and zsh, errexit on and off --
 * because POSIX has the shell ignore `-e` inside a compound command whose
 * status is consumed by `||`, `&&` or `if`, which is the only way to read it
 * without the failure taking the shell down. The option letters are the shell's
 * own answer about its own state, and are right in all six.
 */

import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { logicalLines } from '../../tooling/forbidden-requirements/detect.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..', '..')
const DOC = 'docs/RELEASING.md'
const GUARD = 'release/fail-closed.sh'
const GUARD_LINE = `. ./${GUARD} || exit 1`

/* Commands whose failure is a finding, and which always close on one logical
 * line in this document. `test` is the one the defect was made of. */
const CHECKED = ['test', 'git', 'gh', 'task']

let failures = 0

const fail = (message) => {
    process.stderr.write(`FAIL: release procedure: ${message}\n`)
    failures += 1
}

/*
 * The blocks are fenced ```sh, and five of the seven are indented inside a
 * numbered step, so the fence is matched with its indent and that indent comes
 * off the body. A rule anchored at `^```` sees two of them.
 */
export function shellBlocks(markdown) {
    const blocks = []
    const lines = markdown.split('\n')
    let open = null
    lines.forEach((line, index) => {
        const fence = line.match(/^([ \t]*)```(\S*)\s*$/)
        if (open === null) {
            if (fence) open = { indent: fence[1], lang: fence[2], start: index + 2, body: [] }
            return
        }
        if (fence && line.startsWith(open.indent)) {
            if (open.lang === 'sh') blocks.push({ startLine: open.start, lines: open.body })
            open = null
            return
        }
        open.body.push(line.startsWith(open.indent) ? line.slice(open.indent.length) : line)
    })
    return blocks
}

/*
 * One statement per entry. `logicalLines` joins backslash continuations, which
 * is how the long `gh` invocations are written; a line ending in `||`, `&&` or
 * `|` continues too, and that is how a failure action is wrapped inside 79
 * columns. Both joins are needed to see `test ... || fail ...` as one thing.
 */
export function statements(body) {
    const out = []
    let pending = ''
    for (const line of logicalLines(body)) {
        pending = pending === '' ? line : `${pending.replace(/\s+$/, '')} ${line.trim()}`
        if (/(\|\||&&|\|)\s*$/.test(pending)) continue
        out.push(pending)
        pending = ''
    }
    if (pending !== '') out.push(pending)
    return out
}

const firstWord = (statement) => statement.trim().split(/\s+/, 1)[0]

/* A `(` count that ignores what single quotes make literal, which is enough to
 * tell `x=$(git ...)` from the `$(for ...; do` that closes three lines later. */
const balanced = (statement) => {
    const bare = statement.replace(/'[^']*'/g, '')
    return (bare.match(/\(/g) ?? []).length === (bare.match(/\)/g) ?? []).length
}

export function unguarded(statement) {
    const trimmed = statement.trim()
    if (trimmed === '' || trimmed.startsWith('#')) return false
    if (/\|\|\s*(fail\b|exit\b)/.test(trimmed)) return false
    if (CHECKED.includes(firstWord(trimmed))) return true
    return /^[A-Za-z_][A-Za-z0-9_]*=\$\(/.test(trimmed) && balanced(trimmed)
}

/* ------------------------------------------------------- both directions first */

const MUST_CATCH = [
    'test "$a" = "$b"',
    'git push "$remote" HEAD:refs/heads/main',
    'x=$(git rev-parse HEAD)',
    'task release-evidence',
]
const MUST_NOT_CATCH = [
    'test "$a" = "$b" || fail \'a is not b\'',
    'test "$a" = "$b" ||\n    fail \'a is not b\'',
    'test "$(gh release view "$tag" \\\n    --json isDraft --jq .isDraft)" = false ||\n    fail \'draft\'',
    '. ./release/fail-closed.sh || exit 1',
    'remote_sha=${record%%[[:space:]]*}',
    'printf \'%s\\n\' done',
    'actual=$(for asset in "$dir"/*; do',
    '# test "$a" = "$b"',
]

for (const source of MUST_CATCH) {
    if (!statements(source).some(unguarded)) {
        fail(`the unguarded-statement rule missed one it must catch: ${JSON.stringify(source)}`)
    }
}
for (const source of MUST_NOT_CATCH) {
    if (statements(source).some(unguarded)) {
        fail(`the unguarded-statement rule reported a guarded statement: ${JSON.stringify(source)}`)
    }
}
if (failures === 0) {
    process.stdout.write(
        `PASS: the block rule catches ${MUST_CATCH.length} unguarded statements ` +
            `and accepts ${MUST_NOT_CATCH.length} guarded ones\n`,
    )
}

/* --------------------------------------------------------------- the document */

const blocks = shellBlocks(readFileSync(join(ROOT, DOC), 'utf8'))
if (blocks.length === 0) {
    fail(`no \`sh\` blocks were found in ${DOC}, so this gate proved nothing`)
}

let checks = 0
for (const block of blocks) {
    const where = `${DOC}:${block.startLine}`
    const body = block.lines.join('\n')
    const running = statements(body)
        .map((statement) => statement.trim())
        .filter((statement) => statement !== '' && !statement.startsWith('#'))

    const guardAt = running.indexOf(GUARD_LINE)
    if (guardAt === -1) {
        fail(`the block at ${where} does not source ${GUARD}; open it with \`${GUARD_LINE}\``)
    } else if (running.slice(0, guardAt).some((statement) => statement !== 'set -eu')) {
        fail(`the block at ${where} runs something before it sources ${GUARD}`)
    }

    for (const statement of running) {
        if (unguarded(statement)) {
            fail(`${where}: \`${statement.slice(0, 60)}\` has no failure action; ` +
                "end it `|| fail '<what was being proved>'`")
        }
        checks += 1
    }

    for (const match of body.match(/\$[A-Za-z_][A-Za-z0-9_]*:/g) ?? []) {
        fail(`${where}: \`${match}\` interpolates before a colon, which zsh reads as a ` +
            `history modifier -- write \`\${${match.slice(1, -1)}}\` (this is how ` +
            "`refs/tags/$tag:refs/tags/$tag` became `refs/tags/v0.11efs/tags/v0.11.0-seed`)")
    }
}

if (failures === 0) {
    process.stdout.write(
        `PASS: ${blocks.length} ${DOC} blocks source ${GUARD} first, and all ${checks} ` +
            'of their statements fail closed\n',
    )
}

/* ------------------------------------------------------------- and it parses */

/*
 * Nothing else in the tree asks whether this document's shell is shell. The
 * blocks are edited by hand, in a file no gate ran until now, and a mangled
 * quote or continuation would be found by the operator mid-release -- which is
 * the moment this whole gate exists to keep boring. `-n` reads without running,
 * so this costs one process per block and executes none of them.
 */
const SHELLS = ['sh', 'bash', 'zsh'].filter(
    (shell) => spawnSync('command', ['-v', shell], { shell: '/bin/sh' }).status === 0,
)

for (const shell of SHELLS) {
    for (const block of blocks) {
        const parsed = spawnSync(shell, ['-n'], {
            cwd: ROOT,
            input: block.lines.join('\n'),
            encoding: 'utf8',
        })
        if (parsed.status !== 0) {
            fail(`${DOC}:${block.startLine} is not valid ${shell}: ${parsed.stderr.trim()}`)
        }
    }
}

if (failures === 0) {
    process.stdout.write(
        `PASS: all ${blocks.length} blocks parse in ${SHELLS.join(', ')}\n`,
    )
}

/* ------------------------------------------------------------ run the guard */

const inShell = (shell, script) =>
    spawnSync(shell, ['-c', script], { cwd: ROOT, encoding: 'utf8' })

let proved = 0
for (const shell of SHELLS) {
    const refused = inShell(shell, `. ./${GUARD}`)
    if (refused.status === 0) {
        fail(`${shell}: ${GUARD} accepted a shell with neither -e nor -u`)
    } else if (!refused.stderr.includes('FAIL:')) {
        fail(`${shell}: ${GUARD} refused without saying why on stderr`)
    }

    if (inShell(shell, `set -e; . ./${GUARD}`).status === 0) {
        fail(`${shell}: ${GUARD} accepted a shell with -e but no -u`)
    }

    const accepted = inShell(shell, `set -eu; . ./${GUARD}`)
    if (accepted.status !== 0) {
        fail(`${shell}: ${GUARD} refused \`set -eu\`, exit ${accepted.status}`)
    } else if (accepted.stdout !== '' || accepted.stderr !== '') {
        fail(`${shell}: ${GUARD} is not silent under \`set -eu\``)
    }

    /* The half the guard cannot do alone: a failed check stops the block. */
    const stopped = inShell(
        shell,
        `set -eu; . ./${GUARD}; test 1 = 2 || fail 'one is not two'; printf 'REACHED\\n'`,
    )
    if (stopped.status === 0 || stopped.stdout.includes('REACHED')) {
        fail(`${shell}: a failed check did not stop the block`)
    }
    proved += 1
}

if (SHELLS.length === 0) {
    fail('no shell was available to run the guard, so it was only read')
}

if (failures === 0) {
    process.stdout.write(
        `PASS: ${GUARD} refuses a shell without \`set -eu\` and stops a failed check, ` +
            `in ${proved} shell(s): ${SHELLS.join(', ')}\n`,
    )
}

process.exit(failures === 0 ? 0 : 1)

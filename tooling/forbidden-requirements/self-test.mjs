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

import { DETECTORS, dialectOf, matchCommands, withoutComments } from './detect.mjs'
import { guardVerdict, needOf } from './reach.mjs'

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
    ['mention-and-invoke.sh', 'node', 'invoke', 3,
        'three invocations — at a line start, inside a subshell, and on the line ' +
        'after a multi-line `$(` — against five mentions in comments and two ' +
        'Python-heredoc lines where `node` is a parameter name (#1500)'],
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
    ['mention-and-invoke.yml', 'node', 'invoke', 2,
        '`npm ci` and multiline `npm run` count as Node.js toolchain invocations'],
    ['mention-only.yml', 'node', 'invoke', 0,
        'an npm-shaped comment, `actions/setup-node`, quoted prose, and `npm-cli` do not count'],
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
 * Wrapper terminators are tested directly rather than folded into the fixture
 * count. Each row owns one command-position fact, so a newly missed positive
 * cannot cancel a newly invented invocation and leave an aggregate unchanged.
 */
const WRAPPER_TERMINATOR_CASES = [
    ['env terminator', 'env -- npm ci', 'node|npm', 1],
    ['command terminator', 'command -- node script.mjs', 'node|npm', 1],
    ['xargs terminator', 'printf x | xargs -- npm exec', 'node|npm', 1],
    ['short option before terminator', 'env -i -- npm ci', 'node|npm', 1],
    ['flow keyword before wrapper', 'if env -- npm ci', 'node|npm', 1],
    ['existing env wrapper', 'env npm ci', 'node|npm', 1],
    ['existing command wrapper', 'command node script.mjs', 'node|npm', 1],
    ['existing xargs wrapper', 'xargs npm exec', 'node|npm', 1],
    ['flow keyword is not an executable wrapper', 'if -- node', 'node|npm', 0],
    ['wrapper-shaped prose', 'echo env -- npm ci', 'node|npm', 0],
    ['quoted wrapper-shaped prose', "printf '%s\\n' 'command -- node'", 'node|npm', 0],
    ['command terminator does not skip an assignment',
        'command -- FOO=bar node script.mjs', 'node|npm', 0],
    ['xargs terminator does not skip an assignment',
        'printf x | xargs -- FOO=bar npm exec', 'node|npm', 0],
    ['wrapper and terminator stay on one physical line',
        'env' + '\n    -- node', 'node|npm', 0],
    ['argument-taking xargs option is not guessed',
        'printf x | xargs -n -- npm exec', 'node|npm', 0],
    ['unmeasured env option is not guessed',
        'env -u NAME -- npm ci', 'node|npm', 0],
    ['similarly named npm executable', 'env -- npm-cli ci', 'node|npm', 0],
    ['similarly named node executable', 'command -- nodejs script.mjs', 'node|npm', 0],
]

for (const [name, body, token, expected] of WRAPPER_TERMINATOR_CASES) {
    const actual = matchCommands(body, token).length
    if (actual !== expected) {
        fail(`${name}: matchCommands counted ${actual}, expected ${expected} in ` +
            JSON.stringify(body))
    }
}

/*
 * The command-position model itself (#1552). Each row is a shape the previous,
 * pattern-shaped rule got wrong, or one it got right and this must keep: an
 * aggregate count cannot tell a newly missed positive from a newly invented
 * invocation, so every fact is its own row.
 *
 * The first seven are the matrix measured on `main@a858e0fa` when #1552 was
 * filed. The rest are the regions the issue names -- quoting of all three
 * kinds, escaped operators and newlines, command substitutions, `case`
 * patterns -- plus the two live files whose counts this changed.
 */
const COMMAND_POSITION_CASES = [
    /* Prose that names a wrapper is not an invocation of what follows it. */
    ['prose wrapper', 'echo env node', 'node|npm', 0],
    ['single-quoted wrapper prose', "printf '%s\\n' 'command node'", 'node|npm', 0],
    ['ANSI-C quoted wrapper prose', String.raw`printf $'command node\n'`, 'node|npm', 0],
    /* Wrapper chains compose, in the order the shell can actually resolve. */
    ['shell wrapper before external', 'command env -- node', 'node|npm', 1],
    ['external before external', 'env xargs -- npm', 'node|npm', 1],
    ['external before external, reversed', 'xargs env -- npm', 'node|npm', 1],
    ['env cannot resolve the builtin command', 'env -- command node', 'node|npm', 0],
    ['xargs cannot resolve the builtin command', 'xargs -- command node', 'node|npm', 0],
    /* Quoting decides what is text. Both of these are live files. */
    ['a generated script is text, not a command',
        `printf '%s\\n' 'exec node "$ROOT/run.mjs" "$0.wasm"' >script`, 'node|npm', 0],
    ['an escaped backtick is text, not a substitution',
        'printf \'%s\\n\' "run \\`task release-evidence\\`"', 'task', 0],
    ['a substitution inside double quotes still runs',
        'value=$(json_string "$(rustc -Vv)")', 'rustc', 1],
    /* An assignment may precede the command, at any indentation. */
    ['indented assignment before the command',
        '        KOFUN_RFC_TODAY="$horizon" node "$VALIDATOR" validate', 'node|npm', 1],
    ['an assignment is not itself a command', 'differential=\'skipped (node absent)\'', 'node|npm', 0],
    /* `case` patterns sit exactly where a command would. */
    ['a case pattern is not a command', 'case "$x" in\n    node)\n        true\n        ;;\nesac', 'node|npm', 0],
    ['a case body is', 'case "$x" in\n    a)\n        node run\n        ;;\nesac', 'node|npm', 1],
    ['a command after esac is', 'case "$x" in\n    a)\n        true\n        ;;\nesac\nnode run', 'node|npm', 1],
    /* A here-document body is data, including when it is a script. */
    ['a heredoc body is not run here', "cat <<'EOF' >script\nnode run.mjs\nEOF\n", 'node|npm', 0],
    ['a command after a heredoc is', "cat <<'EOF' >script\ntext\nEOF\nnode run.mjs\n", 'node|npm', 1],
    /* A brace expansion names a variable; a brace group runs a command. */
    ['a brace expansion is not a command', 'for candidate in ${KOFUN_CC:-} clang gcc cc; do :; done',
        String.raw`cc|gcc|clang|c99`, 0],
    ['a brace group is', '{ node run; }', 'node|npm', 1],
    /* An escaped newline continues one command; a bare one ends it. */
    ['an escaped newline continues the command',
        'KOFUN_STAGE2_COMMON_LINK_ID=documentation-index \\\n    node "$EMITTER"', 'node|npm', 1],
    /* An escape makes an operator a character. */
    ['an escaped semicolon does not open a command', 'find . -exec rm {} \\; node', 'node|npm', 0],
    /* A spelling may span two words: `openssl dgst` is the forbidden one, and
     * `openssl x509` is not (#1213, tests/digest/no-host-digest-tools.mjs). */
    ['a two-word spelling matches', 'openssl dgst -sha256 file', String.raw`openssl[ \t]+dgst`, 1],
    ['a two-word spelling does not over-match', 'openssl x509 -noout -in cert.pem',
        String.raw`openssl[ \t]+dgst`, 0],
]

for (const [name, body, token, expected] of COMMAND_POSITION_CASES) {
    const actual = matchCommands(body, token).length
    if (actual !== expected) {
        fail(`${name}: matchCommands counted ${actual}, expected ${expected} in ` +
            JSON.stringify(body))
    }
}

if (process.exitCode !== 1) {
    process.stdout.write(
        `PASS: ${COMMAND_POSITION_CASES.length} command-position cases over quoting, ` +
            'wrapper chains, `case` patterns, here-documents and two-word spellings\n',
    )
}

/*
 * `npm` is a spelling of the existing `node` requirement in both halves of
 * the model. Counting the command without teaching the guard reader its name
 * would make an optional branch look unguarded and therefore required. The
 * optional case is the load-bearing one: omitting `npm` from SPELLINGS.node
 * leaves guardVerdict's default at `required` and this test fails.
 */
const NPM_GUARD_CASES = [
    {
        name: 'optional npm guard',
        expected: 'optional',
        body: `if command -v npm >/dev/null 2>&1; then
    npm --version
else
    printf 'SKIP: npm unavailable\\n'
fi
`,
    },
    {
        name: 'fail-closed npm guard',
        expected: 'required',
        body: `command -v npm >/dev/null 2>&1 || {
    printf 'npm is required\\n' >&2
    exit 1
}
npm --version
`,
    },
]

const npmGuardPath = 'fixtures/npm-guard.sh'
const npmGuardWhere = new Map([[npmGuardPath, 'on']])
for (const { name, expected, body } of NPM_GUARD_CASES) {
    const direct = guardVerdict(body, 'node')
    if (direct !== expected) {
        fail(`${name}: guardVerdict returned \`${direct}\`, expected \`${expected}\``)
    }
    const joined = needOf({
        path: npmGuardPath,
        body,
        requirement: 'node',
        kind: 'invoke',
    }, npmGuardWhere)
    if (joined !== expected) {
        fail(`${name}: needOf returned \`${joined}\`, expected \`${expected}\``)
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
        .map((l) => l.split('\t')[5]),
)
for (const name of [
    'mention-and-invoke.sh',
    'mention-and-invoke.mjs',
    'mention-and-invoke.yml',
    'mention-only.yml',
]) {
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
const patternSources = [patternSource, 'tooling/forbidden-requirements/reach.mjs']
const patternInvokes = censusRows.filter((f) => f[5] === patternSource && f[1] === 'invoke')
if (patternInvokes.length !== 0) {
    fail(`${patternSource} has ${patternInvokes.length} invoke row(s); it spells the patterns ` +
        'out as string literals and runs nothing, so counting them reports the vocabulary as a finding')
}
if (!censusRows.some((f) => f[5] === patternSource && f[0] === 'node' && f[1] === 'source')) {
    fail(`${patternSource} has no \`node source\` row; the invoke exemption has widened into ` +
        'the whole file, and the census no longer counts its own instrument')
}
for (const name of ['check.mjs', 'self-test.mjs', 'reach.mjs']) {
    const path = `tooling/forbidden-requirements/${name}`
    if (!censusRows.some((f) => f[5] === path && f[0] === 'node' && f[1] === 'source')) {
        fail(`${path} is missing from the census; the exemption has widened to the directory`)
    }
}

/*
 * The derived column, pinned to two facts about the tree rather than only to
 * its own consistency. A checker that agreed with whatever it computed would
 * pass with every value inverted.
 *
 * `bin/kofun` invokes `cc` with no availability guard and `repository-check`
 * runs it. `scripts/graphify.sh` invokes `python` and its only two callers,
 * `graphify-setup` and `graphify-update`, are both recorded in
 * `tooling/gate-reachability/unreachable.tsv` as manual by design.
 */
const needOfRow = (requirement, path) => {
    const row = censusRows.find((f) => f[0] === requirement && f[5] === path && f[1] === 'invoke')
    return row === undefined ? '(no row)' : row[4]
}
for (const [requirement, path, expected, why] of [
    ['cc', 'bin/kofun', 'required', 'unguarded, and `repository-check` runs it'],
    ['python', 'scripts/graphify.sh', 'off-path', 'both its tasks are recorded unreachable'],
]) {
    const actual = needOfRow(requirement, path)
    if (actual !== expected) {
        fail(`${path}: \`${requirement}\` is recorded as \`${actual}\`, expected ` +
            `\`${expected}\` — ${why}`)
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
        ledger: `${original.trimEnd()}\ncc\tinvoke\t1\trequired-today\trequired\ttooling/forbidden-requirements/no-such-file.sh\n`,
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
        name: "a required use moved into `optional`",
        why: 'the need column is derived, so this is the case that stops it becoming a suppression list',
        ledger: original.replace(
            /^(cc\tinvoke\t\d+\trequired-today\t)required(\tbin\/kofun)$/m,
            '$1optional$2',
        ),
        expect: 'The need column is derived',
    },
    {
        name: 'an off-path use claimed as required',
        why: 'the derivation has to fail in both directions or it only ratchets one way',
        ledger: original.replace(
            /^(python\tinvoke\t\d+\trequired-today\t)off-path(\tscripts\/graphify\.sh)$/m,
            '$1required$2',
        ),
        expect: 'The need column is derived',
    },
    {
        name: 'a need value outside the vocabulary',
        why: 'four values, closed, or the column means whatever the last author thought',
        ledger: original.replace(/\trequired\tbin\/kofun$/m, '\tprobably\tbin/kofun'),
        expect: 'is not one of',
    },
    {
        name: 'more unknown rows than the declared ceiling',
        why: 'this is what a use the rules cannot classify looks like when it arrives as an ordinary row',
        ledger: original.replace(/^# unknown-ceiling: \d+$/m, '# unknown-ceiling: 4'),
        expect: 'may not arrive as an ordinary row',
    },
    {
        name: 'a ceiling left above the count',
        why: 'the other direction: slack nobody recorded is an improvement nobody can see',
        ledger: original.replace(/^# unknown-ceiling: \d+$/m, '# unknown-ceiling: 400'),
        expect: 'lower it so the improvement is recorded',
    },
    {
        name: 'no ceiling at all',
        why: 'an absent bound and a satisfied bound must not look the same',
        ledger: original.replace(/^# unknown-ceiling: \d+$/m, '# (no ceiling here)'),
        expect: 'declares no',
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
    `PASS: ${FIXTURE_CASES.length} detector cases over ` +
    `${new Set(FIXTURE_CASES.map((c) => c[0])).size} fixtures, ` +
    `${FIXTURE_CASES.filter((c) => c[3] === 0).length} of them asserting a near miss counts zero\n`)
process.stdout.write(
    `PASS: ${WRAPPER_TERMINATOR_CASES.length} wrapper command-position cases, ` +
    `${WRAPPER_TERMINATOR_CASES.filter((c) => c[3] === 0).length} of them asserting a near miss counts zero\n`)
process.stdout.write(
    `PASS: ${NPM_GUARD_CASES.length} npm guard cases distinguish optional from fail-closed use\n`)
process.stdout.write(
    `PASS: ${CASES.length} ledger mutations each refused with a diagnostic that names the drift\n`)
process.stdout.write('PASS: the committed census passes the same checker unmutated\n')

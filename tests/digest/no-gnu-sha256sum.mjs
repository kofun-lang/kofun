/*
 * No tracked file computes a digest with GNU `sha256sum` (#1213).
 *
 * #1213 replaced that dependency with `bin/kofun-digest`, and the census, the
 * package manager, and this gate's own header all state it as done. It was
 * not: `.github/workflows/native-hosts.yml` still ran `sha256sum` against each
 * emitted native image, and that comparison is what decides whether the
 * six-host evidence a release binds is accepted. Nothing failed when the last
 * call site survived, because nothing was looking.
 *
 * The rule is command position, not mention. Roughly half the tree's
 * occurrences of the string are prose explaining #1213 — including this file —
 * and a gate that counted those would have to be silenced immediately, which
 * is how a rule stops being read.
 *
 * The detector is the census's `commandPosition`, reused rather than
 * re-written: it already knows that `$(sha256sum` is an invocation and that
 * `SHA256SUMS` and `nodejs-flavour`-shaped tokens are not, and #1535 widened
 * it for wrapper `--` terminators. A second, private copy of that judgement
 * would drift from it.
 */

import { execFileSync } from 'node:child_process'
import { readFileSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { commandPosition, dialectOf, withoutComments } from '../../tooling/forbidden-requirements/detect.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..', '..')

/* The census's own fixtures exist to contain forbidden spellings. */
const EXCLUDED = 'tooling/forbidden-requirements/fixtures/'

/* Same set the census scans: what can invoke something. */
const RUNNABLE = ['.sh', '.mjs', '.js', '.yml', '.yaml']

const TOKEN = 'sha256sum'

let failures = 0

const fail = (message) => {
    process.stderr.write(`FAIL: digest: ${message}\n`)
    failures += 1
}

function invocationsIn(path, body) {
    return withoutComments(path, body).match(commandPosition(TOKEN, dialectOf(path))) ?? []
}

/*
 * Both directions first. A scan that reports nothing is indistinguishable from
 * a scan that cannot see, and this one runs over a tree where the true answer
 * is expected to be zero forever — so the only evidence it still works is a
 * case it must catch and a case it must not.
 */
const MUST_CATCH = [
    ['catch.sh', 'digest=$(sha256sum "$IMAGE" | awk \'{ print $1 }\')\n'],
    ['catch.yml', 'run: |\n  sha256sum file >sums\n'],
    ['catch2.sh', 'true && sha256sum file\n'],
]
const MUST_NOT_CATCH = [
    ['prose.sh', '# sha256sum is not used here (#1213)\n'],
    ['manifest.sh', 'cat SHA256SUMS\n'],
    ['name.sh', 'run_sha256sum_report\n'],
]

for (const [name, body] of MUST_CATCH) {
    if (invocationsIn(name, body).length === 0) {
        fail(`the ${TOKEN} scan missed an invocation it must catch: ${JSON.stringify(body)}`)
    }
}
for (const [name, body] of MUST_NOT_CATCH) {
    if (invocationsIn(name, body).length !== 0) {
        fail(`the ${TOKEN} scan reported a non-invocation: ${JSON.stringify(body)}`)
    }
}

if (failures === 0) {
    process.stdout.write(
        `PASS: the ${TOKEN} scan catches ${MUST_CATCH.length} invocation shapes ` +
            `and refuses ${MUST_NOT_CATCH.length} mentions\n`,
    )
}

/* The tree itself. */
const tracked = execFileSync('git', ['ls-files', '-z'], { cwd: ROOT, maxBuffer: 64 * 1024 * 1024 })
    .toString('utf8')
    .split('\0')
    .filter(Boolean)

let scanned = 0
for (const path of tracked) {
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
    if (!RUNNABLE.some((suffix) => path.endsWith(suffix)) && !body.startsWith('#!')) continue
    scanned += 1
    for (const hit of invocationsIn(path, body)) {
        fail(
            `${path} invokes GNU \`${TOKEN}\` (${hit.trim()}); ` +
                'compute the digest with `bin/kofun-digest`, which prints the same format (#1213)',
        )
    }
}

if (scanned === 0) {
    fail('the scan reached no files, so it proved nothing about the tree')
}

if (failures === 0) {
    process.stdout.write(
        `PASS: none of ${scanned} runnable tracked files invokes GNU \`${TOKEN}\`\n`,
    )
}

process.exit(failures === 0 ? 0 : 1)

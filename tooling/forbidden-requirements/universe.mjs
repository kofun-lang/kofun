/*
 * The set of tracked files that can invoke something, and the one place it is
 * defined.
 *
 * Two scanners read this repository asking the same question in the same
 * words -- `tooling/forbidden-requirements/check.mjs`, which measures the
 * distance between the contract and the tree, and
 * `tests/digest/no-host-digest-tools.mjs`, which refuses a digest computed by a
 * tool the project does not ship (#1213). The second one arrived as a copy of
 * the first, and the copy had already lost something: the NUL rule below, whose
 * absence silently drops a real Node.js source file from the count. That is
 * three days of drift on a walk that had existed for a week, which is the
 * argument for this file rather than a third copy of it.
 *
 * The prose form of this set stays in `detect.mjs` as `FILE_SET`, beside the
 * per-detector predicates and matching its sibling in `tooling/machine-
 * dependent/`, because `--predicates` prints them together: a count is only
 * meaningful with its predicate attached, and both halves can be too narrow at
 * once.
 *
 * `detect.mjs` deliberately does not host this. Its own header says it is
 * separated from the checker so the self-test can drive the detectors over
 * fixtures without scanning the repository, and a module that shells out to
 * `git ls-files` on import would take that property away.
 */

import { execFileSync } from 'node:child_process'
import { readFileSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..', '..')

/*
 * The fixture directory is the one place excluded from the scan, because it
 * contains a deliberate invocation whose whole purpose is to be detected by the
 * self-test. Excluding it is stated here and asserted in the self-test, so the
 * hole cannot quietly widen into "anything under tooling/".
 */
export const EXCLUDED = 'tooling/forbidden-requirements/fixtures/'

export const RUNNABLE = ['.sh', '.mjs', '.js', '.yml', '.yaml']

export function trackedFiles() {
    const out = execFileSync('git', ['ls-files', '-z'], { cwd: ROOT, maxBuffer: 64 * 1024 * 1024 })
    return out.toString('utf8').split('\0').filter(Boolean)
}

export function universe() {
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

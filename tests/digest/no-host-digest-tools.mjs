/*
 * No tracked file computes a digest with a tool the host happens to provide
 * (#1213).
 *
 * #1213 replaced GNU `sha256sum` with `bin/kofun-digest`, and the census, the
 * package manager, and this gate's own header all state it as done. It was
 * not: `.github/workflows/native-hosts.yml` still verified each emitted native
 * image against `bootstrap/native/SHA256SUMS` with `sha256sum` on the Linux
 * hosts and `shasum -a 256` on the macOS ones, and that comparison is what
 * decides whether the six-host evidence a release binds is accepted. Nothing
 * failed when those two call sites survived, because nothing was looking.
 *
 * The three spellings below are the three `package/manager.sh` used to try in
 * turn before #1213 replaced the chain, which is why one gate refuses all of
 * them: a rule that named only the GNU one would leave the fallback the same
 * code already knew how to reach for.
 *
 * The rule is command position, not mention. Roughly half the tree's
 * occurrences of these names are prose explaining #1213 — including this file
 * — and a gate that counted those would have to be silenced immediately, which
 * is how a rule stops being read. `openssl` is narrowed further, to `openssl
 * dgst`: the digest subcommand is the forbidden one, and refusing every use of
 * the tool would be a rule about the wrong thing.
 *
 * Both halves of the scan are the census's, reused rather than re-written. The
 * detector is `commandPosition`, which already knows that `$(sha256sum` is an
 * invocation and that `SHA256SUMS` and `nodejs-flavour`-shaped tokens are not,
 * and which #1535 widened for wrapper `--` terminators; the file set is
 * `universe()`. This gate first shipped with its own copy of the second one,
 * and the copy was already wrong within the week -- it had dropped the NUL rule
 * that keeps a binary fixture from being sniffed as a script, so the two
 * scanners disagreed about which files the tree even contains. A private copy
 * of either judgement drifts from it.
 *
 * One digest in the tree is deliberately outside this rule, and it is filed
 * rather than left silent: the Windows lane of the same workflow computes its
 * digest with PowerShell's built-in `Get-FileHash`, which this scan cannot see
 * because `commandPosition` reads shell, JavaScript, and YAML `run:` position
 * and not PowerShell. That is also a different dependency — a built-in of the
 * host being tested rather than a userland tool someone installs — and whether
 * `bin/kofun-digest` can run there at all is unmeasured. #1606 carries both
 * questions, so a passing run here means five lanes, not six.
 */

import { commandPosition, dialectOf, withoutComments } from '../../tooling/forbidden-requirements/detect.mjs'
import { universe } from '../../tooling/forbidden-requirements/universe.mjs'

/* `pattern` is a regular-expression fragment; `spelling` is what a message says. */
const TOOLS = [
    { spelling: 'sha256sum', pattern: 'sha256sum' },
    { spelling: 'shasum', pattern: 'shasum' },
    { spelling: 'openssl dgst', pattern: String.raw`openssl[ \t]+dgst` },
]

let failures = 0

const fail = (message) => {
    process.stderr.write(`FAIL: digest: ${message}\n`)
    failures += 1
}

/* Every hit in one file, as `{ spelling, text }`, across all three spellings. */
function invocationsIn(path, body) {
    const source = withoutComments(path, body)
    const dialect = dialectOf(path)
    return TOOLS.flatMap(({ spelling, pattern }) =>
        (source.match(commandPosition(pattern, dialect)) ?? []).map((text) => ({ spelling, text })),
    )
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
    ['bsd.sh', 'actual=$(shasum -a 256 "$IMAGE" | awk \'{ print $1 }\')\n'],
    ['openssl.sh', 'openssl dgst -sha256 "$IMAGE"\n'],
]
const MUST_NOT_CATCH = [
    ['prose.sh', '# sha256sum is not used here (#1213)\n'],
    ['manifest.sh', 'cat SHA256SUMS\n'],
    ['name.sh', 'run_sha256sum_report\n'],
    ['bsd-name.sh', 'kofun_shasum_report\n'],
    ['other-openssl.sh', 'openssl x509 -noout -subject -in cert.pem\n'],
]

for (const [name, body] of MUST_CATCH) {
    if (invocationsIn(name, body).length === 0) {
        fail(`the digest-tool scan missed an invocation it must catch: ${JSON.stringify(body)}`)
    }
}
for (const [name, body] of MUST_NOT_CATCH) {
    const reported = invocationsIn(name, body)
    if (reported.length !== 0) {
        fail(
            `the digest-tool scan reported a non-invocation as \`${reported[0].spelling}\`: ` +
                JSON.stringify(body),
        )
    }
}

if (failures === 0) {
    process.stdout.write(
        `PASS: the digest-tool scan catches ${MUST_CATCH.length} invocation shapes ` +
            `and refuses ${MUST_NOT_CATCH.length} mentions\n`,
    )
}

/*
 * The tree itself, over the census's file set rather than a second definition
 * of it: what can invoke something is one judgement, and this gate and the
 * census have to be asking about the same files for either answer to mean
 * anything.
 */
const files = universe()

for (const { path, body } of files) {
    for (const { spelling, text } of invocationsIn(path, body)) {
        fail(
            `${path} computes a digest with \`${spelling}\` (${text.trim()}); ` +
                'use `bin/kofun-digest`, which prints the same format (#1213)',
        )
    }
}

if (files.length === 0) {
    fail('the scan reached no files, so it proved nothing about the tree')
}

if (failures === 0) {
    process.stdout.write(
        `PASS: none of ${files.length} runnable tracked files computes a digest with ` +
            `${TOOLS.map((tool) => `\`${tool.spelling}\``).join(', ')}\n`,
    )
}

process.exit(failures === 0 ? 0 : 1)

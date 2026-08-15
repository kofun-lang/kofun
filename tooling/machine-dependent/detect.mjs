/*
 * Detectors for bounds whose verdict can depend on how busy the machine is
 * rather than on the tree (#1472). Separated from the checker so the self-test
 * can drive them over fixtures without scanning the repository, the way
 * `tooling/forbidden-requirements/detect.mjs` does.
 *
 * A gate's verdict is either a function of the tree alone, or of the tree and
 * whatever else the machine is doing. Both kinds get slower under load; only
 * the second changes its answer, and it changes it in the direction nobody can
 * reproduce afterwards.
 *
 * THREE DETECTORS, BECAUSE ONE SEARCH CANNOT SEE ALL THREE SHAPES.
 *
 * #1472's first version searched for absolute millisecond p95 assertions. That
 * search is correct and finds real sites, and it cannot see a budget held in a
 * named constant and compared as `measured <= budget` — which is how the worst
 * site in the tree, a CPU budget that has actually failed, was missing from it.
 * The lesson is in the issue and it is the reason this file has a
 * `duration-budget` detector at all: a count can be narrowed by its file set
 * and by its pattern at once, and the product still looks plausible.
 *
 * A count is only meaningful with its predicate attached, so every detector
 * carries the shell command that answers the same question. `--predicates`
 * prints them.
 */

/*
 * The file set, stated once. Gates are shell and JavaScript; a `.c` file cannot
 * invoke `timeout`, and a `.md` file describing a budget is prose. `.kofun`
 * fixtures are data.
 *
 * What this boundary hides is reported rather than dropped: `--count` prints
 * how many tracked `*.c` files contain a `clock_gettime`-family call, because
 * a C program that reads a clock could carry a bound this set cannot see.
 */
export const FILE_SET = "FILES=\"$(git ls-files '*.sh' '*.mjs' '*.js')\""

/*
 * Comments are not bounds. A file that explains a budget in a comment table --
 * `tests/lsp/performance_test.js` documents six of them across fifty lines --
 * would otherwise be counted once per line of prose.
 *
 * Scanned rather than pattern-replaced, and the reason is a defect this file
 * shipped with for one revision. The obvious version strips block comments
 * first with a lazy `open ... close` regex. In that same file, line 43 is a
 * line comment containing the path fragment `task` followed by a star and a
 * slash, and the nearest block-comment close after it is 395
 * lines further down inside a template literal. One lazy match therefore
 * deleted lines 43-438 -- including all six CPU budget constants, the exact
 * sites this detector exists to find -- and the run reported zero of them
 * without any error.
 *
 * So: one output line per input line, line comments recognised before block
 * opens on the same line, and block state carried across lines explicitly.
 * Line numbers survive too, which the collapsing version destroyed.
 *
 * Known limit, stated rather than left to be discovered: a line- or
 * block-comment opener inside a
 * string or template literal is still read as a comment. Stripping can only
 * lose matches, never invent them, so the error direction is a missed bound --
 * which is why `--count` reports what stripping removed.
 */
export function withoutComments(path, body) {
    if (!(path.endsWith('.mjs') || path.endsWith('.js'))) {
        return body.replace(/(^|\s)#.*$/gm, '$1')
    }
    let inBlock = false
    return body.split('\n').map((line) => {
        let out = ''
        let index = 0
        while (index < line.length) {
            if (inBlock) {
                const close = line.indexOf('*/', index)
                if (close === -1) break
                inBlock = false
                index = close + 2
                continue
            }
            const lineComment = line.indexOf('//', index)
            const blockOpen = line.indexOf('/*', index)
            if (lineComment !== -1 && (blockOpen === -1 || lineComment < blockOpen)) {
                out += line.slice(index, lineComment)
                break
            }
            if (blockOpen !== -1) {
                out += line.slice(index, blockOpen)
                index = blockOpen + 2
                inBlock = true
                continue
            }
            out += line.slice(index)
            break
        }
        return out
    }).join('\n')
}

/*
 * A duration written as a number. `120` in `timeout 120` is seconds because
 * that is what `timeout(1)` takes; `145` in `DIAGNOSTIC_MAX_CPU_MS` is
 * milliseconds because the name says so. Normalising both to milliseconds is
 * what lets one column hold both and the margin be computed across them.
 */
export function toMilliseconds(text) {
    const match = /^(\d+(?:\.\d+)?)(ms|s|m)$/.exec(String(text).trim())
    if (match === null) return null
    const value = Number(match[1])
    if (match[2] === 'ms') return value
    if (match[2] === 's') return value * 1000
    return value * 60000
}

/*
 * A name ENDS with its unit; it does not merely contain one. `MS` as a bare
 * alternative matches `MAX_COMPLETION_ITEMS` and `CABI_MAX_PARAMS`, because
 * ITEMS and PARAMS both end in MS -- three false rows in the first run, each of
 * them a count of things rather than a duration. So the token must terminate
 * the identifier, and in SCREAMING_CASE it must follow an underscore.
 */
const DURATION_SUFFIX = String.raw`(?:_(?:MS|SECONDS|MILLISECONDS|MICROS|NANOS|TIMEOUT|DURATION|ELAPSED|ms|seconds|milliseconds|timeout|duration|elapsed)|(?:Ms|Millis|Milliseconds|Seconds|Micros|Nanos|Duration|Elapsed|Timeout))`
const NAMED_DURATION = String.raw`[A-Za-z_][A-Za-z0-9_.]*` + DURATION_SUFFIX

/*
 * The unit the name declares. `MILLISECONDS` ends in `SECONDS`, so the
 * milli- forms are tested first; getting this backwards turned
 * `LOCK_WAIT_MILLISECONDS = 2000` into a 2000-second bound in the first run,
 * which is the kind of unit error a ledger of durations cannot afford.
 *
 * A bare `_TIMEOUT` is seconds: every one in this tree feeds `timeout(1)` or a
 * variable that does, and that command takes seconds.
 */
export function unitOf(name) {
    if (/(_MILLISECONDS|_milliseconds|Milliseconds|Millis|_MS|_ms|Ms)$/.test(name)) return 'ms'
    if (/(_SECONDS|_seconds|Seconds|_TIMEOUT|_timeout|Timeout)$/.test(name)) return 's'
    return 'ms'
}

/*
 * KNOWN LIMIT, stated rather than left to be discovered: a bound passed
 * positionally has no name to match. `tests/lsp/protocol_test.js:462` waits
 * with `client.waitFor(predicate, 2000)`, and no detector here can see that
 * `2000` is a millisecond ceiling rather than a count or an index — the
 * argument's meaning lives in `waitFor`'s signature, not at the call.
 *
 * Widening to "any numeric literal in a call" would report every array index
 * in the tree, so the population this file measures is bounds that *say* they
 * are durations. That is a real boundary and it is drawn here, not hidden:
 * a positional bound is invisible to the ledger, and closing that gap means
 * naming the argument at the call site.
 */

export const DETECTORS = [
    {
        site: 'timeout-command',
        describes:
            'a `timeout` wrapper around a command, which bounds how long the ' +
            'machine may take rather than what the program computes',
        predicate:
            String.raw`$FILES | xargs grep -cnE '(^|[|;&(]|\$\()[[:space:]]*timeout[[:space:]]+("?\$|[0-9])'`,
        /*
         * Command position only. `expected exit 124 is reserved for the timeout
         * harness` is prose about a timeout, not one, and four files say it.
         */
        match(body, path) {
            if (!path.endsWith('.sh')) return []
            const hits = []
            body.split('\n').forEach((line, index) => {
                const found = /(?:^|[|;&(]|\$\()\s*timeout\s+("?[^"\s]+"?)/.exec(line)
                if (found === null) return
                const written = found[1].replace(/"/g, '')
                /*
                 * A bare number here is seconds, because that is what
                 * `timeout(1)` takes. Writing the unit in makes `timeout 120`
                 * and `DIAGNOSTIC_MAX_CPU_MS = 145` comparable in one column.
                 */
                const bound = /^\d+(\.\d+)?$/.test(written) ? `${written}s` : written
                hits.push({ line: index + 1, bound, text: line.trim() })
            })
            return hits
        },
    },
    {
        site: 'duration-comparison',
        describes:
            'a comparison whose left side names an elapsed-time measurement ' +
            'and whose right side is a numeric constant',
        predicate:
            String.raw`$FILES | xargs grep -cnE '` + NAMED_DURATION +
            String.raw`[[:space:]]*[<>]=?[[:space:]]*-?[0-9]'`,
        match(body) {
            const pattern = new RegExp(
                '(' + NAMED_DURATION + String.raw`)\s*([<>]=?)\s*(-?\d+(?:\.\d+)?)n?`,
                'g',
            )
            const hits = []
            body.split('\n').forEach((line, index) => {
                for (const found of line.matchAll(pattern)) {
                    hits.push({
                        line: index + 1,
                        bound: `${found[3]}${unitOf(found[1])}`,
                        text: line.trim(),
                    })
                }
            })
            return hits
        },
    },
    {
        site: 'duration-budget',
        describes:
            'a named constant holding a duration, which a comparison elsewhere ' +
            'comes to as a variable — the shape a search for a literal bound cannot see',
        predicate:
            String.raw`$FILES | xargs grep -cnE '^[[:space:]]*((const|let|var)[[:space:]]+)?` +
            NAMED_DURATION +
            String.raw`[[:space:]]*=[[:space:]]*(\$\{[A-Za-z_][A-Za-z0-9_]*:-)?[0-9]'`,
        match(body) {
            const js = new RegExp(
                String.raw`^\s*(?:const|let|var)\s+(` + NAMED_DURATION +
                String.raw`)\s*=\s*(\d+(?:\.\d+)?)\b`,
            )
            /*
             * `NAME=${OVERRIDE:-10}` is a bound of 10 with an escape hatch, not
             * the absence of a bound. The first version of this pattern
             * required a digit immediately after `=` and could not see
             * `TIMEOUT_SECONDS=${KOFUN_SEMANTIC_TIMEOUT:-10}` -- the default
             * that actually governs every run nobody overrides.
             */
            const sh = new RegExp(
                String.raw`^\s*(` + NAMED_DURATION +
                String.raw`)=(?:\$\{[A-Za-z_][A-Za-z0-9_]*:-)?(\d+(?:\.\d+)?)\b`,
            )
            const hits = []
            body.split('\n').forEach((line, index) => {
                const found = js.exec(line) ?? sh.exec(line)
                if (found === null) return
                hits.push({
                    line: index + 1,
                    bound: `${found[2]}${unitOf(found[1])}`,
                    text: line.trim(),
                })
            })
            return hits
        },
    },
]

/*
 * One row per (site, file, bound) with a count, not one per line. Line numbers
 * drift with every edit above them, and a ledger that has to be re-blessed for
 * an unrelated insertion is a ledger people stop reading. This is the key
 * `tooling/forbidden-requirements/census.tsv` uses for the same reason.
 */
export function detect(files) {
    const found = new Map()
    for (const [path, body] of files) {
        const stripped = withoutComments(path, body)
        for (const detector of DETECTORS) {
            for (const hit of detector.match(stripped, path)) {
                const key = `${detector.site}\t${path}\t${hit.bound}`
                const existing = found.get(key)
                if (existing === undefined) {
                    found.set(key, {
                        site: detector.site,
                        path,
                        bound: hit.bound,
                        count: 1,
                        lines: [hit.line],
                    })
                } else {
                    existing.count += 1
                    existing.lines.push(hit.line)
                }
            }
        }
    }
    return found
}

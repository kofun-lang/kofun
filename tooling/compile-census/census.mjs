/*
 * The compile census (#1485), the standing form of #1205's last measurement.
 *
 * #1205 removed repeated C compilation from `task verify` in five migrations.
 * Its final criterion asks for the result to be a *standing property* rather
 * than a reading: "a threshold picked after seeing 16.0% would be post-hoc, so
 * what this asks for is a gate: the census key is computed on every full run
 * and the share is asserted against a recorded ceiling, so a later change that
 * re-splits a shared object family fails rather than quietly costing the time
 * back."
 *
 * The key is the whole of it. The same run answers three different numbers
 * depending on what counts as "the same compile", and the umbrella's own
 * census measured them 9x apart:
 *
 *   basename of the source          overstates  (one name, several files)
 *   verbatim effective argv          1.8%       understates
 *   codegen flags + sources + -D    16.0%       the answering key
 *
 * Verbatim argv understates because it contains `-o <path>`, which is unique
 * per gate: two invocations that compile identical bytes with identical
 * codegen settings into differently named outputs are the same work and a
 * verbatim key calls them different. Basenames overstate the other way. This
 * file computes both surviving keys, because reporting one alone is how the
 * 9x went unnoticed the first time.
 */

/*
 * Options that change the object a compile produces. An option outside this
 * set may still be necessary — `-o`, `-I`, warning flags — but two compiles
 * that differ only in one of those produce interchangeable objects, which is
 * exactly the question the key asks.
 *
 * `-D` is codegen-affecting and is collected separately rather than folded in,
 * because a macro difference is the one that the reuse work must never
 * flatten: `KOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY` and
 * `KOFUN_TEST_DIAGNOSTIC_FAULTS` are what make two otherwise identical
 * compiles genuinely different objects.
 */
const CODEGEN_EXACT = new Set([
    '-c', '-g', '-O0', '-O1', '-O2', '-O3', '-Os', '-Ofast',
    '-fPIC', '-fpic', '-fPIE', '-fno-omit-frame-pointer', '-fomit-frame-pointer',
    '-fanalyzer', '--analyze', '-fno-strict-aliasing', '-fwrapv',
    '-fvisibility=hidden', '-shared', '-static', '-pthread', '-m32', '-m64',
])

const CODEGEN_PREFIX = [
    '-fsanitize=', '-fno-sanitize=', '-std=', '-march=', '-mtune=', '-mcpu=',
    '-target', '--target=', '-fprofile', '-fcoverage', '-flto',
]

/* Options that take their value as the following argument. Skipping the value
 * matters for `-o out.o`: without this the output path would be read as a
 * source and every compile would look like it had a unique input. */
const VALUE_OPTIONS = new Set(['-o', '-I', '-isystem', '-include', '-L', '-l', '-x'])

const SOURCE_SUFFIX = ['.c', '.h', '.inc', '.cc', '.cpp', '.S', '.s']

const NUL = String.fromCharCode(0)

export function decodeArgv(hex) {
    if (typeof hex !== 'string' || hex.length % 2 !== 0) return null
    if (hex.length && !/^[0-9a-f]+$/.test(hex)) return null
    const bytes = []
    for (let index = 0; index < hex.length; index += 2) {
        bytes.push(Number.parseInt(hex.slice(index, index + 2), 16))
    }
    const text = Buffer.from(bytes).toString('utf8')
    /* The wrapper writes each argument NUL-terminated, so the split leaves a
     * trailing empty element rather than an empty final argument. */
    const parts = text.split(NUL)
    if (parts.length && parts[parts.length - 1] === '') parts.pop()
    return parts
}

export function isSource(argument) {
    if (argument.startsWith('-')) return false
    return SOURCE_SUFFIX.some((suffix) => argument.endsWith(suffix))
}

/*
 * Paths in the census are absolute, because the gates pass `$ROOT/...`. A key
 * built from them describes one checkout rather than the tree: the ledger
 * would be unreadable by anyone else, and would change when the worktree
 * moved, which is a property of the reader and not of the repository.
 */
export function relativize(argument, root) {
    if (!root) return argument
    const prefix = root.endsWith('/') ? root : `${root}/`
    return argument.startsWith(prefix) ? argument.slice(prefix.length) : argument
}

function isCodegen(argument) {
    if (CODEGEN_EXACT.has(argument)) return true
    return CODEGEN_PREFIX.some((prefix) => argument.startsWith(prefix))
}

/*
 * The answering key: what the object is made of and how it was made, with
 * everything that only says where to put it or what to warn about removed.
 *
 * Sources are sorted. Two invocations listing the same translation units in a
 * different order compile the same thing, and an order-sensitive key would
 * report them as distinct work — the same class of mistake as the output path,
 * one level subtler.
 */
export function codegenKey(argv, root = '') {
    const codegen = []
    const macros = []
    const sources = []
    for (let index = 1; index < argv.length; index += 1) {
        const argument = argv[index]
        if (VALUE_OPTIONS.has(argument)) {
            index += 1
            continue
        }
        if (argument.startsWith('-D')) {
            macros.push(argument)
            continue
        }
        if (isCodegen(argument)) {
            codegen.push(argument)
            continue
        }
        if (isSource(argument)) sources.push(relativize(argument, root))
    }
    return [
        codegen.slice().sort().join(' '),
        macros.slice().sort().join(' '),
        sources.slice().sort().join(' '),
    ].join('|')
}

/* The key the umbrella's criterion originally named, kept so the two can be
 * reported side by side. It is not wrong, it answers a different question:
 * "was this exact command run twice", not "was this object built twice". */
export function verbatimKey(argv, root = '') {
    return argv.map((argument) => relativize(argument, root)).join(' ')
}

/*
 * A compile, as opposed to a link. The repository routinely compiles and links
 * in one invocation, so `-c` is not the test — the presence of a translation
 * unit is. An invocation whose inputs are all `.o` performs no compilation, so
 * counting it as repeated compilation would put linker time into a number the
 * reuse work cannot move. It would also group badly: with an empty source set
 * every such invocation sharing codegen flags collapses into one family, which
 * reports a relationship between unrelated links.
 */
export function isCompile(argv, root = '') {
    return codegenKey(argv, root).split('|')[2] !== ''
}

/*
 * A compile of sources that exist for this run only.
 *
 * Two shapes reach the census: mutants written under `mktemp -d`, and trees
 * unpacked into `build/…/.sufficient.<pid>/`. Both carry a fresh path every
 * run, so each is its own family by construction and can never be repeated
 * work. Left in, they would inflate the distinct count with noise and — the
 * part that matters — a ledger row naming one would be stale the moment it was
 * written.
 */
export function isEphemeral(argv, root = '') {
    const sources = codegenKey(argv, root).split('|')[2]
    if (!sources) return false
    return sources.split(' ').some(
        (source) => source.startsWith('/') || source.startsWith('build/'),
    )
}

/*
 * `bin/kofun` builds `kofun-module-resolver` into `build/module-resolver` and
 * reuses it across runs, so a census taken with a warm `build/` is missing that
 * compile. CI starts clean and always has it; a developer running verify twice
 * does not.
 *
 * Detecting it from the census is exact — the compile is either in the log or
 * it is not — and it is the difference between a gate that explains itself and
 * one that tells every local run to lower a ceiling that is correct.
 */
export function sawLauncherResolver(rows) {
    return rows.some((row) => row.output === 'kofun-module-resolver')
}

export function parseRow(line) {
    if (!line.startsWith('cc\t')) return null
    const row = {}
    for (const field of line.split('\t').slice(1)) {
        const at = field.indexOf('=')
        if (at < 0) continue
        row[field.slice(0, at)] = field.slice(at + 1)
    }
    return row
}

export function parseCensus(text) {
    return text.split('\n').map(parseRow).filter(Boolean)
}

/*
 * Group by a key and total the wall time of every invocation after the first
 * in each group. The first is first-time work no reuse removes; the rest is
 * what the migrations were for.
 */
export function repeatedWork(rows, keyOf, root = '') {
    const groups = new Map()
    for (const row of rows) {
        const argv = decodeArgv(row.argv_hex)
        if (!argv) continue
        if (!isCompile(argv, root)) continue
        if (isEphemeral(argv, root)) continue
        const key = keyOf(argv, root)
        const wall = Number.parseInt(row.wall_ns ?? '0', 10)
        const group = groups.get(key) ?? { count: 0, wallNs: 0, firstWallNs: 0 }
        group.count += 1
        if (group.count === 1) group.firstWallNs = Number.isFinite(wall) ? wall : 0
        else group.wallNs += Number.isFinite(wall) ? wall : 0
        groups.set(key, group)
    }
    let repeatedCount = 0
    let repeatedWallNs = 0
    for (const group of groups.values()) {
        repeatedCount += group.count - 1
        repeatedWallNs += group.wallNs
    }
    return { distinct: groups.size, repeatedCount, repeatedWallNs, groups }
}

export function summarize(rows, root = '') {
    const failures = rows.filter((row) => row.status !== '0').length
    const profiles = new Set()
    let compiles = 0
    let links = 0
    let ephemeral = 0
    let wallNs = 0
    for (const row of rows) {
        const argv = decodeArgv(row.argv_hex)
        if (!argv) continue
        if (isCompile(argv, root)) {
            if (isEphemeral(argv, root)) ephemeral += 1
            else compiles += 1
            profiles.add(codegenKey(argv, root).split('|')[0])
        } else {
            links += 1
        }
        const wall = Number.parseInt(row.wall_ns ?? '0', 10)
        if (Number.isFinite(wall)) wallNs += wall
    }
    return {
        invocations: rows.length,
        compiles,
        links,
        ephemeral,
        warmLauncherCache: !sawLauncherResolver(rows),
        failures,
        flagProfiles: profiles.size,
        wallNs,
        codegen: repeatedWork(rows, codegenKey, root),
        verbatim: repeatedWork(rows, verbatimKey, root),
    }
}

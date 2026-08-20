/*
 * Detectors for `spec/native-toolchain-v1/contract.json`'s
 * `forbidden_core_build_requirements`, separated from the checker so the
 * self-test can drive them over fixtures without scanning the repository.
 *
 * Two kinds of use, because they are different facts:
 *
 *   `invoke`  a command-position invocation — the build shells out to the tool.
 *   `source`  the file is written in that language, so running it requires the
 *             tool whether or not anything invokes it by name.
 *
 * A count is only meaningful with its predicate attached, so every detector
 * carries the shell command that answers the same question. Both halves of a
 * count can be too narrow at once and the product still looks plausible: this
 * repository shipped "46 gate scripts shell out to node" when the answer over
 * all tracked `.sh` was 70, because the file set was `tests/**` plus
 * `tooling/*` and the pattern required a trailing space. Neither narrowing was
 * visible in the number.
 */

/*
 * A count has two halves and each can be too narrow on its own, so the file set
 * is stated once, here, and every detector's `predicate` states only the other
 * half. `$FILES` below is that file set spelled as a command.
 *
 * The universe is what *runs*: shell, JavaScript, the task and workflow
 * definitions, and every tracked file carrying a shebang. Deliberately outside
 * it, because a name in them is prose or data rather than a build requirement:
 * `*.md` (which says `node` constantly), `*.kofun` fixtures, and `*.c`/`*.h`
 * sources — a C file cannot invoke anything. What that boundary hides is
 * reported rather than dropped: `--count` prints the tracked `*.c`/`*.h` total,
 * because those files do require a C compiler even though no line in them
 * invokes one.
 */
export const FILE_SET =
    "FILES=\"$(git ls-files '*.sh' '*.mjs' '*.js' '*.yml' '*.yaml'; " +
    "git ls-files | while read -r f; do head -c2 \"$f\" | grep -q '#!' && echo \"$f\"; done)\""

/*
 * Command position. A token counts as invoked when it starts a command: at the
 * start of a line, after a shell operator, inside `$(`, or after one of the
 * wrappers that run their argument. It must be followed by whitespace, a
 * quote, or the end of the line — `nodejs-flavour` and `taskfile` are not
 * invocations of `node` and `task`.
 *
 * The wrapper list is what a `(^|[|;&(`]|\$\()` pattern alone misses:
 * `exec node`, `xargs node`, `env node`, and `command -v node` all invoke it.
 */
const WRAPPERS = 'exec|command|env|xargs|sudo|time|nice|then|do|else|elif|if'
/*
 * A command may be preceded by environment assignments on the same line:
 *
 *     KOFUN_STAGE2_COMMON_LINK_ID=documentation-index/producer \\
 *     "$CC" -std=c11 …
 *
 * Five gate scripts open their compile line exactly that way, and a rule that
 * only accepts an operator before the command name reports all five as clean.
 */
const ASSIGN = String.raw`(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)[ \t]+)*`

/*
 * `(` opens a subshell — but only when nothing identifier-like precedes it.
 * `foo(node)` is a call, and the census recorded
 * `tests/conformance/int-bits-lowering/check.sh` as invoking Node.js on the
 * strength of `def find(node):` inside a Python heredoc it embeds. Every
 * occurrence of the word in that file is a parameter name (#1500).
 *
 * And `$(` at end of line opens a command on the NEXT line. Measured: 80
 * sites in tracked shell open that way, none of them with a forbidden
 * requirement today — so this half fixes no count now and stops the next one
 * being silent.
 */
const OPEN = String.raw`(?:^|(?<![A-Za-z0-9_])[(]|[|;&){}\`\n!]|\$\([ \t]*\n?[ \t]*|&&|\|\||(?:\b(?:${WRAPPERS})\b(?:\s+[-!]\w*)*\s+))${ASSIGN}`
const CLOSE = String.raw`(?=\s|$|['"\`;|&)])`

/*
 * Command position is not one thing, and reading it as one is how a census
 * acquires both false positives and false negatives in the same pass:
 *
 *   - shell    a backtick opens a command substitution;
 *   - JS       a backtick opens a *template literal*, so the shell rule filed
 *              `` `task limit exceeded` `` — an error message — as an
 *              invocation of the task runner, in three model files;
 *   - YAML     `- run: task verify` is the whole of how CI invokes anything,
 *              and no shell operator appears anywhere on the line, so the
 *              shell rule reported the CI workflow as calling nothing.
 *
 * JavaScript does not have a command position at all. What it has is a
 * child-process call, so that is what is matched: the tool must be the first
 * token of the string handed to one.
 */
const JS_SPAWN = String.raw`(?:execFileSync|execSync|spawnSync|execFile|spawn|exec)\s*\(\s*['"\`]\s*`
const YAML_OPEN = String.raw`(?:^|[|;&(){}\n!]|\$\(|&&|\|\||run:\s*|cmd:\s*|-\s+)["']?${ASSIGN}`

export function commandPosition(token, dialect = 'sh') {
    if (dialect === 'js') return new RegExp(`${JS_SPAWN}(?:${token})${CLOSE}`, 'gm')
    if (dialect === 'yaml') return new RegExp(`${YAML_OPEN}[ \\t]*(?:${token})${CLOSE}`, 'gm')
    return new RegExp(`${OPEN}[ \\t]*(?:${token})${CLOSE}`, 'gm')
}

export function dialectOf(path) {
    if (path.endsWith('.mjs') || path.endsWith('.js')) return 'js'
    if (path.endsWith('.yml') || path.endsWith('.yaml')) return 'yaml'
    return 'sh'
}

/* A literal flag or fragment anywhere on the line — linker and SDK flags are
 * arguments, never command names, so command position would find none of them. */
function anywhere(pattern) {
    return new RegExp(pattern, 'gm')
}

/*
 * Shell continuations joined, so a flag on its own line still belongs to the
 * command that opened it. Without this, the overwhelmingly common
 *
 *     cc -o out in.c \
 *        -lm
 *
 * puts `cc` and `-lm` on different lines, and any rule that asks "is this flag
 * on a compiler line?" answers no for the normal case.
 */
export function logicalLines(body) {
    return body.replace(/\\\n\s*/g, ' ').split('\n')
}

/*
 * A compiler or linker driver appearing on a line. `-lm` is an import library
 * only when something links with it; on a shell `[ "$n" -lt 3 ]` it is the
 * `less than` operator. Measured before narrowing: a bare `-l[a-z]+` rule
 * matched 59 files, of which the true positives were four occurrences of `-lm`
 * — the rest were `-lt` (82), `-le` (33), grep's `-lE`, and `-length`.
 */
const HEAD = String.raw`(?:^|[|;&(\`!]|\$\()[ \t]*${ASSIGN}"?`
const LINKS = new RegExp(
    `${HEAD}(?:cc|gcc|clang|c\\+\\+|g\\+\\+|clang\\+\\+|ld|lld|\\$\\{?CC\\}?|\\$\\{?CXX\\}?|\\$\\{?LD\\}?)"?(?=\\s)`,
)

/*
 * A C compiler is very often held in a variable, and the variable is not called
 * `CC`. Measured on this tree: 23 files carry `-std=c` and none of them was in
 * a `cc` census built from the literal spellings alone — the driver is
 * `"$ANALYZER_CC"`, `"$real_cc"`, `"$host_compiler"`, `"$kofun_stage1_cc"`.
 *
 * Matching on the *name* would be worse than missing them, because
 * `"$STAGE2_COMPILER"` and `"$WASM_COMPILER"` hold the **Kofun** compiler, and
 * a name-based rule would file every Kofun invocation as a C compiler use. So
 * the discriminator is what the line does, not what the variable is called: a
 * C compiler is being run when the line carries a C compiler's flags.
 */
const VAR_COMMAND = new RegExp(`${HEAD}\\$\\{?[A-Za-z_][A-Za-z0-9_]*(?::[-=?+][^}]*)?\\}?"?(?=\\s)`)
const C_SIGNATURE = /-std=c|-fanalyzer|-fsanitize=|-Wa,|-Wl,|\S+\.c(?=\s)/

/*
 * A variable *named* for a C compiler, which is the one place a name-based rule
 * is safe. `exec "$KOFUN_VERIFY_REAL_CC" "$@"` passes the caller's arguments
 * straight through, so the line carries no C flag to recognise it by, and the
 * flag-based rule above cannot see it. The suffix is `CC`/`cc` only —
 * deliberately not `COMPILER`, because `"$STAGE2_COMPILER"` and
 * `"$WASM_COMPILER"` hold the Kofun compiler and would be filed as C uses.
 */
const CC_NAMED_VAR = new RegExp(
    `${HEAD}\\$\\{?(?:[A-Za-z_][A-Za-z0-9_]*_)?(?:CC|cc)(?::[-=?+][^}]*)?\\}?"?(?=\\s)`,
)

export function isCCompileLine(line) {
    if (LINKS.test(line)) return true
    if (CC_NAMED_VAR.test(line)) return true
    return VAR_COMMAND.test(line) && C_SIGNATURE.test(line)
}

const SH_EXTENSIONS = ['.sh']
const NODE_EXTENSIONS = ['.mjs', '.js']

const endsWith = (list) => (path) => list.some((ext) => path.endsWith(ext))

/*
 * `source` detectors need the interpreter a shebang names, because three of
 * this repository's drivers carry no extension at all: `bin/kofun`,
 * `bin/kofun-digest`, and `tooling/lsp/kofun-lsp`. A file-extension file set
 * misses the CLI driver, which is the largest single shell surface in the tree.
 */
const shebangNames = (body, ...names) => {
    const first = body.split('\n', 1)[0]
    if (!first.startsWith('#!')) return false
    return names.some((name) => new RegExp(String.raw`\b${name}\b`).test(first))
}

/*
 * One entry per member of `forbidden_core_build_requirements`. The list of
 * requirements itself is never written here — the checker reads it from the
 * contract and fails when a requirement has no detector, so adding a
 * requirement to the contract cannot silently go unmeasured.
 */
export const DETECTORS = [
    {
        requirement: 'cc',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*"?(cc|gcc|clang|c99|\$\{?CC\}?)"?[ ]'` +
            String.raw` # plus one per continuation-joined line running "$SOME_VAR" with -std=c, -fanalyzer, -fsanitize=, or a *.c argument`,
        describes: 'a C compiler invoked as a command, by name, through $CC, or through any variable on a line carrying C compiler flags',
        match: (body, dialect) => {
            const hits = []
            for (const line of logicalLines(body)) {
                const direct = line.match(commandPosition(String.raw`cc|gcc|clang|c99`, dialect))
                if (direct !== null) {
                    hits.push(...direct)
                    continue
                }
                if (isCCompileLine(line)) hits.push(line.trim().slice(0, 40))
            }
            /*
             * JavaScript spawns it by name rather than at a command position:
             * `execFileSync(process.env.CC ?? "cc", ["-std=c11", …])`. The
             * shell-shaped rules above see none of that.
             */
            hits.push(...(body.match(anywhere(String.raw`process\.env\.(?:CC|CXX)\b`)) ?? []))
            return hits
        },
    },
    {
        requirement: 'c++',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*(c\+\+|g\+\+|clang\+\+|\$\{?CXX\}?)[ ]'`,
        describes: 'a C++ compiler invoked as a command, including through $CXX',
        match: (body, dialect) => body.match(commandPosition(String.raw`c\+\+|g\+\+|clang\+\+|\$CXX|\$\{CXX\}|"\$CXX"`, dialect)) ?? [],
    },
    {
        requirement: 'assembler',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*(nasm|yasm|gas)[ ]|[ ]as[ ]+(-|\S+\.[sS]\b)|-Wa,'`,
        describes: 'a standalone assembler, or a compiler driver passing -Wa,',
        /*
         * `as` is not matched as a bare word. It is an English preposition and
         * a JavaScript-adjacent noise token: measured before narrowing, a bare
         * `as` matched four files and every hit was `` ` as`` or `} as` inside
         * prose. It counts only when followed by a flag or an assembly source.
         */
        match: (body, dialect) => [
            ...(body.match(commandPosition(String.raw`nasm|yasm|gas`, dialect)) ?? []),
            ...(body.match(anywhere(String.raw`(?:^|[|;&(\`]|\$\()[ \t]*as[ \t]+(?:-|\S+\.[sS](?=\s|$))`)) ?? []),
            ...(body.match(anywhere(String.raw`-Wa,`)) ?? []),
        ],
    },
    {
        requirement: 'system-linker',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*(ld|lld|link)[ ]|-Wl,|-fuse-ld='`,
        describes: 'a linker invoked directly, or a compiler driver passing -Wl, / -fuse-ld=',
        match: (body, dialect) => [
            ...(body.match(commandPosition(String.raw`ld|lld|ld\.lld|link\.exe`, dialect)) ?? []),
            ...(body.match(anywhere(String.raw`-Wl,|-fuse-ld=`)) ?? []),
        ],
    },
    {
        requirement: 'rustc',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*rustc[ ]'`,
        describes: 'the Rust compiler invoked as a command',
        match: (body, dialect) => body.match(commandPosition('rustc', dialect)) ?? [],
    },
    {
        requirement: 'cargo',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*cargo[ ]'`,
        describes: 'Cargo invoked as a command',
        match: (body, dialect) => body.match(commandPosition('cargo', dialect)) ?? [],
    },
    {
        requirement: 'zig',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*zig[ ]'`,
        describes: 'the Zig toolchain invoked as a command',
        match: (body, dialect) => body.match(commandPosition('zig', dialect)) ?? [],
    },
    {
        requirement: 'node',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\(|run:[ ]*|cmd:[ ]*|-[ ]+)[ ]*(node|npm)[ ]'`,
        describes: 'Node.js or its npm package-manager frontend invoked as a command',
        match: (body, dialect) => body.match(commandPosition('node|npm', dialect)) ?? [],
    },
    {
        requirement: 'node',
        kind: 'source',
        predicate: String.raw`git ls-files '*.mjs' '*.js'`,
        describes: 'a file written in JavaScript, which cannot run without Node.js',
        selects: (path, body) => endsWith(NODE_EXTENSIONS)(path) || shebangNames(body, 'node'),
    },
    {
        requirement: 'python',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*python3?[ ]'`,
        describes: 'a Python interpreter invoked as a command',
        match: (body, dialect) => body.match(commandPosition(String.raw`python3?`, dialect)) ?? [],
    },
    {
        requirement: 'shell-build-driver',
        kind: 'source',
        predicate: String.raw`git ls-files '*.sh'; git ls-files | xargs -I{} sh -c 'head -1 {} | grep -lq "^#!.*\b(sh|bash|dash)\b"'`,
        describes: 'a file written in shell that drives a build, gate, or command',
        selects: (path, body) => endsWith(SH_EXTENSIONS)(path) || shebangNames(body, 'sh', 'bash', 'dash'),
    },
    {
        requirement: 'go-task',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*task[ ]'`,
        describes: 'the go-task runner invoked as a command',
        match: (body, dialect) => body.match(commandPosition('task', dialect)) ?? [],
    },
    {
        requirement: 'go-task',
        kind: 'source',
        predicate: 'git ls-files Taskfile.yml',
        describes: "the build definition written in go-task's own file format",
        selects: (path) => path === 'Taskfile.yml' || path.endsWith('/Taskfile.yml'),
    },
    {
        requirement: 'system-sdk',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(xcrun|xcodebuild|pkg-config|--sysroot|-isysroot|WindowsSdkDir)'`,
        describes: 'a platform SDK located or selected at build time',
        match: (body, dialect) => [
            ...(body.match(commandPosition(String.raw`xcrun|xcodebuild|pkg-config`, dialect)) ?? []),
            ...(body.match(anywhere(String.raw`--sysroot|-isysroot|WindowsSdkDir`)) ?? []),
        ],
    },
    {
        requirement: 'import-library',
        kind: 'invoke',
        predicate:
            '$FILES | xargs awk \'/\\\\$/{h=h $0; sub(/\\\\$/,"",h); next} {l=h $0; h=""; ' +
            'if (l ~ /(^|[|;&(]|\\$\\()[ ]*(cc|gcc|clang|ld|\\$\\{?CC\\}?)[ ]/) while (match(l, / -l[a-zA-Z][a-zA-Z0-9_+-]*/)) ' +
            '{n++; l=substr(l, RSTART+RLENGTH)}} END{print n+0}\'  # plus: grep -coE \'\\.dll\\.a|dlltool\'',
        describes: 'a link against a named import or shared library, counted only on linker lines',
        /*
         * `-lm` is an import library only when something links with it. On a
         * shell line it is far more often `[ "$n" -lt 3 ]`. So the flag is
         * counted only on a logical line that also runs a compiler or linker
         * driver, and continuations are joined first because the flag is
         * usually on the next physical line.
         */
        match: (body, dialect) => {
            const hits = []
            for (const line of logicalLines(body)) {
                if (!isCCompileLine(line)) continue
                hits.push(...(line.match(/(?<=\s)-l[a-zA-Z][a-zA-Z0-9_+-]*(?=\s|$|['"])/g) ?? []))
            }
            hits.push(...(body.match(anywhere(String.raw`\.dll\.a\b|\bdlltool\b`)) ?? []))
            return hits
        },
    },
    {
        requirement: 'non-kofun-build-language',
        kind: 'source',
        /*
         * Deliberately NOT the union of the rows above. Every `.sh` and `.mjs`
         * in the tree is trivially "a build language that is not Kofun", and a
         * row per file here would restate `shell-build-driver` and `node`
         * without adding a fact — two lists of one fact, defended unequally.
         *
         * What this requirement adds, and nothing else in the contract covers,
         * is a *second build system*: a build described in a third language
         * that neither shell nor the task runner already accounts for.
         */
        predicate: "git ls-files 'Makefile' '*.mk' 'CMakeLists.txt' 'build.zig' 'meson.build' 'build.gradle' '*.cmake'",
        describes: 'a build described in a third build language — make, cmake, meson, gradle, or zig build',
        selects: (path) => [
            /(^|\/)Makefile$/, /\.mk$/, /(^|\/)CMakeLists\.txt$/, /\.cmake$/,
            /(^|\/)build\.zig$/, /(^|\/)meson\.build$/, /(^|\/)build\.gradle$/,
        ].some((re) => re.test(path)),
    },
]

/*
 * Comments are not uses. `86 mention node; 70 invoke it` — that 16-file gap is
 * the distinction a census has to make, and a checker that picks one meaning
 * silently is the failure this file exists to avoid.
 *
 * Known limit, stated rather than left to be discovered: a `#` inside a
 * double-quoted shell string preceded by whitespace is stripped as a comment,
 * so `sh -c "run # node here"` would be under-counted. Stripping can only lose
 * matches, never invent them, so the error direction is a missed use — which is
 * why `--count` prints the mention totals beside the invoke totals.
 */
export function withoutComments(path, body) {
    if (path.endsWith('.mjs') || path.endsWith('.js')) {
        return body
            .replace(/\/\*[^]*?\*\//g, ' ')
            .replace(/^\s*\/\/.*$/gm, ' ')
    }
    return body.replace(/(^|\s)#.*$/gm, '$1')
}

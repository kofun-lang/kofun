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
 * Command position, read rather than pattern-matched (#1552).
 *
 * A token counts as invoked when it is the word the shell would run: at the
 * start of a command, after the assignments that may precede one, and after the
 * wrappers that run their argument. What made this a model instead of a pattern
 * is that a regular expression cannot tell executable text from prose about it.
 * Measured on `main@a858e0fa`, the pattern this replaces reported:
 *
 *     echo env node                       1   invented
 *     printf '%s\n' 'command node'        1   invented
 *     command env -- node                 0   missed
 *     env xargs -- npm                    0   missed
 *     xargs env -- npm                    0   missed
 *     env -- command node                 1   invented
 *     xargs -- command node               1   invented
 *
 * The first two are the shortcut: an unanchored `wrapper\s+` branch matches the
 * word `env` wherever it appears, including inside a single-quoted string that
 * is the *text of a generated script*. The middle three are wrapper chains it
 * had no way to compose. The last two are the same shortcut in the other
 * direction: external `env` and `xargs` cannot resolve the shell builtin
 * `command`, so what runs there is `command`, and `node` is its argument.
 *
 * So the shell text is tokenised once -- words and operators, with quoted
 * regions kept inside the word that contains them -- and command position is a
 * property of where a word sits rather than of what precedes it in the string.
 *
 * WHAT IS DELIBERATELY NOT MODELLED, because guessing is worse than refusing:
 * long wrapper options, options that consume the following argument, runtime
 * expansion, and dynamic command names. Each of those returns "no invocation
 * here" rather than a guess, and each has a case below.
 */

/* Wrappers the shell resolves itself, so they can run a builtin or an external. */
const SHELL_WRAPPERS = new Set(['command', 'exec', 'builtin', 'time', 'nice', 'sudo'])
/* Wrappers that are external programs, so they can only exec another external. */
const EXTERNAL_WRAPPERS = new Set(['env', 'xargs'])
/* Keywords a command may follow. `if -- node` invokes `--`, not Node.js, so
 * these are not wrappers and take no terminator. */
const FLOW = new Set(['then', 'do', 'else', 'elif', 'if', 'while', 'until'])
/* Operators after which the next word starts a command. */
const OPENS_COMMAND = new Set([';', ';;', '&&', '||', '|', '&', '(', ')', '$(', '`', '\n', '{', '}', '!'])

const isOption = (word) => /^-[A-Za-z0-9]+$/.test(word)
/*
 * A command may be preceded by environment assignments:
 *
 *     KOFUN_STAGE2_COMMON_LINK_ID=documentation-index/producer \
 *     "$CC" -std=c11 …
 *
 * Five gate scripts open their compile line exactly that way, and a rule that
 * only accepts an operator before the command name reports all five as clean.
 */
const isAssignment = (word) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(word)

/*
 * Words and operators. A quoted region is part of the word containing it and is
 * never re-read as shell: that one property is what stops
 * `printf '%s\n' 'exec node …'` -- the text of a script this one writes -- from
 * being counted as an invocation of Node.js, which is the live case in
 * `tests/conformance/backends/wasm32-node.sh`.
 */
export function shellTokens(body, commentRanges = null) {
    const tokens = []
    let word = null
    let i = 0
    /*
     * Where the scanner is. Double quotes are not opaque -- `"$(rustc -Vv)"`
     * runs rustc, and reading the whole quoted span as text lost three real
     * invocations in `examples/rust-shim/benchmark.sh` -- so a substitution
     * inside them opens a nested context that the matching `)` closes. Single
     * quotes are opaque, because nothing expands inside them, which is what
     * makes `'exec node …'` the text of a script rather than a command.
     */
    const context = ['top']
    const inside = () => context[context.length - 1]
    /*
     * Here-document bodies are data, not shell. Reading them as shell is both
     * wrong and unstable: an apostrophe in English prose inside one opens a
     * quoted region that swallows the rest of the file, which is measurable --
     * before this, one `don't` in `tests/usability/check.sh` hid every
     * invocation after line 407. Skipping the body is also the answer the
     * census wants for the case that started #1552: a heredoc holding the text
     * of a script this one writes is not this script running it.
     */
    const pendingHeredocs = []
    const heredocDelimiter = (text) => {
        const match = /^<<-?\s*(.+)$/.exec(text)
        if (match === null) return null
        const raw = match[1].trim()
        if (raw === '' || raw.startsWith('<')) return null
        return { word: raw.replace(/^['"]|['"]$/g, ''), strip: text.startsWith('<<-') }
    }

    const endWord = () => {
        if (word !== null) {
            const heredoc = heredocDelimiter(word.text)
            if (heredoc !== null) pendingHeredocs.push(heredoc)
            tokens.push(word)
            word = null
        }
    }
    const pushOperator = (text) => { endWord(); tokens.push({ kind: 'op', text }) }
    /*
     * `quoted` records whether the word *opens* with a quote, which is the
     * question every rule below asks: `'command node'` is prose because the
     * quote comes first, while `KOFUN_RFC_TODAY="$horizon"` is an assignment
     * whose value happens to be quoted. Marking the whole word quoted lost the
     * second shape in six files -- every `NAME="value" command` line in the
     * tree.
     */
    const addToWord = (text, quoted, at) => {
        if (word === null) word = { kind: 'word', text: '', quoted, start: at }
        word.text += text
    }

    while (i < body.length) {
        const c = body[i]

        /* An escaped newline continues the command; any other escape is part of
         * the word, so `\;` is an argument and `` \` `` is not a substitution. */
        if (c === '\\' && body[i + 1] === '\n') { i += 2; continue }
        if (c === '\\') { addToWord(body.slice(i, i + 2), false, i); i += 2; continue }

        if (c === '$' && body[i + 1] === '(') {
            pushOperator('$(')
            context.push('subst')
            i += 2
            continue
        }

        if (inside() === 'dquote') {
            if (c === '"') { addToWord(c, true, i); context.pop(); i += 1; continue }
            if (c === '`') { pushOperator('`'); context.push('subst'); i += 1; continue }
            addToWord(c, true, i)
            i += 1
            continue
        }

        if (c === ' ' || c === '\t') { endWord(); i += 1; continue }

        /*
         * A `#` opens a comment only where a word could start. Inside a word it
         * is a character, and the difference is load-bearing: the old
         * line-oriented strip cut
         *
         *     assert_grep "row $item does not name issue #$owner in its header"
         *
         * at the `#`, leaving an unterminated quote that swallowed the rest of
         * `tests/usability/check.sh` -- every `rustc` invocation after line 122
         * went uncounted once the scan became stateful.
         */
        if (c === '#' && word === null) {
            const lineEnd = body.indexOf('\n', i)
            const stop = lineEnd === -1 ? body.length : lineEnd
            if (commentRanges !== null) commentRanges.push([i, stop])
            i = stop
            continue
        }

        /* Single and ANSI-C quoting: opaque, and the closing quote is found
         * here rather than by a pattern so operators inside stay text. */
        if (c === "'" || (c === '$' && body[i + 1] === "'")) {
            const open = c === '$' ? i + 1 : i
            let j = open + 1
            while (j < body.length && body[j] !== "'") j += 1
            addToWord(body.slice(i, Math.min(j + 1, body.length)), true, i)
            i = j + 1
            continue
        }

        if (c === '"') { addToWord(c, true, i); context.push('dquote'); i += 1; continue }

        if (c === ')' && inside() === 'subst') { context.pop(); pushOperator(')'); i += 1; continue }

        if (c === ';' && body[i + 1] === ';') { pushOperator(';;'); i += 2; continue }
        if (c === '&' && body[i + 1] === '&') { pushOperator('&&'); i += 2; continue }
        if (c === '|' && body[i + 1] === '|') { pushOperator('||'); i += 2; continue }
        /*
         * `(` opens a subshell -- but only when nothing identifier-like
         * precedes it. `foo(node)` is a call, and the census recorded
         * `tests/conformance/int-bits-lowering/check.sh` as invoking Node.js on
         * the strength of `def find(node):` inside a Python heredoc it embeds.
         * Every occurrence of the word in that file is a parameter name (#1500).
         */
        if ('({'.includes(c) && word !== null) { addToWord(c, false, i); i += 1; continue }
        /* `}` closes what `{` opened, so it follows the same rule: `${node}` is
         * one word naming a variable, and `{ node; }` is a group running one. */
        if (c === '}' && word !== null) { addToWord(c, false, i); i += 1; continue }
        if (c === '\n' && pendingHeredocs.length !== 0) {
            pushOperator('\n')
            i += 1
            while (pendingHeredocs.length !== 0) {
                const { word: delimiter, strip } = pendingHeredocs.shift()
                while (i < body.length) {
                    const lineEnd = body.indexOf('\n', i)
                    const line = body.slice(i, lineEnd === -1 ? body.length : lineEnd)
                    i = lineEnd === -1 ? body.length : lineEnd + 1
                    if ((strip ? line.replace(/^\t+/, '') : line) === delimiter) break
                }
            }
            continue
        }
        if (';&|()`\n{}!'.includes(c)) { pushOperator(c); i += 1; continue }

        addToWord(c, false, i)
        i += 1
    }
    endWord()
    return tokens
}

/*
 * The index of every token that is run, given the tokens of one file.
 *
 * `case` gets its own state because its patterns sit exactly where a command
 * would: in `case "$x" in\n  node) …`, the word `node` follows a newline and is
 * a pattern, not an invocation. The states are the three places a `case` can
 * be -- reading its subject, reading a pattern, running a body -- and anything
 * that does not fit them leaves the stack alone rather than guessing.
 */
export function commandHeads(tokens) {
    const heads = []
    const cases = []
    let atCommand = true

    for (let i = 0; i < tokens.length; i += 1) {
        const token = tokens[i]
        const open = cases.length === 0 ? null : cases[cases.length - 1]

        if (token.kind === 'op') {
            if (OPENS_COMMAND.has(token.text)) {
                atCommand = true
                if (open !== null && open.state === 'pattern' && token.text === ')') open.state = 'body'
                else if (open !== null && open.state === 'body' && token.text === ';;') open.state = 'pattern'
            }
            continue
        }

        /*
         * `esac` closes the construct from wherever it is reached, and where it
         * is reached from is `pattern`: every arm ends `;;`, which returns to
         * pattern state, and `esac` follows. Reading it only from a command
         * position left the machine inside the `case` for the rest of the file.
         */
        if (open !== null && token.text === 'esac' && !token.quoted) {
            cases.pop()
            atCommand = false
            continue
        }
        /*
         * `case "$target" in` puts its subject and its `in` where no command
         * can be, so these two states read every word rather than only the ones
         * in command position. Reading them like commands is what left the
         * machine waiting for an `in` it had already passed: measured on
         * `bin/kofun`, every `case` body in the file went uncounted.
         */
        if (open !== null && open.state === 'head') {
            if (token.text === 'in' && !token.quoted) open.state = 'pattern'
            atCommand = false
            continue
        }
        if (open !== null && open.state === 'pattern') { atCommand = false; continue }

        if (!atCommand) continue
        atCommand = false

        if (token.text === 'case' && !token.quoted) { cases.push({ state: 'head' }); continue }

        const head = runWord(tokens, i)
        if (head !== -1) heads.push(head)
    }
    return heads
}

/*
 * From a command position, skip assignments, flow keywords and wrapper chains,
 * and return the index of the word that is actually run -- or -1 where this
 * model refuses to guess.
 *
 * The composition rule is the one the shell has: `command env -- node` runs
 * node, because the shell resolves `command`, which execs `env`, which execs
 * `node`. `env -- command node` does not, because `env` is an external program
 * and cannot resolve a shell builtin; what it runs is a program named
 * `command`. So a shell wrapper may precede an external one and not the reverse.
 */
function runWord(tokens, from) {
    let i = from
    let external = false

    while (i < tokens.length) {
        const token = tokens[i]
        /* A wrapper and what it runs are one command: an operator, including a
         * newline, ends the chain rather than continuing it. */
        if (token.kind === 'op') return -1

        const word = token.text
        if (!token.quoted && FLOW.has(word)) { i += 1; continue }
        if (!token.quoted && isAssignment(word)) { i += 1; continue }

        const shellWrapper = !token.quoted && !external && SHELL_WRAPPERS.has(word)
        const externalWrapper = !token.quoted && EXTERNAL_WRAPPERS.has(word)
        if (!shellWrapper && !externalWrapper) return i

        const options = []
        let j = i + 1
        while (j < tokens.length && tokens[j].kind === 'word' && isOption(tokens[j].text)) {
            options.push(tokens[j].text)
            j += 1
        }

        if (j < tokens.length && tokens[j].kind === 'word' && tokens[j].text === '--') {
            /*
             * `--` ends option parsing, so the next word is the command -- but
             * only where the options before it are ones whose shape has been
             * measured. `xargs -n -- npm` reads `--` as the argument to `-n`,
             * and a rule that guessed otherwise would report an invocation the
             * shell does not make.
             */
            const measured = options.length === 0 ||
                (word === 'env' && options.length === 1 && options[0] === '-i')
            if (!measured) return -1
            const next = tokens[j + 1]
            /* After a terminator an assignment-shaped word is a program name:
             * `command -- FOO=bar node` runs a program called `FOO=bar`. */
            if (next === undefined || next.kind !== 'word') return -1
            return j + 1
        }

        if (externalWrapper) external = true
        i = j
    }
    return -1
}

/*
 * How many words one requirement's spelling may span. `openssl dgst` is two --
 * `tests/digest/no-host-digest-tools.mjs` matches the digest subcommand and not
 * the tool (#1213) -- and nothing here spans three.
 */
const SPAN = 3

/*
 * One body, tokenised once. The checker asks fourteen detectors about the same
 * file in a row, and this gate asks three; without this the scan reads every
 * file fourteen times and the census checker goes from 0.9s to 4.7s. A single
 * entry is the whole cache because the callers are loops over detectors inside
 * a loop over files -- the reuse is always immediate.
 */
let lastBody = null
let lastTokens = null
let lastHeads = null

function analyse(body) {
    if (body !== lastBody) {
        lastBody = body
        lastTokens = shellTokens(body)
        lastHeads = commandHeads(lastTokens)
    }
    return { tokens: lastTokens, heads: lastHeads }
}

function shellMatches(body, pattern) {
    const anchored = new RegExp(`^(?:${pattern})$`)
    const { tokens, heads } = analyse(body)
    const hits = []
    for (const head of heads) {
        let candidate = ''
        for (let n = 0; n < SPAN && head + n < tokens.length; n += 1) {
            const token = tokens[head + n]
            if (token.kind !== 'word') break
            candidate = n === 0 ? token.text : `${candidate} ${token.text}`
            if (anchored.test(candidate)) { hits.push(candidate); break }
        }
    }
    return hits
}

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
 * token of the string handed to one. These two stay patterns: #1552 replaced
 * the shell half only, and a `run:` key has no quoting rules to get wrong.
 */
const ASSIGN = String.raw`(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)[ \t]+)*`
const CLOSE = String.raw`(?=\s|$|['"\`;|&)])`
const JS_SPAWN = String.raw`(?:execFileSync|execSync|spawnSync|execFile|spawn|exec)\s*\(\s*['"\`]\s*`
const YAML_OPEN = String.raw`(?:^|[|;&(){}\n!]|\$\(|&&|\|\||run:\s*|cmd:\s*|-\s+)["']?${ASSIGN}`

/* Every invocation of `pattern` in `body`, as the text that was matched. */
export function matchCommands(body, pattern, dialect = 'sh') {
    if (dialect === 'js') {
        return body.match(new RegExp(`${JS_SPAWN}(?:${pattern})${CLOSE}`, 'gm')) ?? []
    }
    if (dialect === 'yaml') {
        return body.match(new RegExp(`${YAML_OPEN}[ \\t]*(?:${pattern})${CLOSE}`, 'gm')) ?? []
    }
    return shellMatches(body, pattern)
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
                const direct = matchCommands(line, String.raw`cc|gcc|clang|c99`, dialect)
                if (direct.length !== 0) {
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
        match: (body, dialect) => matchCommands(body, String.raw`c\+\+|g\+\+|clang\+\+|\$CXX|\$\{CXX\}|"\$CXX"`, dialect),
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
            ...(matchCommands(body, String.raw`nasm|yasm|gas`, dialect)),
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
            ...(matchCommands(body, String.raw`ld|lld|ld\.lld|link\.exe`, dialect)),
            ...(body.match(anywhere(String.raw`-Wl,|-fuse-ld=`)) ?? []),
        ],
    },
    {
        requirement: 'rustc',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*rustc[ ]'`,
        describes: 'the Rust compiler invoked as a command',
        match: (body, dialect) => matchCommands(body, 'rustc', dialect),
    },
    {
        requirement: 'cargo',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*cargo[ ]'`,
        describes: 'Cargo invoked as a command',
        match: (body, dialect) => matchCommands(body, 'cargo', dialect),
    },
    {
        requirement: 'zig',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\()[ ]*zig[ ]'`,
        describes: 'the Zig toolchain invoked as a command',
        match: (body, dialect) => matchCommands(body, 'zig', dialect),
    },
    {
        requirement: 'node',
        kind: 'invoke',
        predicate: String.raw`$FILES | xargs grep -coE '(^|[|;&(\`]|\$\(|run:[ ]*|cmd:[ ]*|-[ ]+)[ ]*(node|npm)[ ]'`,
        describes: 'Node.js or its npm package-manager frontend invoked as a command',
        match: (body, dialect) => matchCommands(body, 'node|npm', dialect),
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
        match: (body, dialect) => matchCommands(body, String.raw`python3?`, dialect),
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
        match: (body, dialect) => matchCommands(body, 'task', dialect),
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
            ...(matchCommands(body, String.raw`xcrun|xcodebuild|pkg-config`, dialect)),
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
/*
 * Comments removed with the shell's own quoting rules, which a line-oriented
 * pattern cannot have: a `#` inside a string is a character, and cutting there
 * leaves an unterminated quote for everything downstream to trip over. The
 * ranges come from the tokeniser rather than a second scanner, so there is one
 * implementation of what a quote is.
 */
export function stripShellComments(body) {
    const ranges = []
    shellTokens(body, ranges)
    if (ranges.length === 0) return body
    let out = ''
    let at = 0
    for (const [from, to] of ranges) {
        out += body.slice(at, from)
        at = to
    }
    return out + body.slice(at)
}

export function withoutComments(path, body) {
    if (path.endsWith('.mjs') || path.endsWith('.js')) {
        return body
            .replace(/\/\*[^]*?\*\//g, ' ')
            .replace(/^\s*\/\/.*$/gm, ' ')
    }
    /* YAML has no shell quoting, so its comments stay a line rule. */
    if (path.endsWith('.yml') || path.endsWith('.yaml')) {
        return body.replace(/(^|\s)#.*$/gm, '$1')
    }
    return stripShellComments(body)
}

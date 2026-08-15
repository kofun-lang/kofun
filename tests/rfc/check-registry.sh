#!/bin/sh
# RFC ledger validation plus the accepted RFC-0013/A01 amendment truth gate.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
VALIDATOR="$ROOT/tests/rfc/validate-registry.mjs"
GENERATOR="$ROOT/tests/rfc/make-invalid.mjs"
mkdir -p "$ROOT/build/tmp"
WORK=$(mktemp -d "$ROOT/build/tmp/rfc-ledger.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

if test "$#" -gt 0; then
    printf '%s\n' "rfc-ledger: unexpected argument: $1" >&2
    printf '%s\n' 'rfc-ledger: usage: sh tests/rfc/check-registry.sh' >&2
    exit 2
fi

node --check "$VALIDATOR"
node --check "$GENERATOR"
node "$VALIDATOR" schema
node "$VALIDATOR" validate

# #1446. The corpus is run a second time with today set well past every fixture
# date. `proposed-claiming-a-decision-date` carried a literal `2026-08-15`,
# chosen as "the future" when it was written; on that morning it stopped being
# the future, the rule it relied on stopped firing, and the mutation was
# accepted. Nothing failed because the ledger changed — the calendar moved.
#
# One run cannot catch that: a fixture that expires tomorrow passes today. So
# the axis itself is exercised, and a date that expires is caught the day it is
# written rather than the day it expires.
for horizon in 2027-01-01 3000-01-01; do
    KOFUN_RFC_TODAY="$horizon" node "$VALIDATOR" validate >/dev/null 2>&1 || {
        printf '%s\n' "FAIL: rfc ledger: the ledger itself is invalid at today=$horizon" >&2
        exit 1
    }
done

mutations=0
node "$GENERATOR" list > "$WORK/mutations.tsv"
while IFS='	' read -r mutation blame; do
    test -n "$mutation" || continue
    mutations=$((mutations + 1))
    node "$GENERATOR" "$mutation" "$WORK/$mutation.json"
    if node "$VALIDATOR" validate "$WORK/$mutation.json" \
        > "$WORK/$mutation.out" 2> "$WORK/$mutation.err"
    then
        printf '%s\n' "FAIL: rfc ledger: accepted generic mutation $mutation" >&2
        exit 1
    fi
    grep -qF -- "$blame" "$WORK/$mutation.err" || {
        printf '%s\n' "FAIL: rfc ledger: $mutation did not name $blame" >&2
        cat "$WORK/$mutation.err" >&2
        exit 1
    }
    grep -q 'Repair: ' "$WORK/$mutation.err" || {
        printf '%s\n' "FAIL: rfc ledger: $mutation has no repair" >&2
        exit 1
    }
done < "$WORK/mutations.tsv"
for horizon in 2027-01-01 3000-01-01; do
    while IFS='	' read -r mutation blame; do
        test -n "$mutation" || continue
        KOFUN_RFC_TODAY="$horizon" node "$GENERATOR" "$mutation" "$WORK/$mutation.$horizon.json"
        if KOFUN_RFC_TODAY="$horizon" node "$VALIDATOR" validate \
            "$WORK/$mutation.$horizon.json" >/dev/null 2>&1
        then
            printf '%s\n' \
                "FAIL: rfc ledger: $mutation is accepted at today=$horizon; its fixture date expires" >&2
            exit 1
        fi
    done < "$WORK/mutations.tsv"
done

test "$mutations" -eq 23 || {
    printf '%s\n' "FAIL: rfc ledger: expected 23 generic mutations, ran $mutations" >&2
    exit 1
}

# Reproduce the one-commit Actions checkout, and separately prove that a
# missing historical object is never skipped in an ordinary non-shallow repo.
SHALLOW="$WORK/shallow"
git clone -q --depth=1 --no-checkout "file://$ROOT" "$SHALLOW"
NONSHALLOW="$WORK/nonshallow"
git init -q "$NONSHALLOW"
git -C "$NONSHALLOW" config user.name rfc-ledger-selftest
git -C "$NONSHALLOW" config user.email rfc-ledger-selftest@example.invalid
git -C "$NONSHALLOW" commit -q --allow-empty -m root

node - "$ROOT" "$SHALLOW" "$NONSHALLOW" <<'NODE'
const { readFileSync } = require('node:fs')
const { createHash } = require('node:crypto')
const { spawnSync } = require('node:child_process')

const [root, shallowRoot, nonshallowRoot] = process.argv.slice(2)
const rfc = readFileSync(`${root}/rfcs/0013-int-bit-operations.md`, 'utf8')
const ledger = JSON.parse(readFileSync(`${root}/rfcs/index.json`, 'utf8'))
const base = '80f79798361c9513a637c521ec03d718d3842dfc'
const deltaHash = 'bf745aee7dcbb0baf57901e182adf6334ad82de01d8757ea8a35a9d9d3290e7c'
const announcement =
    '> **Amended: `RFC-0013/A01` (2026-08-12).** The accepted text below is\n' +
    '> preserved as written. It is no longer the complete current contract for\n' +
    '> semantics, diagnostics, compatibility evidence, or identity provenance;\n' +
    '> the ledger amendment is authoritative for those changes.\n'
const query = String.raw`base=80f79798361c9513a637c521ec03d718d3842dfc; git ls-tree -r --name-only "$base" | grep -c '\.kofun$'; git grep -lE '^[[:space:]]*fn (and|or|xor|not|shl|shr|rotr|wrapping_add)\(' "$base" -- '*.kofun' | wc -l; git grep -lE '\.(and|or|xor|not|shl|shr|rotr|wrapping_add)\(' "$base" -- '*.kofun' | wc -l; git grep -nEi 'sha.?256|0x428a2f98|0x71374491|1116352408|1899447441' "$base" -- '*.kofun' | wc -l; git grep -lE '0x428a2f98|0x71374491|1116352408|1899447441' "$base" -- '*.kofun' | wc -l`
const result =
    `At base ${base}: 1114 tracked .kofun files; 0 declaration files; ` +
    '0 call files; 11 bounded SHA-256 text rows; 0 first-round-constant ' +
    'files. The 11 rows are one native-fixture comment, two Stage 2 help ' +
    'lines, seven observations_sha256 stored-text accessors, and one ' +
    'usability comment—not a tracked Kofun SHA-256 round implementation.'
const compatibilityStatement =
    'No tracked program at the base declares/calls these unimplemented ' +
    'methods. A01 changes no accepted program; it closes future semantics, ' +
    'diagnostics, evidence and provenance before implementation.'

function hash(text) {
    return createHash('sha256').update(text).digest('hex')
}
function clone(value) {
    return structuredClone(value)
}
function replaceOnce(text, needle, replacement) {
    if (!text.includes(needle)) throw new Error(`stale mutation needle: ${needle}`)
    return text.replace(needle, replacement)
}
function runGit(cwd, args, allowNoMatch = false) {
    const out = spawnSync('git', args, {
        cwd, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
    })
    if (out.status !== 0 && !(allowNoMatch && out.status === 1)) {
        throw new Error(`git ${args.join(' ')} failed: ${out.stderr || out.status}`)
    }
    return out.stdout
}
function lines(text) {
    const value = text.trim()
    return value === '' ? [] : value.split('\n')
}

function verify(rfcText, ledgerValue, auditRoot = '') {
    const errors = []
    const notes = []
    const exact = (actual, expected, label) => {
        if (actual !== expected) errors.push(`${label} changed`)
    }
    const marker = '- Status: accepted\n\n' + announcement + '\n## Summary'
    if (!rfcText.includes(marker)) errors.push('amendment announcement is missing')
    const restored = rfcText.replace('\n' + announcement + '\n', '\n')
    exact(
        hash(restored),
        'ad9339cdd5ee3db38c66762476bd98285fb620f0faa05ff6849259e257048388',
        'accepted RFC original bytes'
    )
    const through = (start, ending) => {
        const first = restored.indexOf(start)
        const last = restored.indexOf(ending, first)
        if (first < 0 || last < 0) {
            errors.push(`accepted RFC original-semantics anchor ${start} is missing`)
            return ''
        }
        return restored.slice(first, last + ending.length)
    }
    const section = (start, end) => {
        const first = restored.indexOf(start)
        const last = restored.indexOf(end, first)
        if (first < 0 || last < 0) {
            errors.push(`accepted RFC original-semantics anchor ${start} is missing`)
            return ''
        }
        return restored.slice(first, last).trimEnd()
    }
    const originalSemantics = [
        through('Kofun cannot compute a digest', 'code.'),
        through("The language's entire operator set", '(`spec/grammar.ebnf:121-124`).'),
        through('Not one of the', 'because none can.'),
        through('Every identity the compiler assigns', 'until this exists.'),
        through('**`shl` traps on overflow.**', 'exactly as `a * 2**n` does today.'),
        section('**`width` is `1..64`.**', '\n**No effects'),
        through(
            'Two runtime codes and no new compile-time family:',
            '- `R011`, new, covers a shift count outside `0..63` and a width outside `1..64`.'
        ),
        through('A non-`Int` receiver', 'no new code is required for it.'),
        through('- **result**: `1105`', 'nothing acquires new behaviour.'),
        section('**Whether `shl` should trap or wrap.**', '\n**Whether `width` belongs'),
    ].join('\n\n')

    const entry = ledgerValue.rfcs.find((candidate) => candidate.id === 'RFC-0013')
    if (entry === undefined) {
        errors.push('RFC-0013 ledger entry is missing')
        return { errors, notes }
    }
    const originalEntry = clone(entry)
    delete originalEntry.amendments
    exact(
        hash(JSON.stringify(originalEntry)),
        '29fefcdbb9d067ce32ffd3624091a01823cbddf8640f241fc29941ec03e5df74',
        'accepted RFC-0013 ledger row'
    )
    const matches = (entry.amendments ?? []).filter(({ id }) => id === 'A01')
    if (matches.length !== 1) {
        errors.push('RFC-0013/A01 ledger row is missing')
        return { errors, notes }
    }
    const amendment = matches[0]
    exact(amendment.recorded_on, '2026-08-12', 'A01 recorded_on')
    exact(amendment.change, 'https://github.com/kofun-lang/kofun/issues/1350', 'A01 change authority')
    exact(amendment.original_semantics, originalSemantics, 'A01 verbatim original_semantics')
    exact(hash(amendment.delta ?? ''), deltaHash, 'A01 exact delta digest')
    exact(amendment.compatibility?.category, 'additive', 'A01 compatibility category')
    exact(amendment.compatibility?.statement, compatibilityStatement, 'A01 compatibility statement')
    exact(amendment.compatibility?.corpus_query, query, 'A01 current-base corpus query')
    exact(amendment.compatibility?.result, result, 'A01 compatibility result')
    exact(amendment.compatibility?.evidence, 'tests/rfc/check-registry.sh', 'A01 compatibility evidence')

    if (auditRoot === '') return { errors, notes }
    const repository = spawnSync('git', ['rev-parse', '--git-dir'], {
        cwd: auditRoot, encoding: 'utf8',
    })
    if (repository.status !== 0) {
        errors.push(`current-base audit root is not a Git repository: ${auditRoot}`)
        return { errors, notes }
    }
    const hasBase = spawnSync('git', ['cat-file', '-e', `${base}^{commit}`], {
        cwd: auditRoot, encoding: 'utf8',
    })
    if (hasBase.status !== 0) {
        const shallow = spawnSync('git', ['rev-parse', '--is-shallow-repository'], {
            cwd: auditRoot, encoding: 'utf8',
        })
        if (shallow.status === 0 && shallow.stdout.trim() === 'true') {
            notes.push(`historical base ${base} unavailable in shallow checkout; corpus recomputation SKIP`)
        } else {
            errors.push(`historical-base-unavailable-in-non-shallow: ${base}`)
        }
        return { errors, notes }
    }
    const tracked = lines(runGit(auditRoot, ['ls-tree', '-r', '--name-only', base]))
        .filter((path) => path.endsWith('.kofun')).length
    const declarations = lines(runGit(auditRoot, [
        'grep', '-lE',
        '^[[:space:]]*fn (and|or|xor|not|shl|shr|rotr|wrapping_add)\\(',
        base, '--', '*.kofun',
    ], true)).length
    const calls = lines(runGit(auditRoot, [
        'grep', '-lE', '\\.(and|or|xor|not|shl|shr|rotr|wrapping_add)\\(',
        base, '--', '*.kofun',
    ], true)).length
    const shaRows = runGit(auditRoot, [
        'grep', '-nEi',
        'sha.?256|0x428a2f98|0x71374491|1116352408|1899447441',
        base, '--', '*.kofun',
    ], true)
    const constantFiles = lines(runGit(auditRoot, [
        'grep', '-lE', '0x428a2f98|0x71374491|1116352408|1899447441',
        base, '--', '*.kofun',
    ], true)).length
    if (`${tracked}/${declarations}/${calls}` !== '1114/0/0') {
        errors.push(`current-base corpus is ${tracked}/${declarations}/${calls}, expected 1114/0/0`)
    }
    if (lines(shaRows).length !== 11 ||
        hash(shaRows) !== '4370aa07437947106ee9581ac8b9207c753a041c6c294756125541a2ff2ff420') {
        errors.push('SHA-256 textual match set changed')
    }
    if (constantFiles !== 0) errors.push('SHA-256 first-round constant anchor returned')
    return { errors, notes }
}

function assertPass(label, rfcText, ledgerValue, auditRoot = '') {
    const outcome = verify(rfcText, ledgerValue, auditRoot)
    if (outcome.errors.length > 0) {
        throw new Error(`${label} failed: ${outcome.errors.join('; ')}`)
    }
    return outcome
}
function assertRefusal(label, mutate, blame, auditRoot = '') {
    const candidate = { rfc, ledger: clone(ledger) }
    mutate(candidate)
    const outcome = verify(candidate.rfc, candidate.ledger, auditRoot)
    if (outcome.errors.length === 0) throw new Error(`${label} mutation was accepted`)
    if (!outcome.errors.some((error) => error.includes(blame))) {
        throw new Error(`${label} refusal did not name ${blame}: ${outcome.errors.join('; ')}`)
    }
}
function amendmentOf(candidate) {
    return candidate.ledger.rfcs.find(({ id }) => id === 'RFC-0013')
        .amendments.find(({ id }) => id === 'A01')
}
function mutateField(field, needle, replacement) {
    return (candidate) => {
        let owner = amendmentOf(candidate)
        const path = field.split('.')
        for (const key of path.slice(0, -1)) owner = owner[key]
        const key = path.at(-1)
        owner[key] = replaceOnce(owner[key], needle, replacement)
    }
}

const honest = assertPass('honest RFC-0013/A01', rfc, ledger, root)
for (const note of honest.notes) process.stdout.write(`SKIP: ${note}\n`)
const shallow = assertPass('shallow RFC-0013/A01', rfc, ledger, shallowRoot)
if (shallow.notes.length !== 1 || !shallow.notes[0].includes('corpus recomputation SKIP')) {
    throw new Error('shallow checkout did not report the historical-base SKIP')
}
const nonshallow = verify(rfc, ledger, nonshallowRoot)
if (!nonshallow.errors.some((error) =>
    error.includes('historical-base-unavailable-in-non-shallow'))) {
    throw new Error(`non-shallow missing-base refusal failed: ${nonshallow.errors}`)
}

const mutations = [
    ['missing-announcement', (c) => {
        c.rfc = replaceOnce(c.rfc, '\n' + announcement + '\n', '\n')
    }, 'amendment announcement is missing'],
    ['missing-row', (c) => {
        const entry = c.ledger.rfcs.find(({ id }) => id === 'RFC-0013')
        entry.amendments = entry.amendments.filter(({ id }) => id !== 'A01')
    }, 'RFC-0013/A01 ledger row is missing'],
    ['shl-contradiction', mutateField('delta',
        'checked; only future `wrapping_shl` may wrap',
        'trap versus wrap remains unresolved'), 'A01 exact delta digest'],
    ['stale-census', (c) => {
        const a = amendmentOf(c)
        a.compatibility.corpus_query = replaceOnce(a.compatibility.corpus_query, base, 'ffa3d8a7')
        a.compatibility.result = replaceOnce(a.compatibility.result, '1114', '1105')
        a.compatibility.result = replaceOnce(a.compatibility.result, base, 'ffa3d8a7')
    }, 'A01 current-base corpus query'],
    ['preimage-inversion', mutateField('delta',
        'IDs=digest outputs over framed preimages',
        'IDs are framed preimages, not digest outputs'), 'A01 exact delta digest'],
    ['provenance-collapse', mutateField('delta',
        '`bin/kofun-digest`: C-backed generic digest CLI for repo checksums, reference/gate preimages; not universal production compiler identity',
        '`bin/kofun-digest` is the universal identity command'), 'A01 exact delta digest'],
    ['missing-label', mutateField('delta',
        'takes positional arguments; the bit operations have no parameter names',
        'rejects labelled arguments'), 'A01 exact delta digest'],
    ['missing-member', mutateField('delta',
        'unknown \\`Int\\` member \\`<name>\\`', 'unknown member'), 'A01 exact delta digest'],
    ['argument-order', mutateField('delta',
        'bind/check its label, then type-check it',
        'type-check it before binding its label'), 'A01 exact delta digest'],
    ['rotation-rejection', mutateField('delta',
        'then n mod w', 'then rejects n>=w'), 'A01 exact delta digest'],
    ['sha-query', mutateField('compatibility.corpus_query',
        '0x428a2f98', '0x428a2f99'), 'A01 current-base corpus query'],
    ['sha-count', mutateField('compatibility.result',
        '11 bounded SHA-256 text rows',
        '10 bounded SHA-256 text rows'), 'A01 compatibility result'],
    ['original-semantics', mutateField('original_semantics',
        'Kofun cannot compute a digest',
        'Kofun once could not compute a digest'), 'A01 verbatim original_semantics'],
]
if (mutations.length !== 13) throw new Error(`expected 13 A01 mutations, got ${mutations.length}`)
for (const [label, mutate, blame] of mutations) {
    assertRefusal(label, mutate, blame)
    if (label === 'sha-query' || label === 'sha-count') {
        assertRefusal(`shallow-${label}`, mutate, blame, shallowRoot)
    }
}
process.stdout.write(
    `PASS: RFC-0013/A01 preserves accepted bytes, pins exact semantics and base evidence, and ${mutations.length} amendment mutations are refused\n`
)
NODE

printf '%s\n' \
    "PASS: the RFC ledger separates acceptance from implementation, and $mutations generic mutations are refused"

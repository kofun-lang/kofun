// The rules docs/ISSUE_READINESS.md states, asserted against the committed
// snapshot. Every failure names the issue and both values, because "the
// backlog is inconsistent" is not something anyone can act on.

import { readFileSync } from 'node:fs'

import { CLAIM_STATUSES, STATE_LABELS, latestLiveClaimAgents } from './extract.mjs'

const [snapshotPath, debtPath] = process.argv.slice(2)
if (!snapshotPath || !debtPath) {
    throw new Error('usage: check.mjs SNAPSHOT DEBT')
}

const snapshot = JSON.parse(readFileSync(snapshotPath, 'utf8'))
const failures = []

if (snapshot.schema !== 'kofun.backlog-issue-state/v1') {
    failures.push(`snapshot schema is ${snapshot.schema}, not kofun.backlog-issue-state/v1`)
}

// The vocabulary is carried twice — here as the repository's definition, and in
// the snapshot as the one its writer used. Reading only the snapshot's copy
// would let a stale or hand-edited file widen the vocabulary and then satisfy
// every rule below against its own wider version.
const vocabulary = new Set(STATE_LABELS)
const declared = snapshot.state_labels ?? []
const unexpected = declared.filter((name) => !vocabulary.has(name))
const missing = STATE_LABELS.filter((name) => !declared.includes(name))
if (unexpected.length > 0 || missing.length > 0) {
    failures.push(
        `snapshot declares a different state vocabulary than tests/backlog/extract.mjs` +
            `${unexpected.length > 0 ? `; it adds ${unexpected.join(', ')}` : ''}` +
            `${missing.length > 0 ? `; it omits ${missing.join(', ')}` : ''}` +
            '; regenerate it with tests/backlog/refresh.mjs',
    )
}

const issues = snapshot.issues ?? []

// An empty set satisfies every rule below without checking anything, which is
// how this class of drift stays invisible in the first place. Refuse rather
// than report a vacuous pass.
if (issues.length === 0) {
    failures.push('snapshot holds no open issues; the gate would pass without checking anything')
}
const openIssueCount = issues.filter(
    (issue) => (issue.issue_state ?? 'open') !== 'closed',
).length
if (openIssueCount !== snapshot.open_issues) {
    failures.push(`snapshot says ${snapshot.open_issues} open issues but carries ${openIssueCount}`)
}

const open = new Set(
    issues.filter((issue) => (issue.issue_state ?? 'open') !== 'closed').map((issue) => issue.number),
)
const byNumber = new Map(issues.map((issue) => [issue.number, issue]))

// Recorded debt. Both directions matter: an unlisted problem is new drift, and
// a listed row that no longer applies is a win that was not recorded.
//
// One ledger, two readers. `unverifiable-stamp` needs the git history, so
// tests/backlog/check-stamps.mjs owns it and this reader must not report those
// rows as unused. A kind neither reader claims is a typo that would otherwise
// sit in the file excusing nothing.
const OWNED_KINDS = new Set([
    'state-disagreement',
    'unstamped-ready',
    'closed-blockers',
    'unreadable-state',
    'stateless-tracker',
    'unnamed-blocker',
    'capability-blocker',
    'unclaimed-progress',
    'stale-ready-claim',
    'inert-claim',
])
const KNOWN_KINDS = new Set([...OWNED_KINDS, 'unverifiable-stamp'])

const debt = new Map()
for (const raw of readFileSync(debtPath, 'utf8').split('\n')) {
    const line = raw.trim()
    if (line === '' || line.startsWith('#')) continue
    const [kind, number, detail] = raw.split('\t')
    if (!KNOWN_KINDS.has(kind)) {
        failures.push(`debt row for #${Number(number)} has unknown kind \`${kind}\``)
        continue
    }
    if (!OWNED_KINDS.has(kind)) continue
    const key = `${kind}:${Number(number)}`
    // A duplicate row is a badly edited file, and storing it by key would
    // silently keep the last one — so the ledger would report a smaller count
    // than it holds and a stale copy could outlive the row that replaced it.
    if (debt.has(key)) {
        failures.push(`debt lists #${Number(number)} as ${kind} more than once`)
        continue
    }
    debt.set(key, { kind, number: Number(number), detail })
}
const usedDebt = new Set()

function owedDebt(kind, number, detail) {
    const key = `${kind}:${number}`
    const row = debt.get(key)
    if (row === undefined) return false
    usedDebt.add(key)
    if (row.detail !== detail) {
        failures.push(
            `#${number} is recorded as ${kind} ${row.detail} but is now ${detail}; ` +
                'update tests/backlog/debt.tsv so the row still describes the issue',
        )
    }
    return true
}

let agreeing = 0
let blockedWithNamedBlockers = 0
let unnamedBlockers = 0
let capabilityBlockers = 0
let stamped = 0
let readyCount = 0
let stated = 0
let unreadableState = 0
let statelessTrackers = 0
let claims = 0
let liveClaims = 0
let inProgressCount = 0
let claimedProgress = 0
let unclaimedProgress = 0
let staleReadyClaims = 0
let inertClaims = 0

const claimVocabulary = new Set(CLAIM_STATUSES)

for (const issue of issues) {
    const where = `#${issue.number}`

    // Claims are append-only events. Validate every event, then let the latest
    // valid event for one agent decide whether that agent still owns the issue.
    for (const claim of issue.claims ?? []) {
        claims += 1
        if (claim.agent_id === null || claim.agent_id === undefined || claim.agent_id === '') {
            failures.push(`${where} has an agent-claim:v1 without exactly one \`agent_id\``)
            continue
        }
        if (claim.status === null || claim.status === undefined || claim.status === '') {
            failures.push(`${where} claim for \`${claim.agent_id}\` has no single \`status\``)
            continue
        }
        if (!claimVocabulary.has(claim.status)) {
            failures.push(
                `${where} claim for \`${claim.agent_id}\` has status \`${claim.status}\`, ` +
                    `not one of ${CLAIM_STATUSES.join(', ')}`,
            )
            continue
        }
    }
    const liveAgents = latestLiveClaimAgents(issue.claims)
    liveClaims += liveAgents.length
    if (liveAgents.length > 1) {
        failures.push(`${where} has ${liveAgents.length} live claims: ${liveAgents.join(', ')}`)
    }
    if ((issue.issue_state ?? 'open') === 'closed' && liveAgents.length > 0) {
        failures.push(`${where} is closed but still has live claims: ${liveAgents.join(', ')}`)
    }
    // An inert claim is a claim its author believes they published. The
    // extractor records the ones whose first non-blank line is the marker and
    // which parse to nothing — that combination cannot be a comment about
    // claiming, only a failed claim. It is checked before the closed-issue
    // `continue` because a closed issue's inert claim misled someone too.
    for (const marker of issue.inert_claims ?? []) {
        if (owedDebt('inert-claim', issue.number, marker)) {
            inertClaims += 1
            continue
        }
        failures.push(
            `${where} has a comment beginning \`${marker}\` that parses to no claim, ` +
                'so its author published nothing the gate can read; rewrite it in the ' +
                'canonical `### agent-claim:v1` form with `- ` keys as ' +
                'docs/ISSUE_READINESS.md defines, or record it in ' +
                'tests/backlog/debt.tsv as `inert-claim`',
        )
    }

    if ((issue.issue_state ?? 'open') === 'closed') continue

    // 1. At most one state. Two state labels is not a stricter claim, it is an
    //    unreadable one.
    if (issue.state_labels.length > 1) {
        failures.push(`${where} carries ${issue.state_labels.length} state labels: ${issue.state_labels.join(', ')}`)
        continue
    }

    const label = issue.state_labels[0] ?? null
    const line = issue.state_line ?? null

    // 2. A State line names a state. The label side cannot go wrong — the
    //    extraction only keeps labels drawn from the vocabulary — but the line
    //    is free text, so an issue can invent a word. Rule 3 below never sees
    //    it: an invented word on an issue with no label has nothing to
    //    disagree with, so the gate reported agreement it had not checked.
    //    #998 carried `State: planning` this way.
    if (line !== null && !vocabulary.has(line)) {
        failures.push(
            `${where} has \`State: ${line}\`, which is not one of ${STATE_LABELS.join(', ')}; ` +
                'use a state docs/ISSUE_READINESS.md defines, or widen the vocabulary there first',
        )
        continue
    }
    if (line !== null) stated += 1

    // 2b. Coverage. Every rule below rule 2 is keyed on the State line, so an
    //     issue whose body has none is skipped by all of them — silently, and
    //     without reducing the count the gate reports. `PASS: 51 State lines
    //     name a state` read as complete while it was 51 of 71, and the 20 it
    //     never reached included #955, whose label says `blocked` while its
    //     body says `State: in-progress.` — a disagreement rule 3 exists to
    //     catch and structurally could not see, because an unprefixed line
    //     extracts as null and rule 3 needs two values to compare.
    //
    //     So an unreadable state is now a failure like any other, with the two
    //     ledger kinds separating the two things it can mean. `unreadable-state`
    //     is drift with a fix — write the `- State:` line — and its detail is
    //     the label that supplies the answer, so relabelling the issue makes
    //     the row fail rather than quietly excuse a different state.
    //     `stateless-tracker` is a deliberate exemption for an issue that
    //     carries no state by design; recording it separately is what keeps it
    //     from being indistinguishable from drift.
    if (line === null) {
        const label = issue.state_labels[0] ?? '-'
        if (owedDebt('stateless-tracker', issue.number, label)) {
            statelessTrackers += 1
        } else if (owedDebt('unreadable-state', issue.number, label)) {
            unreadableState += 1
        } else {
            failures.push(
                `${where} carries no \`State:\` line the gate can read, so every rule keyed on it ` +
                    'skips this issue; add `- State: <state>` to its body, or record it in ' +
                    'tests/backlog/debt.tsv as `unreadable-state` or `stateless-tracker`',
            )
            continue
        }
    }

    // 3. Label and body agree when both are present.
    //
    //    This used to add "an issue with neither is untriaged, which is a
    //    different problem and not this gate's". That carve-out is gone: rule
    //    2b refuses an unreadable state before this point, so an issue with
    //    neither a label nor a line now fails there unless it is recorded as
    //    `stateless-tracker`. The sentence stayed behind and described a
    //    branch that could no longer be reached, which is the kind of comment
    //    this file is otherwise careful not to leave.
    if (label !== null && line !== null) {
        if (label === line) {
            agreeing += 1
        } else if (!owedDebt('state-disagreement', issue.number, `${label}/${line}`)) {
            failures.push(`${where} label says \`${label}\` and its State line says \`${line}\``)
            continue
        }
    }

    // 4. The mirror of a ready issue naming an open blocker: a blocked issue
    //    whose nonempty dependency list is entirely closed is advertised as
    //    unstartable after its own stated reason has disappeared.
    if (label === 'blocked' && issue.blocked_by.length > 0) {
        blockedWithNamedBlockers += 1
        const openBlockers = issue.blocked_by.filter((number) => open.has(number))
        if (openBlockers.length === 0) {
            const detail = issue.blocked_by.map((number) => `#${number}`).join(', ')
            if (!owedDebt('closed-blockers', issue.number, detail)) {
                failures.push(`${where} is blocked but all named blockers are closed: ${detail}`)
            }
        }
    }

    // 4b. Coverage for rule 4. `blockedBy()` needs a `Blocked by:` line; a
    //     blocker stated in prose yields `blocked_by: []`, so rule 4 skips the
    //     issue silently and its count reads as a total when it is a sample.
    //     Measured 2026-08-07: 4 of 28 blocked issues were reached, and the
    //     24 it missed included #314, whose own body says `Unblock condition:
    //     **fulfilled.**` and cites the green run, while still labelled
    //     `blocked`. That is work sitting idle behind a sentence no rule reads.
    //
    //     So an unreachable blocker is now a failure, with two kinds
    //     separating the two things it means. `unnamed-blocker` is drift with
    //     a fix — write `Blocked by: #N` — and the row retires itself, because
    //     an issue that gains the line stops reaching this branch and its row
    //     then fails as unused. `capability-blocker` is an exemption for an
    //     issue blocked on something no issue number can express: #26 waits on
    //     an unowned WASI capability profile and #570 on a Stage 2 parse
    //     capability. Both are honest and current, and both are permanently
    //     invisible to a rule that only understands issue numbers. Recording
    //     them separately is what keeps an exemption from reading as drift.
    if (label === 'blocked' && issue.blocked_by.length === 0) {
        if (owedDebt('capability-blocker', issue.number, '-')) {
            capabilityBlockers += 1
        } else if (owedDebt('unnamed-blocker', issue.number, '-')) {
            unnamedBlockers += 1
        } else {
            failures.push(
                `${where} is blocked but names no blocker where the gate reads one, so the ` +
                    'closed-blocker rule skips it; add a `Blocked by: #N` line to its body, or ' +
                    'record it in tests/backlog/debt.tsv as `unnamed-blocker` or ' +
                    '`capability-blocker`',
            )
        }
    }

    // 6b. `in-progress` asserts that someone is working on the issue right
    //     now. The claim protocol exists so a second agent can see that before
    //     starting, and both rules above are quantified over the claims that
    //     exist — so with none anywhere they pass without checking anything.
    //     Measured 2026-08-07: `PASS: 0 live claims` across all 70 open
    //     issues, while four of them had an open pull request implementing
    //     them. The protocol was gated, documented, and unused.
    //
    //     `in-progress` is the one ownership assertion this offline snapshot
    //     can check, so it is the one the gate enforces: an issue that says
    //     work is underway and carries no live claim is an assertion nobody
    //     signed. `unclaimed-progress` records the ones being corrected.
    //
    //     Note what this cannot see. An inert claim — a wrapped HTML comment,
    //     or the marker followed by prose keys — extracts as nothing, so it is
    //     indistinguishable here from never having claimed. That is the worse
    //     failure of the two, because its author believes the signal is
    //     published. docs/ISSUE_READINESS.md names the canonical form.
    if (label === 'in-progress') {
        inProgressCount += 1
        if (liveAgents.length > 0) {
            claimedProgress += 1
        } else if (owedDebt('unclaimed-progress', issue.number, '-')) {
            unclaimedProgress += 1
        } else {
            failures.push(
                `${where} is in-progress with no live claim, so nothing records who owns it; ` +
                    'post a `### agent-claim:v1` comment in the canonical form ' +
                    'docs/ISSUE_READINESS.md defines, or record it in tests/backlog/debt.tsv ' +
                    'as `unclaimed-progress`',
            )
        }
    }

    // 5b. `ready` and owned is a contradiction the rules above cannot see.
    //     The claim rules walk `in-progress` and `closed`; the ready rules read
    //     blockers and stamps and never look at claims. So an issue advertised
    //     as free while an agent still holds it passes everything.
    //
    //     Measured on #1315 (2026-08-15): released to `ready` because it gates
    //     fourteen dependents, while an earlier canonical `active` block stayed
    //     live because the release comment was written in a form the extractor
    //     does not read. Nothing failed. Its mirror — `in-progress` with no
    //     claim — failed within the minute, and the louder of the two was
    //     already the one being caught.
    if (label === 'ready' && liveAgents.length > 0) {
        if (owedDebt('stale-ready-claim', issue.number, liveAgents.join(', '))) {
            staleReadyClaims += 1
        } else {
            failures.push(
                `${where} is ready but ${liveAgents.join(', ')} still holds a live claim, ` +
                    'so it is advertised as free and owned at the same time; post a claim ' +
                    'with status `released` or `merged`, or record it in ' +
                    'tests/backlog/debt.tsv as `stale-ready-claim`',
            )
        }
    }

    if (label !== 'ready') continue
    readyCount += 1

    // 5. A `ready` issue naming an open blocker is advertised as startable
    //    while its own body says it is not. This one has no debt escape: it is
    //    the drift that costs a contributor their afternoon.
    const openBlockers = issue.blocked_by.filter((number) => open.has(number))
    if (openBlockers.length > 0) {
        const detail = openBlockers
            .map((number) => `#${number} (${byNumber.get(number)?.state_labels[0] ?? 'no state label'})`)
            .join(', ')
        failures.push(`${where} is ready but names open blockers: ${detail}`)
    }

    // 6. Definition of Ready rule 2: a current-behavior claim names the commit
    //    it was measured on. Without a stamp nobody can tell whether the
    //    premise still holds without re-deriving it, so nobody does.
    if (issue.evidence_commits.length === 0) {
        if (!owedDebt('unstamped-ready', issue.number, '-')) {
            failures.push(
                `${where} is ready with no evidence stamp; measure its current behavior and name the ` +
                    'commit, or record it in tests/backlog/debt.tsv',
            )
        }
    } else {
        stamped += 1
    }
}

// A debt row nobody reached is either fixed or stale. Both mean the row must
// go, and leaving it would let a future issue inherit the exemption unseen.
for (const [key, row] of debt) {
    if (usedDebt.has(key)) continue
    const issue = byNumber.get(row.number)
    if (issue === undefined) {
        failures.push(`debt names #${row.number} (${row.kind}), which is not an open issue; remove its row`)
    } else {
        failures.push(
            `debt names #${row.number} as ${row.kind}, which no longer applies; ` +
                'remove its row so the improvement is recorded',
        )
    }
}

if (failures.length > 0) {
    for (const failure of failures) process.stderr.write(`FAIL: backlog: ${failure}\n`)
    process.exit(1)
}

process.stdout.write(
    `PASS: ${claims} canonical claim events use the closed status vocabulary\n` +
        `PASS: ${liveClaims} live claims are unique per open issue and absent from closed issues\n` +
        `PASS: ${claimedProgress} of ${inProgressCount} in-progress issues carry a live claim; ${unclaimedProgress} recorded as unclaimed\n` +
        `PASS: ${stated} State lines name a state in the vocabulary\n` +
        `PASS: ${stated} of ${stated + unreadableState + statelessTrackers} open issues carry a State line the gate reads; ${unreadableState} recorded as unreadable, ${statelessTrackers} exempt by design\n` +
        `PASS: ${agreeing} issues agree between their state label and their State line\n` +
        `PASS: ${blockedWithNamedBlockers} blocked issues with named blockers still have an open blocker or recorded debt\n` +
        `PASS: ${blockedWithNamedBlockers} of ${blockedWithNamedBlockers + unnamedBlockers + capabilityBlockers} blocked issues name their blockers where the gate reads them; ${unnamedBlockers} recorded as unnamed, ${capabilityBlockers} exempt by design\n` +
        `PASS: no ready issue names an open blocker (${readyCount} ready)\n` +
        `PASS: ${stamped} ready issues carry an evidence stamp\n` +
        `PASS: ${debt.size} recorded debt rows all still describe the issue they name\n`,
)

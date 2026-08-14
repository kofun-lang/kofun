import { claimEvents, inertClaimComments } from './extract.mjs'

function equal(actual, expected, name) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        throw new Error(`${name}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`)
    }
}

equal(
    claimEvents([
        {
            body:
                '### agent-claim:v1\n' +
                '- agent_id: codex-one\n' +
                '- status: active\n' +
                '- baseline: abc123\n',
        },
        { body: '### agent-claim:v1\n- agent_id: codex-one\n- status: pr-open\n' },
    ]),
    [
        { agent_id: 'codex-one', status: 'active' },
        { agent_id: 'codex-one', status: 'pr-open' },
    ],
    'canonical claim extraction',
)

equal(
    claimEvents([
        { body: '<!--\n### agent-claim:v1\n- agent_id: hidden\n- status: active\n-->' },
        { body: '```markdown\n### agent-claim:v1\n- agent_id: example\n- status: active\n```' },
        { body: 'agent-claim:v1\nagent_id: legacy\nstatus: active' },
    ]),
    [],
    'noncanonical claims stay inert',
)

equal(
    claimEvents([
        { body: '### agent-claim:v1\n- agent_id: duplicate\n- agent_id: other\n- status: active' },
    ]),
    [{ agent_id: null, status: 'active' }],
    'duplicate load-bearing key',
)

// #1431. An inert claim is detectable even though it parses to nothing: its
// first non-blank line is the marker. The anchoring is the whole rule — without
// it this fires on every comment that discusses the format, which is how a rule
// gets disabled by the third person it annoys.
equal(
    inertClaimComments([
        { body: 'agent-claim:v1\n- agent_id: bare\n- status: active' },
        { body: '  ### agent-claim:v1  \nno keys at all' },
    ]),
    ['agent-claim:v1', '### agent-claim:v1'],
    'a comment that opens with the marker and parses to nothing is inert',
)

equal(
    inertClaimComments([
        { body: '### agent-claim:v1\n- agent_id: real\n- issue: 1\n- status: active' },
    ]),
    [],
    'a canonical claim is not inert',
)

equal(
    inertClaimComments([
        { body: 'The bare form is not a claim. Write `### agent-claim:v1` with `- ` keys.\n\nagent-claim:v1' },
        { body: 'Every claim I posted used the bare line:\n\n    agent-claim:v1\n    - agent_id: x' },
        { body: '```\nagent-claim:v1\n```\nis inert; the heading form is not.' },
    ]),
    [],
    'prose about the format is not an inert claim',
)

process.stdout.write('PASS: canonical claim comments extract once and legacy wrappers stay inert, and an inert claim is told from prose about one\n')

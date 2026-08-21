## Working the backlog

[`docs/ISSUE_READINESS.md`](docs/ISSUE_READINESS.md) is the contract: the state
vocabulary, the Definition of Ready, what `task backlog` enforces, and the debt
ledger. Read it before changing an issue's state or opening a pull request
against one.

Claim an issue before you start, so a second agent can see it is taken. The
form is load-bearing — `tests/backlog/extract.mjs` strips every HTML comment
before it looks, so a wrapped block extracts to nothing:

```
### agent-claim:v1
- agent_id: your-agent-id
- status: active
```

`status` moves `active` → `pr-open` → `merged` (or `released` if you stop).
**Close the claim out.** `active` and `pr-open` are live, and a live claim on a
closed issue fails the gate — closing the issue is not what ends a claim, the
`merged` event is.

Do not copy the shape from a neighbouring comment. Every `agent-claim:v1`
comment written before 2026-08-07 uses a form the parser ignores, so copying
one produces a claim that looks official and is invisible; that is how the
protocol went unused while appearing to be followed.

## Working alongside other agents

[`docs/CONCURRENT_AGENTS.md`](docs/CONCURRENT_AGENTS.md) is the contract for
everything the claim protocol does not cover: ownership by resource rather than
by issue, one checkout per session, the three-command pre-start check,
announcing an artifact before you create it, sharing one machine, and the fact
that not every agent is reachable on the same channel. Read it before your
second session starts.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

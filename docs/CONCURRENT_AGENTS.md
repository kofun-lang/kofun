# Working this repository with several agents at once

[`AGENTS.md`](../AGENTS.md) documents `agent-claim:v1`, and it works: it answers
*who owns this issue*. On 2026-08-20/21 five agent sessions worked this
repository concurrently and did not collide on a single issue.

**Every collision they did have was about something else**, and none of it was
written down. This document is what those two days cost, stated as rules.

| what happened | the rule it needed |
| --- | --- |
| Two sessions read and wrote each other's uncommitted tree for an hour | one checkout, one session |
| Two sessions edited `bootstrap/stage2/compiler.{kofun,c}` concurrently | ownership by resource, not by issue |
| [#1523](https://github.com/kofun-lang/kofun/issues/1523) was filed, claimed, and independently implemented inside an hour; the claim log was empty when the second agent looked | the pre-start check is three commands |
| The same claim was written twice — [#1564](https://github.com/kofun-lang/kofun/pull/1564) and [#1565](https://github.com/kofun-lang/kofun/pull/1565) — after one agent asked the other for wording | say which artifact you are about to create |
| Two sessions were independently told to cut a release; both were minutes from bumping `VERSION` | announce a release window |
| A `verify` was killed mid-run at load 48, and three gates have bounds no environment variable reaches | announce long runs, and know which gates are load-sensitive |
| A fifth session was working [#1535](https://github.com/kofun-lang/kofun/issues/1535) and could not be reached on the message channel at all | the protocol must survive a participant who is not on it |

Six of the seven were caught by somebody noticing in conversation. **That is not
a mechanism.** The seventh was not caught; it was discovered afterwards.

## Ownership is by resource, not by issue

A claim binds an agent to an *issue*. Two agents on different issues that touch
one file collide exactly as hard as two on one issue, and both claims stay
correct and live throughout.

**The canonical Stage 2 pair is one lock over four paths**, and they must move
together:

```
bootstrap/stage2/compiler.kofun
bootstrap/stage2/compiler.c
bootstrap/stage2/SHA256SUMS
trusted_seed_sha256 in bootstrap/manifest.json
```

Issues that change the pair carry a `## Serialization` section saying so. That
tells you the rule once you have found the issue; it cannot tell you the pair is
a lock *before* you pick one, and picking is when you need to know.

**Four more resources belong to no issue and any issue can trip them:**

| resource | what trips it | what you get |
| --- | --- | --- |
| `artifacts/release-evidence/index.json` | **any** `Taskfile.yml` edit, because it pins that file's digest | a separate CI job red in nine seconds, at a commit whose diff mentions nothing of the sort |
| `tests/pair-coverage/inputs.tsv` | any new tracked `*.kofun`, from any issue | `measure.sh` refuses in both directions |
| `tests/typed-sidecar/stage2-events.sh` | any new `.stdout`/`.stderr` refusal companion | two hard-coded census counts the script's own comment says are expected to move |
| `tooling/forbidden-requirements/census.tsv` | any new shell or Node file | `--count` regenerates the rows; classifying a new one is still yours |

`index.json` is the sharp one: it is a **digest map, and must be regenerated,
never merged**. Taking either side of a conflict — or hand-computing the digest
correctly — produces a file that matches neither tree, and `task release-claims`
then fails on a file that looks resolved. Run `task release-evidence` and commit
the result. The failure mode is invisible from the conflict itself, which is why
it is worth a line here: it cost one wasted `verify` before anyone worked it
out.

## One checkout, one session

`git switch`, `git stash`, and anything writing `build/` are global to a
checkout. Two sessions in one working tree are reading each other's uncommitted
work without either one intending it.

**Start in `git worktree add`, always, even when you are first.** Being first is
not a property you can check later, and the session that arrives second cannot
tell that the tree it is reading is somebody's work in progress.

## The pre-start check is three commands

```sh
gh issue view N --json comments      # the claim log
git ls-remote --heads origin         # a branch exists before a claim does
gh pr list --state open              # so does a PR
```

The claim log alone answers only for agents who claim *before* starting. #1523
was filed, claimed and independently implemented inside one hour by two agents
who both checked it.

**Read the last `agent-claim:v1` block per `agent_id`, not the first.**
[`docs/ISSUE_READINESS.md`](ISSUE_READINESS.md) says the log is append-only and
that a later block supersedes an earlier one — which means a `released` claim
looks live from the top. Both mistakes have been made here: an agent reported
three free issues as taken, and another read a `released` claim on
[#1268](https://github.com/kofun-lang/kofun/issues/1268) as live.

**Claim when you can start, not when you decide to.** A live claim you cannot
act on for hours reads as taken to everyone who checks it, and the three
commands above cannot tell that apart from work in progress. If you want to
reserve something, record the intent instead: a comment saying *"I intend to
take this when X frees; take it sooner if you can"* costs nothing and blocks
nobody. A claim is a signal to other people, so its cost is paid by them.

**Move the claim to `pr-open` when the PR opens, not when it merges.** The
status vocabulary in [`docs/ISSUE_READINESS.md`](ISSUE_READINESS.md) treats
`active` and `pr-open` as equally live, so leaving a claim at `active` through
PR creation breaks no rule — and loses the only fact another agent wants:
**`pr-open` is not bookkeeping, it is the difference between "someone is holding
this" and "someone is holding this and you can go read what they did."** The
agent who leaves it at `active` is answering a question nobody asked while
withholding the answer to the one they did.

## Say which artifact you are about to create

Claiming the issue is not enough. Two agents wrote the same
`release/claims.json` entry within an hour: one asked the other for the wording,
received it, and wrote the entry; the other had meanwhile decided the entry
needed a specification document under it and was writing both. Neither reading
of "send me the wording" was wrong, and neither agent said which one it was
acting on.

**Before you create an artifact — a file, a claim, a gate, a fixture set — say
so where the work is tracked.** *"This needs a spec first; I am writing
`spec/x-v1.md` and the claim, do not write the entry"* is one line, and it is
the line that was missing.

Note who caught that one: not either author, but a third session reading both
pull requests because it was cutting a release and needed to know what the notes
would say. **The reviewer caught what the two authors could not**, and the
reviewer was never in their conversation — which is the argument for announcing
to the tracker rather than to each other.

## Sharing the machine

One 8-core box ran five agents on 2026-08-21. Measured that morning: **load
average 41.10 with three concurrent `task verify` runs.**
`tests/pair-coverage/driver-failures.tsv` already recorded the cost at half that
load — *"Four concurrent agent sessions on an 8-core machine took the 1-minute
load average to 21 and killed a peer's fuzz run outright"*.

Three gates cannot defend themselves, because their bounds are hard-coded rather
than configurable:

| gate | bound |
|---|---|
| `tests/fuzz/grammar.sh:101` | `timeout 2` |
| `tests/conformance/run.sh:260` | `timeout 10` |
| `roadmap`, through the LSP sidecar | absolute `hover p95 < 2ms` |

**Run one `verify` at a time per machine.** `bootstrap/stage2/verify-runner.sh`
already bounds itself with `VERIFY_JOBS`; three runs of three workers on eight
cores is slower than one run for the person who started the third. And the cost
is worse than slowness: a concurrent run makes your own result **red for a
reason that is not in your diff**, and a red you cannot trust is worse than a
slow green.

**Announce anything longer than about half an hour before you start it, and say
when it ends.** `tests/pair-coverage/measure.sh` is the worked multi-hour
example; its exact current cost is recorded in
`tests/pair-coverage/undefended.tsv`. It refuses unrecorded or stale driver
outcomes and any corpus timeout, reducing the risk that load-induced drift
enters the published basis.

**Announce a release freeze, and end it.** Cutting a release means `main` must
hold still between the commit CI proved and the tag
([`docs/RELEASING.md`](RELEASING.md) step 7). Say so before the `VERSION`
commit, say so again after the tag, and if it runs long, thaw and re-freeze
rather than holding everyone open-endedly.

## Not every agent is on the same channel

Sessions of one kind can message each other. A Codex agent on the same machine
cannot be reached that way, and **nothing in a claim tells you which kind of
agent holds it** — `codex-root-1535-wrapper-terminator-20260821` and
`claude-1508-pattern-region-20260820` are both just `agent_id` strings.

**The issue tracker is the only medium every participant shares.** Put intent
where all of them can read it: the issue you are working, or the issue whose
resource you are about to use. When three `task verify` runs saturated the box,
the only thing that reached their owner was a comment on the issue they were
working.

Assume a participant who never sees your messages: one who may be holding the
pair, saturating the machine, or about to bump `VERSION`. The protocol has to
work for them too, and that is a property of where you write things down.

# Kofun RFCs

This directory is the durable record of public semantic decisions. The process
is the [public RFC process](https://kofun-lang.github.io/kofun/docs/rfc-process/).

| File | Role |
|---|---|
| `index.json` | The authoritative ledger. Edit this. |
| `TEMPLATE.md` | The proposal template. |
| `NNNN-<slug>.md` | An accepted proposal. Immutable once accepted. |

`task rfc-registry` checks the ledger, and `task verify` runs it.

## What this is not

It is not the work tracker. Issues own work state, scheduling and evidence, and
[`ISSUE_TRIAGE.md`](https://github.com/kofun-lang/kofun-site/blob/main/content/ISSUE_TRIAGE.md)
in `kofun-lang/kofun-site` governs them. The ledger owns
one thing issues cannot: the durable statement of what was decided about the
language, separated from whether anything was built.

It is not a capability claim either. `release/claims.json` owns what the
compiler can currently do, and the ledger points at it rather than restating
it — a decision may only be recorded as `implemented` if the capability
manifest already evidences the claims it names.

## The distinction the ledger exists to keep

`accepted` means the decision is made. It does not mean an implementation
exists, and the checker refuses any accepted decision that carries an
implementation record.

`implemented` means the behaviour is enabled on the target branch, named by a
gate, and backed by capability claims that the manifest records as implemented
or checkpoint.

Between those, an amendment is how accepted semantics change. It preserves the
original wording, states the delta, repeats the compatibility analysis, and is
announced in the document that carries the decision text — so a reader of that
document sees the semantics moved rather than reading a superseded sentence as
current.

## Current contents

Every recorded decision is `migrated`: its text was written before this process
existed, and it is indexed so the ledger is complete rather than convenient.
`task rfc-registry` prints how many there are and how the states divide, so
this file does not keep a second copy of that list — a hand-written inventory
beside the ledger drifts silently, which is the defect `DD-022` describes.

Migrated decisions carry `recorded_on` — the date their text entered the
repository — rather than a review window. Inventing an `opened_on` for a
decision that predates the process would be exactly the fabricated evidence
this ledger exists to prevent, and the checker refuses it.

## Every date here is a recorded fact

A native proposal carries `opened_on` and nothing else while it is `proposed`.
It gains `review_closed_on` and `decided_on` at the moment the shepherd closes
review and records the disposition, and the checker refuses any date that has
not happened yet.

`review_period_days` is the window a proposal is *announced* with. It is
guidance for shepherds, not a gate. A shepherd who has read the responses may
close review early, and one who has not may leave it open longer; either way
`review_closed_on` says which day it actually happened.

The ledger deliberately does not hold a scheduled closing date. It used to,
and that was the same defect it refuses everywhere else: a scheduled date and
a real one are indistinguishable once written down, so a row that promised to
close on a future day read, to anything joining on that field, as a row whose
review had a definite end. It did not. The window is now stated in the
proposal document as an intention, and the ledger records only what occurred.

Four rows exercise the states that matter, and are worth reading before adding
a fifth kind:

- `DD-010` carries a real amendment: `/` on `Int` became a refusal, and the
  amendment is announced in the decision document as well as recorded here.
- `DD-012` is implemented, joined to three manifest claims.
- `DD-013` is accepted with nothing built, and therefore carries no
  implementation record at all.
- `DD-025` and `DD-030` are `conditional`: each names a query over the tracked
  corpus and the number it returned, rather than a belief about impact.

A decision whose text lives in `spec/` is indexed through its narrative entry
in [`docs/DESIGN_DECISIONS.md`](../docs/DESIGN_DECISIONS.md), which is the
`source` the amendment marker is checked against, while `normative_spec` names
the specification that actually states the semantics.

No decision is currently `superseded`; that branch of the checker is proved by
a mutation fixture rather than by a live row.

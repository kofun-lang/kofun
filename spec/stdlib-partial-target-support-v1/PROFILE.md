# Portable capability target-support profile v1

Normative schema: `kofun.stdlib-partial-target-support-v1/v1`.
Decision owner: Issue #1531. Selected: **Option A**, the portable row is
universal-only. This is a decision contract, not implementation evidence.

## One row, one universal subject

A `portable` row in `stdlib/capabilities.tsv` describes one capability over
**every declared toolchain**. The authoritative target set is the complete set
of adapter files under `tests/conformance/backends/`; each filename and its
`BACKEND_NAME` must agree. The conformance checker remains the owner of the
per-target supported/refused disposition.

The legal state table is exact:

| Executing support | Portable row | Where execution is published |
| --- | --- | --- |
| `0/N` | `planned` | nowhere |
| `1..N-1/N` | `planned` | exact-target conformance rows, a bounded MVP row, and a `checkpoint` release claim |
| `N/N` | `implemented` | the portable row may cite its focused task |

`specified` continues to mean an accepted contract with no shipped
implementation. It is not the partial-support state. No state vocabulary is
added or redefined.

## Exhaustive target disposition

Every declared target is one of:

- `supported`: the focused production gate executes on that target;
- `unsupported`: an adapter executes a stable refusal diagnostic and publishes
  no runnable artifact for the capability; or
- initially unadapted: represented by that same explicit unsupported refusal,
  never by omitting a row.

An issue, source file, pure model, or refusal sentence is not executing
support. A claimed refusal requires the adapter fixture that observes the
diagnostic and the absence of an artifact.

## Four non-overlapping authorities

- `stdlib/capabilities.tsv` owns the universal compatibility promise.
- `tests/conformance/capabilities.tsv` and backend adapters own target
  execution/refusal facts.
- `docs/MVP_IMPLEMENTED.md` may summarize a bounded checkpoint but cannot
  promote the universal row.
- `release/claims.json` may publish a `checkpoint` whose target list is exactly
  the executing subset. It cannot restate the universal promise.

Adding a backend immediately invalidates the `N/N` premise. The portable row
must reopen until the new target either executes the capability or executes an
explicit refusal. A historical release remains historical; the current matrix
may not continue to say universal `implemented` on the smaller denominator.

## Existing concurrency row

The `concurrency` row remains `planned` through `0/N` and partial execution,
and cites the still-open full-support owner, #1167. A partial implementation
may publish a target-bounded checkpoint after #1166, but #1167 closes and the
portable row becomes `implemented` only when every declared target executes
the focused scoped-parallelism gate. A target omitted from the matrix is a
failure, not a smaller denominator.

## Rejected alternatives

Option B would create a second row/registry authority for the same portable
fact. Option C would overload one state with both partial and universal
meaning. Neither cost is needed because exact-target checkpoints already have
three owning artifacts.

## Gate

`task stdlib-partial-target-support-decision` pins the subject, target-set
authority, all three state transitions, explicit refusal, #1167 close rule,
future-target invalidation, and the no-claim boundary. It mutates each
property independently. `task capabilities`, the conformance matrix, and
`task release-claims` remain the production truth gates.

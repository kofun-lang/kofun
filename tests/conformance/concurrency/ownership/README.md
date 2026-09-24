# Production scoped-parallel ownership

`task concurrency-ownership` exercises the maintained C CLI
`--check-scoped-ownership INPUT OUTPUT LOGICAL-PATH` and canonical Kofun
`check_scoped_ownership_file` (#1162). This is an analysis entry. Ordinary
compilation still refuses `par` with `E2S154`, and the gate checks that too.

For each `par`, the entry derives one bounded input for the accepted model,
`spec/concurrency/scoped-parallelism-v1/model.mjs`:

- **tasks**: the scope-HIR lifecycle rows, in spawn order;
- **steps**: dense ranks of spawn and join completions and parent access starts,
  in source order;
- **captures**: the complete capture collector's merged task records, both
  known places and explicit unknowns;
- **parent actions**: the same expanded access rows inside the block but
  outside every task lambda.

The entry then decides that input natively with the model's rules. It writes
the input, the decision and a name table for opaque identities. It exits 1
and prints the first diagnostic when any scope is rejected.

`cases.json` pairs each source with an authored expectation: step order, the
capture multiset per task, parent and after-scope actions, handle uses, and the
decision. For every native build (O0, O2, ASan+UBSan, repeated) and the
canonical Kofun half, the gate requires identical bytes. It then requires that
the derived input equals the authored expectation, and that the production
decision equals `analyzeScopedParallelism` over that derived input, diagnostic
for diagnostic. The gate restates none of the rules.

The eighteen model fixtures that source can express each have a mirror case.
A mirror must reproduce the fixture's step order, handle uses and captures, and
the model's decision class on the fixture itself. The two exceptions put a join
or a parent access at the scope-exit step, where source has no statement; the
gate confirms the model refuses them as `SPV1-INVALID-MODEL`.
`sequential-unknown-after-take` needs a slice take, which source refuses
(`E2S122`). Its mirror takes the explicit unknown of an unresolved callback
instead, and that relation is just as unprovable.

Four derivation choices are deliberately conservative:

- **Conditional joins.** Only a join written as a plain statement of its own
  block ends its task's liveness. A join inside a nested block, a loop
  condition or a short-circuit operand leaves the task live until scope exit.
- **After-scope uses.** A place a task took stays removed after the join and
  after the scope ends. The model's parent actions stop at scope exit, so later
  accesses in the same function are reported as `after_scope_actions`, and only
  those related to a taken place. The gate extends the model input with them
  (implicit joins become explicit at the old exit) before comparing.
- **Loops.** A `par` inside a loop cannot take a binding declared outside that
  loop. This is refused with `E2S123`, because the next iteration would take it
  again.
- **Escapes.** A handle used for anything other than its own join is
  `SPV1-HANDLE-ESCAPE`, decided before any capture exists: capture derivation
  cannot type an escaping handle, so such a file reports lifecycle facts only.
  Any use of the scope token other than a direct spawn is refused, because the
  model has no token input.

Constants in slice bounds are dense ranks over one scope's constants. That
keeps every order and equality the model compares exact over the full i64
range; the gate reads them back in the same rank domain.

Other checks: `logical-path` invariance of every decision, the 256/257
parent-action bound, and the entry's own `E2S35` refusals.

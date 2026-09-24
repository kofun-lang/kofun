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

Five derivation choices are deliberately conservative:

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
- **Closures.** Any lambda written in a `par` block, whether a task's or
  not, can run later or more than once. A handle used inside one, even as a
  join receiver, is an escape, and so is the scope token. A parent use of a
  callable binding that is not a capture-free local lambda literal (a
  parameter, a capturing closure, a returned lambda) takes an explicit
  unknown place at that step, and after the scope when a task took anything.
  A capture-free closure stays free to call.
- **Escapes.** A handle used for anything other than its own join is
  `SPV1-HANDLE-ESCAPE`, decided before any capture exists: capture derivation
  cannot type an escaping handle, so such a file reports lifecycle facts only.
  Any use of the scope token other than a direct spawn is refused, because the
  model has no token input.

Constants in slice bounds are dense ranks over one scope's constants. That
keeps every order and equality the model compares exact over the full i64
range; the gate reads them back in the same rank domain.

When a file has an escape, capture facts are not derived at all, and every
other scope in it reports `not-decided` rather than `accepted`. That is the
entry's statement that it decided nothing, not a model verdict, so the gate
does not compare it with the model.

Each rejection carries its contract class and the registered compiler code
(#1163). The gate reads the mapping from the §8 table of the spec and requires
the registry to hold it: `E2S183` capture conflict, `E2S184` overlap unknown,
`E2S185` parent conflict, `E2S186` use after take, `E2S187` handle escape, and
`E2S188` invalid model. Every message must match one of a closed set of
shapes: lexical task numbers (`#0`), modes, and places built from visible
names, constant bounds, `_` for a dynamic bound, or `<hidden>`. It never
carries an identity, a path, a time, or a thread. A binding name over 128
bytes is reported as `<hidden>`, and the gate checks that the name appears in
neither the message nor the document. `kofun check` on each registered
fixture must print exactly its golden to stderr, with empty stdout.

Other checks: `logical-path` invariance of every decision, the 256/257
parent-action bound, and the entry's own `E2S35` refusals.

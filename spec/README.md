# Kofun language specification draft

This directory separates normative language contracts from the smaller
executable bootstrap implementation.

- `grammar.ebnf` is the full-language grammar draft. The active Stage 1 and
  Stage 2 checkpoints intentionally accept smaller subsets.
- `semantics.md` records the semantic contract that every executable backend
  must preserve for the constructs it accepts.
- `backend-differential-contract.md` defines exact cross-backend observations
  and unsupported-feature accounting.
- `roadmap-31-34/` defines executable acceptance gates for generics, compiler
  fixed points, native Stage 1, and the language server.
- `syntax/FOUNDATIONS_AND_CONTROL.md` specifies issues 35 through 47 and links
  each claim to explicit bootstrap capability evidence.
- `syntax/EXPRESSIONS_AND_LITERALS.md` specifies issues 48 through 59 without
  treating planned syntax as implemented behavior.
- `bool-match-exhaustiveness.md` is the executable Stage 2 checkpoint for issue
  #30 over the finite `Bool = { true, false }` constructor set in statement and
  value position. It does not claim the general ADT exhaustiveness algorithm.
- `enum-match-exhaustiveness.md` generalizes that finite-set coverage to named
  concrete enums whose constructors carry zero or one `Int` payload for issues
  #30 and #782, without claiming generics, wider payloads, or a general type
  checker. Both documents are read by `tests/conformance/syntax/issues_35_47/`,
  which is their executable gate.
- `parser/TOKEN_SPANS.md` defines the current Stage 2 byte-span prototype and
  the work still required for a lossless parser.
- `modules/package-roots.md` defines deterministic manifest and anonymous
  single-file package roots and the versioned `PackageIdPayload` contract.
- `modules/source-file-mapping.md` selects explicit manifest-source module
  headers and defines versioned `FileId`/`ModuleId` identity inputs.
- `modules/namespaces.md` assigns declarations to the stable value, type,
  module, and meta namespaces and fixes deterministic lookup and collisions.
- `modules/module-identity.md` fixes production IDs, canonical compiled-
  interface bytes, and separate public, internal, and target ABI digests.
- `modules/visibility.md` defines default-private declarations, package-scoped
  `internal`, intentional `pub`, restricted ancestor visibility, and the
  identity-only access decision implemented by the focused conformance gate.
- `modules/re-exports.md` selects explicit `pub import`/`pub from` forwarding,
  preserves target identities, and rejects every visibility-widening edge.
- `tooling/typed-sidecar.md` defines the non-authoritative canonical JSON
  artifact for complete and explicitly status-marked partial semantic facts.
- `typed-sidecar/` contains its JSON Schema, canonical examples, semantic
  validator, negative corpus, replacement model, and executable gate.
- `../tooling/typed-sidecar/` implements the bounded, recursively immutable
  tooling codec and stale-safe atomic replacement without granting authority.
- `records-v1.md` selects `type Name = { ... }` declarations with labelled
  call-form `Name(field: value)` construction, fixes nominal identity,
  immutable fields, whole-record moves, and untagged declaration-order layout,
  and names `tests/conformance/records/` as its executable gate.
- `result-propagation-v1.md` selects postfix `?` on `Result[T, E]` as the one
  initial sequencing sugar, monomorphic to `Result` and desugaring after type
  resolution to the `match`-and-early-return core. Accepted as DD-036; nothing
  implements it yet and it has no gate, so acceptance settles what the sugar is,
  not that it ships.
- `type-level-programming-v1.md` defines the Type-only, named, structurally
  terminating type-function profile, its fixed reduction/display budgets, and
  the requirement that type-level features ship with inspectable traces. No
  compiler implements the profile, and `task type-reduction-trace` gates the
  trace contract rather than any reducer. V1 rejects Turing-complete type
  computation as a language goal; #1130 is the open request to supersede that
  row with a fuel-bounded v2, so the rejection is the current accepted answer
  and not a closed question.
- `effects/validation-accumulation.md` defines the accumulating validation
  contract for issue #742: three result states, independent combination that
  collects every issue in deterministic source order, dependent sequencing
  whose continuation never runs without an input value, pure v1 branches, an
  opaque `Issues[E]`, and an O(N) issue-accumulation bound. The design is
  accepted and its five open questions are decided; no library or compiler
  implements it, and its named gate does not exist yet.
- `concurrency/scoped-parallelism-v1.md` fixes the v1 spawn/join ownership
  contract for issue #555: the three `par`/`spawn`/`join` source forms, the
  second-class scope token and affine task handles, semantic liveness from
  spawn to join, `read`/`edit`/`take` capture exclusivity, the closed set of
  place-disjointness proofs, scope-exit drain with deterministic panic and
  cancellation precedence, and six required diagnostic classes. Its bounded
  executable model, fixtures, and `concurrency/scoped-parallelism-v1/check.sh`
  are gated by `task scoped-parallelism`. The document is a normative input to
  proposed `RFC-0003`, whose review closes 2026-08-16; no parser, ownership
  checker, scheduler, or backend implements it, so passing the gate is evidence
  about the contract only.
- `concurrency/schedule-trace-v1.md` is the accepted deterministic testing
  contract for issue #736: stable scope/task identities, the canonical
  `kofun.schedule-trace/v1` and `kofun.schedule-witness/v1` bytes, FIFO, seeded,
  replay, and bounded exhaustive policies over one task model, and the strict
  rejection codes that refuse a stale or drifted trace. Its model and the
  `tests/concurrency/schedule-replay/` corpus are gated by `task
  schedule-trace`. It supplies reproduction evidence for the scoped contract
  above; neither model is authority for the other, and Kofun has no production
  scheduler.
- `type-reduction-trace/kofun.type-reduction-trace.v1.schema.json`, its
  alias, type-function, and failure vectors in `examples/`, and
  `type-reduction-trace/check.sh` define the executable
  `kofun.type-reduction-trace/v1` validation gate. No active compiler emits
  this trace yet.
- `law-evidence-v2.schema.json` defines the accepted target
  `kofun.law-evidence/v2` artifact, including purpose-separated cache/evidence
  identities, ground law/implementation/model inputs, standard-v1 resource
  caps, computed assurance, and canonical counterexamples. No active compiler
  emits it yet.
- `law-evidence.schema.json` defines the historical
  `kofun.law-evidence/v1` prototype artifact. It remains available only for
  explicit identification and migration; it is not an active compiler,
  optimizer, cache, or release contract and must never be interpreted as v2.

- `aggregate-layout-v1.md`, its `aggregate-layout-v1/` reference computer,
  target files, golden vectors, and `aggregate-layout-v1/check.sh` define the
  accepted target-parameterized byte layout for `Text`, `List`, flat records,
  and flat ADT variants on `x86_64-linux` and `wasm32`. It is a layout
  contract only; no backend lowers to it yet, and the shipped native `i64`
  headers are compared against it rather than governed by it.

- `wasm-host-abi-v1.md`, its `wasm-host-abi-v1/` reference host, boundary
  document, recomputed vectors, instantiation fixtures, and
  `wasm-host-abi-v1/check.sh` define the accepted `kofun-wasm-host-abi-v1`
  boundary: one ABI version, the import allowlist with exact wasm signatures,
  the required exports, and the `Text`/`List` representation derived from the
  `wasm32` layout target. It is the input contract for wasm32 `Text`/`List`
  lowering; no backend emits it yet, and it does not describe WASI or a
  supported-engine matrix.

- `wasm-host-profile-v1.md` and `wasm-host-profile-v1/check.sh` decide how a
  build reaches that contract: the host ABI is part of the target name, so
  `--target wasm32` keeps the bounded numeric binding and
  `--target wasm32-hostabi1` is reserved for `kofun-wasm-host-abi-v1`. It
  records the legacy binding as supported rather than deprecated, names the
  native x86-64 semantic oracle and the v1 byte-layout oracle the lowering will
  be measured against, and states how a host tells the two bindings apart on
  the module bytes before instantiation. It decides activation only: no wasm
  bytes change, no capability row moves, and no backend emits the profile yet.

- `wasi-command-profile-v1.md`, its closed import/capability vocabulary,
  reference model, canonical vectors, refusal mutations, and Node-executed
  fixture in `wasi-command-profile-v1/` define the accepted implementation
  input for the reserved `wasm32-wasi-command1` target. The profile is a
  bounded `wasi_snapshot_preview1` core-module subset with explicit authority,
  borrowed guest-pointer lifetimes, read-only preopens, and no ambient access.
  It is not a language RFC or a capability claim: the shipped CLI still
  refuses the target and no backend emits it.

Design-only material in `docs/` is not normative until it is promoted here
with conformance evidence. The specification is versioned independently from
the implementation; the current draft is `0.3-bootstrap`.

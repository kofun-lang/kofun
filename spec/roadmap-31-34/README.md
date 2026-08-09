# Issues 31-34: executable roadmap

This directory records the reviewable boundary between implemented bootstrap
capabilities and the acceptance criteria of issues 31-34. It is intentionally
not an implementation claim. An unchecked item remains open even when a nearby
checkpoint is executable.

| Issue | Acceptance item | Current evidence | Status |
|---|---|---|---|
| #31 | Generic functions and types with trait bounds type-check | A focused typed-only frontend checks explicit unbounded generic function calls; generic types, bounds, traits, and lowering remain open | open |
| #31 | Strategy selected with measured justification | A baseline and measurement protocol are specified in `generics-and-traits.md`; no compiler measurements exist | open |
| #31 | Laws can be stated over generic types | Proposed syntax exists, but no generic proof kernel exists | open |
| #32 | Stage 1 compiles its own source | The canonical `S` has complete frozen-profile evidence, the trusted seed produces runnable `C1/A1`, and `A1(S) -> C2/A2` is gated by `task selfhost-generations` (#271) | implemented |
| #32 | Three generated C sources and executables are byte-identical | `task selfhost-fixed-point` (#272) proves `C2 == C3` and `A2 == A3` byte for byte, twice in normalized clean directories; `C1/A1` are hash-pinned provenance, not criteria, per #271's recorded decision | implemented |
| #32 | Manifest closes the gate and records hashes | `bootstrap/manifest.json` records the three B4/B5 gates as `working` with a `fixed_point_closure` hash block the fixed-point gate asserts, and `diverse_double_compilation` (B7) as `working` behind `task selfhost-diverse-double-compilation`; the remaining bootstrap track is B6, which has no manifest gate row because it is reproduction by a builder this repository does not run | implemented |
| #33 | Stage 1 builds through the native backend | Bounded Kofun-authored x86-64 and AArch64 ELF fixtures execute or are audited; Stage 1 still builds through C11 | open |
| #33 | Interpreted and native Stage 1 outputs match | The Kofun checker exists, but no native Stage 1 artifact exists to supply its second input | open |
| #33 | Bootstrap gate verifies the native path | Native fixtures and Stage 1 are separate gates | open |
| #34 | Inline diagnostics | Versioned diagnostics update and clear through the packaged stdio server | implemented |
| #34 | Definition and hover | Same-document bootstrap symbols and available types/modes are indexed | implemented |
| #34 | Interactive incremental performance | The deterministic 10,000-declaration, 100-range-edit gate enforces the contract thresholds | implemented |

## Current executable evidence

Run the isolated probe:

```sh
sh spec/roadmap-31-34/verify-current-gates.sh
```

It compiles the audited Stage 2 C11 checkpoint, uses that checkpoint to lower
`current-core-probe.kofun`, compiles and executes the result, and checks the
observable floor-arithmetic contract. It also confirms that the self-recompile
and artifact-equivalence manifest entries read `working` while
`diverse_double_compilation` stays `open`, then runs the packaged LSP protocol,
editor smoke, and performance gates. The fixed point those entries record is
proven by `task selfhost-fixed-point`, not by this probe.

To rerun the repository's complete Stage 2 and native fixture gates before the
probe:

```sh
sh spec/roadmap-31-34/verify-current-gates.sh --full
```

The probe demonstrates real integer Core lowering and the scoped bootstrap LSP.
The separate `task generics` gate demonstrates only explicit unbounded generic
function type checking. Neither gate demonstrates generic nominal types,
traits/bounds, generic lowering, compiler self-reproduction, native Stage 1,
project-wide editor indexing, or full compiler type inference.

## Close policy

An issue may be closed only after every acceptance item in its issue-specific
document has:

1. an executable test or reproducible measurement;
2. an artifact produced from canonical `.kofun` source;
3. an exact command recorded in the repository; and
4. no contradiction with `bootstrap/manifest.json`.

Generated bootstrap artifacts may be checked in when their canonical source,
reproduction command, and digest are recorded. Alternate implementations are
not introduced solely to preserve obsolete filenames.

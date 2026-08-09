# wasm32 host-profile activation v1

Status: accepted. Owner: repository maintainer. Issue: #1000. Parent: #998 / #26.

Two wasm32 host bindings now exist, and a module cannot carry both. The legacy
binding executes its bounded numeric slice; the aggregate binding emits its
checked arena and empty entry point while later Text/List lowering remains
unsupported. This document decides which binding a build gets, what happens to
the older one, and which oracles measure the newer one.

It decides **activation only**. The later arena implementation does not amend
that decision, and the wasm32 backend gains no Text/List capability:
`tests/conformance/capabilities.tsv` still records `wasm32-node` as
`unsupported` for `text` and for `list`.

Its normative input is `spec/wasm-host-abi-v1.md`, which this document does not
reopen. Its executable form is `spec/wasm-host-profile-v1/check.sh`, gated by
`task wasm-host-profile`.

The work had no owner because #201 was closed as not planned; #998 re-opened it
as an umbrella and made this the decision its three implementation children
wait on.

## Why this is a spec document and not an RFC

`rfcs/README.md` says the ledger owns "the durable statement of what was decided
about the language, separated from whether anything was built". Nothing here is
about the language. No Kofun program changes meaning, no syntax, type,
diagnostic, or effect moves, and every source that compiles today compiles to
the same bytes tomorrow. What changes is which host binding a *toolchain
invocation* selects.

The sibling contract settles the form. `spec/wasm-host-abi-v1.md` — the
document this one builds on, for the same target, in the same area — is a spec
document with an executable gate and no ledger row. A target-profile decision
recorded two different ways in two adjacent months would make the ledger harder
to read, not more complete.

The review window decides it either way. A native RFC is announced with the
window `review_period_days` in `rfcs/index.json` states, and carries no
`review_closed_on` or `decided_on` while it is `proposed`
(`tests/rfc/validate-registry.mjs`). Filing this as an RFC would leave #1001,
#1002, and #1004 blocked for two weeks on a decision that is not about language
semantics. The checkable-ness the ledger provides is provided here instead by
`sh spec/wasm-host-profile-v1/check.sh`, which is stronger for this subject:
it fails against the tree, not against a row.

## The decision, in one line

**The host ABI is part of the target name.** `--target wasm32` keeps the
bounded numeric binding it has today, byte for byte; `kofun-wasm-host-abi-v1`
is reached only through the separate target name **`wasm32-hostabi1`**.

## What is true today

Every claim below was read off the tree rather than off an issue body.

| Fact | Where |
|---|---|
| The legacy module has five sections — type, import, function, export, code. No memory, no global, no start, no data. | `bootstrap/wasm/compiler.c`, the legacy `emit_module` section writers |
| The aggregate arena module has one fixed memory and the four required v1 exports, but accepts only an empty entry point. | `bootstrap/wasm/compiler.c`, `emit_profile_module`; `bootstrap/wasm/object_arena_check.sh` |
| It imports exactly `kofun.print_i64` and `kofun.panic`, and exports exactly one function, `main`. | `bootstrap/wasm/compiler.c`, the import and export section writers |
| `--target` takes one value from a closed set; an unknown value exits 2 with `kofun: unsupported target:`. There is no profile or ABI option. | `bin/kofun`, the `--target` case and the build option loop |
| `wasm32-node` is `supported` for `numeric` and `functions`, and `unsupported` for `text`, `list`, and `decimal-arithmetic`. | `tests/conformance/capabilities.tsv` |
| `native-x86_64` and `native-aarch64` are `supported` for `text` and `list`, evidenced by `bootstrap/native/check.sh`. | `tests/conformance/capabilities.tsv` |
| `c11-stage1` and `c11-stage2` are `unsupported` for both `text` and `list`. | `tests/conformance/capabilities.tsv` |
| The v1 contract requires an exported `memory`, an immutable `kofun_abi_version: i32 = 1`, `kofun_start`, `kofun_alloc`, and imports only from `kofun:host-abi-v1`. | `spec/wasm-host-abi-v1.md` |
| That contract already states that adopting it "is a versioned change to that target, recorded as one". | `spec/wasm-host-abi-v1.md`, "Relationship to the shipped wasm32 target" |

The shipped module has no linear memory and no globals at all. That is not a
detail: it is why the two bindings are decidable apart on the bytes, and why
neither can be reached by accident from the other.

## Decision 1 — activation is a target name

`kofun-wasm-host-abi-v1` is activated by the target name `wasm32-hostabi1`.
Bare `--target wasm32` stays bound to the numeric binding described by
`bootstrap/wasm/README.md` and does not change.

Three properties follow, and they are the reason for the choice:

- **The emitted ABI is a function of exactly one argument.** Everything in the
  repository that keys on a target — the `case` in `bin/kofun`, the adapters in
  `tests/conformance/backends/`, the rows in `tests/conformance/capabilities.tsv`,
  the closed `targets` vocabulary in `release/claims.json`, and the target ABI
  digest named by `spec/modules/module-identity.md` — keeps working by learning
  one new value. None of them grows a second dimension.
- **A revision bump is a new name.** `kofun-wasm-host-abi-v2`, if it ever
  exists, is `wasm32-hostabi2`. The revision travels in the selector, so
  "a versioned change to that target, recorded as one" is what the command line
  already says.
- **Selection is fail-closed in both directions.** A toolchain that does not
  implement a profile refuses its name with `kofun: unsupported target:` and
  writes nothing, rather than falling back to a binding the caller did not ask
  for. That is DD-012 applied to the selector rather than to lowering.

The name is reserved by this document. Toolchains before #1001 resolve it to
`kofun: unsupported target: wasm32-hostabi1`; current toolchains emit the
arena-only module and continue refusing source outside that implemented slice.

## Decision 2 — compatibility, and how a host tells them apart

**The legacy numeric ABI stays supported.** It is not deprecated by this
document and carries no retirement date. It is the only wasm32 binding with an
executing conformance corpus and a browser host, and removing it would delete
evidence rather than migrate it. Retiring it is #26's decision, and the
condition is stated rather than implied: the v1 profile must first execute the
`numeric` and `functions` corpora and the browser sample that
`sh bootstrap/wasm/check.sh` proves today.

**The v1 aggregate ABI is accepted and partially implemented.** #1001 owns the
arena and required export surface; Text/List source values remain fail-closed
until #1002 and #1004 land.

**A host identifies the binding on the module bytes, before instantiation.**
The two surfaces are disjoint, and neither test needs an engine to run guest
code:

| | legacy numeric | `kofun-wasm-host-abi-v1` |
|---|---|---|
| import module name | `kofun` | `kofun:host-abi-v1` |
| exports | exactly one function, `main` | `memory`, `kofun_abi_version`, `kofun_start`, `kofun_alloc` |
| exported globals | none | `kofun_abi_version: i32 = 1`, immutable |
| entry point | `main()`, called by the host | `kofun_start(argv)`, called by the host |
| start section | absent | forbidden by the contract |

A v1 host runs its phase-1 check and refuses a legacy module with
`abi-version-mismatch` on the first import it reads. A legacy host asked for a
v1 module finds no `main` to call. Neither discovers the mismatch at the first
boundary call, because neither gets that far.

`node spec/wasm-host-abi-v1/hostabi.mjs module MODULE.wasm` is that phase-1
check, pointed at bytes the contract's own fixtures did not assemble. It links
nothing and instantiates nothing, so a verdict costs no guest execution.

**What breaks: nothing, and that is a count rather than a reassurance.**

```
$ git grep -nE -- '--target wasm32([^-]|$)' -- '*.sh' | wc -l
19
$ git grep -lE -- '--target wasm32([^-]|$)' -- '*.sh' | wc -l
7
```

19 invocations in 7 scripts build with the legacy selector at the commit that
accepts this document, and `--target wasm32` means for every one of them what
it meant before. The number is not zero because nothing calls the target; it is
19 because 19 calls keep working.

A caller who wants the v1 profile changes two things together, and must change
both:

1. the selector, from `--target wasm32` to `--target wasm32-hostabi1`; and
2. the host, from the two `kofun.*` function imports and a `main()` call to the
   `kofun:host-abi-v1` allowlist, the four required exports, and a
   `kofun_start(argv)` call.

There is no flag day and no mixed module. A caller who changes only the
selector gets a module their old host cannot link; a caller who changes only
the host has nothing to link it to.

## Decision 3 — two oracles, and they stay independent

**Semantic oracle: native x86-64**, through the shared corpora
`tests/conformance/text` and `tests/conformance/list`, run by
`sh tests/conformance/run.sh` and registered in
`tests/conformance/capabilities.tsv`.

This is settled by the manifest rather than by preference.
`tests/conformance/capabilities.tsv` records `native-x86_64` as `supported` for
both corpora with `bootstrap/native/check.sh` as evidence, and records
`c11-stage1` and `c11-stage2` as `unsupported` for both. A C11-only oracle
cannot observe a `Text` or a `List` today, so choosing it would mean waiting on
work that is not on this path.

**Byte-layout oracle: the v1 reference host**, `sh spec/wasm-host-abi-v1/check.sh`,
which recomputes every offset, stride, and object image by running
`spec/aggregate-layout-v1/layout.mjs` over the pinned `wasm32` target.

The two must stay independent, and the rule that keeps them so is: **the
semantic oracle never sees the bytes, and the byte oracle never sees the
source.** Native x86-64 answers what a program observably does; the reference
host answers whether the wasm32 object images are what the layout rules
compute. A single oracle that did both would be checking a backend against
itself.

Neither oracle is a wasm32 capability claim. Passing both means the wasm32
profile agreed with an executing backend and with recomputed layout vectors; it
does not mean any corpus row moved.

## Rejected alternatives

**Atomic replacement — make `--target wasm32` emit v1.** Rejected. It deletes
the `print_i64` contract with no v1 equivalent: the allowlist in
`spec/wasm-host-abi-v1.md` has `text_out`, `list_int_out`, `list_text_out`, and
`abort`, and nothing that prints an `Int`. Every observation in the `numeric`
and `functions` corpora, the browser sample, and the fuzz adapter runs through
`print_i64`. Replacement would break all 19 invocations counted above at once
and strand the evidence the target already has, in exchange for one fewer
target name.

**Source-shape selection — pick the ABI from what the program uses.** Rejected.
Identical command lines would emit different host ABIs, so a build cache keyed
on the target would be wrong, a host could not know what to supply without
reading the source it is not given, and adding a `Text` literal to a working
program would silently change the binding its host must implement. Fail-closed
refusal of an unsupported construct is the behaviour DD-012 requires; quietly
switching contract is the opposite of it.

**An orthogonal `--host-profile` flag alongside `--target wasm32`.** Rejected,
and this was the close one. It reads well and keeps one wasm32 target name. But
it makes the emitted ABI a function of two arguments that must then be
validated pairwise — `--host-profile` with a native target, with `-g`, with
`--emit-c` — and every keyed structure listed under Decision 1 would have to
learn the second dimension or silently key two different modules the same way.
DD-026 is the general form of that objection: one digest never does two jobs,
and a target that means two ABIs is one name doing two jobs. The trade accepted
here is a second target name for one architecture, and the cost is real: a
reader of `--target wasm32` still cannot tell from the name alone which binding
it is, which is why `bootstrap/wasm/README.md` now says so in its first
paragraph.

**A C11-only differential oracle.** Rejected on the manifest, above.

## What #1001, #1002 and #1004 may assume

- The selector is `--target wasm32-hostabi1`. It is one argument, and it is the
  only thing that activates the profile.
- `--target wasm32` must keep emitting the legacy binding, unchanged. The gate
  for this document fails if that stops being true.
- The legacy target is not being retired, so no child needs to migrate its
  fixtures, its browser sample, or its corpus rows.
- A module is identified as v1 by
  `node spec/wasm-host-abi-v1/hostabi.mjs module MODULE.wasm`, which is the
  accepted contract's own phase-1 check and runs no guest code.
- Semantic differential observations go against native x86-64; byte and layout
  observations go against `sh spec/wasm-host-abi-v1/check.sh`. Neither is
  blocked on the C11 lanes.
- A new profile is a new `targets` token in `release/claims.json`, so the
  existing `wasm32-arithmetic-core` claim keeps its exact bounded wording.

## What they must still decide for themselves

This document does not decide any of the following, and a child that needs one
of them owns it:

- **Which corpus rows the profile may claim.** `tests/conformance/list` uses
  `map`, `filter`, `fold`, and pipelines; `tests/conformance/text` uses
  concatenation and grapheme operations. #1004's slice is literals, `len`, and
  checked indexing. Marking a corpus `supported` for a slice that executes part
  of it would be exactly the silent fallback DD-012 forbids, so a child either
  covers a corpus or adds a narrower one — it does not widen a row to fit.
- **The backend adapter's name and whether one is added at all.**
  `tests/conformance/check-capabilities.sh` requires an adapter's
  `BACKEND_NAME` to equal its filename and forbids an adapter from carrying its
  own corpus list, so the adapter identity is a child's decision made under
  that constraint.
- **The arena's size, growth, and placement.** `spec/wasm-host-abi-v1.md`
  explicitly states no allocator contract; `kofun_alloc` is an entry point with
  an ownership rule. #1001 chooses the policy.
- **Whether `main` is also exported by a v1 module.** The contract requires
  four exports and forbids none, so this is open. Exporting both is legal and
  still not ambiguous — the version global and the import namespace decide the
  binding — but it is a child's call, not an assumption to inherit.
- **Whether the browser sample gains a v1 host.** Out of scope here.

## What this document does not claim

- **No value code generation.** Nothing here lowers `Text` or `List`. #1001,
  #1002 and #1004 own the implementation slices.
- **No capability.** `wasm32-node` supports what it supported before. No row in
  `tests/conformance/capabilities.tsv` moves, and no claim in
  `release/claims.json` is added or widened.
- **No new host behaviour.** The identification rule is the contract's existing
  phase-1 check; this document names it as the migration's discriminator and
  exposes it over a file, and adds no rule to it.
- **No WASI, engine matrix, threads, SIMD, GC types, or component model.** The
  boundaries in `spec/wasm-host-abi-v1.md` are unchanged and unweakened.
- **No schedule.** Acceptance of an activation rule is not a commitment to when
  the profile is implemented.

## Gate

`sh spec/wasm-host-profile-v1/check.sh` proves, on every run:

1. `--target wasm32` still emits the legacy binding — the engine's own view of
   the artifact shows imports from `kofun`, exactly one export `main`, and none
   of the four v1 exports.
2. The accepted v1 contract refuses that artifact with `abi-version-mismatch`,
   with nothing linked and nothing instantiated, while accepting its conforming
   fixture in the same run — so the refusal is discrimination, not a validator
   that refuses everything.
3. The reserved name behaves correctly at whatever stage the migration is in:
   before #1001 it is refused with no artifact; after #1001 whatever it emits
   must be accepted by the v1 contract. There is no third outcome, and the gate
   fails on one.
4. An unimplemented revision — `wasm32-hostabi0` — is refused rather than
   quietly downgraded to a binding the caller did not name.
5. Source shape does not select an ABI: a `Text` source built for `wasm32` is
   refused with no artifact, rather than switching contract.
6. This document, `bootstrap/wasm/README.md`, and `spec/wasm-host-abi-v1.md`
   all name the selector, so activation cannot drift back into prose.

# Standard library charter

Status: accepted policy for GitHub issue
[#636](https://github.com/kofun-lang/kofun/issues/636). This document decides what
ships, who owns it, and how it is versioned. It does **not** claim that every
capability below is implemented — the matrix says which are, and the checker
refuses a matrix that overstates.

Decision owner: the repository maintainer. Changing a tier boundary, the
compatibility promise, or a `non-goal` classification requires a separately
reviewed change to this document and to
[`stdlib/capabilities.tsv`](../stdlib/capabilities.tsv).

The words **must**, **must not**, **should**, and **may** are normative.

## The problem this solves

"Standard library" already means four different things in this repository:
a Linux syscall seed under `stdlib/`, first-party frameworks under
`framework/`, a generated planning catalogue, and prose in the roadmap. Each
carried its own implied promise about portability, compatibility, and security
updates. This charter makes one promise per tier, and makes the coverage claim
machine-checked so it cannot drift ahead of the code.

## Tiers

Four tiers, distinguished by what each promises rather than by what it
contains.

### 1. Prelude / built-ins

Tiny, implicitly available language essentials. **No** I/O, network, clock,
randomness, process access, or allocation-heavy convenience. Anything that can
observe or change the outside world is disqualified from this tier by
definition, not by judgement.

### 2. Portable standard library

Shipped and tested with every toolchain, explicitly imported, source-compatible
within an edition, and pure Kofun where practical. Collections, text and bytes,
`Result`/`Optional`, path-independent encodings, testing primitives, and the
portable half of any capability whose other half is a platform adapter.

### 3. Platform standard adapters

First-party implementations of filesystem, process, clock, entropy, socket, and
terminal capabilities. **Target support is explicit: an unsupported target must
fail at build time rather than degrade silently.** A capability that cannot fail
loudly on an unsupported target does not belong in this tier.

### 4. Official independently versioned modules

Security- and protocol-heavy components — HTTP and TLS, time-zone databases,
compression, database drivers, application frameworks. They may ship in the
default distribution, but **must be updateable without waiting for a compiler
release**, because a TLS fix that waits for a language release is a TLS fix that
arrives late.

Any later simplification of these four must still preserve the explicit
bundling, versioning, security-update, target-support, and binary-size
contracts. Merging tiers 3 and 4 in particular would put a security update on
the compiler's release cadence, which is the failure this split exists to
prevent.

## The coverage matrix

[`stdlib/capabilities.tsv`](../stdlib/capabilities.tsv) is the normative
statement of what exists. `sh stdlib/check-capabilities.sh` — wired in as
`task capabilities` and part of `task verify` — enforces it.

Five states, and what each is allowed to cite as evidence:

| state | meaning | evidence the checker requires |
|---|---|---|
| `implemented` | executable today | a `task <target>` that **exists in `Taskfile.yml`** |
| `specified` | accepted contract, nothing shipped | a `spec/` or `docs/` path that **exists** |
| `planned` | scoped, not started | one or more issue references |
| `deferred` | valid, outside the active milestone | one or more issue references |
| `non-goal` | refused, with a reason | the literal `charter`; the note carries the reason |

The evidence rule is the point. `implemented` cannot be claimed by citing a
source file, because a source file no gate reads proves nothing — the checker
refuses `implemented` unless the evidence is a task target it can find. An open
generated planning issue (`#35`–`#525`) is **never** implementation evidence;
the checker cannot tell which issues are generated, so the reviewer must.

The checker also carries nine negative self-tests. Each breaks exactly one rule
— an unknown state, an `implemented` row citing a path instead of a task, a
`specified` row citing a file that does not exist, a `non-goal` that smuggles in
evidence, a duplicated job id — and each must be refused. A checker that
silently stopped enforcing one of these would keep reporting PASS on an honest
matrix, which is why the mutations are run rather than trusted.

Finally, the checker holds its own list of the capabilities this charter names,
and fails if the matrix lacks a row for one. **A missing row looks exactly like
a missing problem**, so absence is the failure mode worth catching.

## What is decided here

#636 asked for four classifications. They are:

- **HTTP client** — `planned`, tier 4. The contract (#638) comes before the
  core (#644), because URL, TLS, streaming, and cancellation boundaries change
  the shape of the API. The closed HTTP *server* framework (#24) is not
  evidence that a client exists.
- **Calendar, date, and time zones** — split. `date-time-core` is `planned` in
  tier 2 (#639, #645); `time-zone-data` is `planned` in tier 4 (#648), because
  a tzdb is data that expires and must update independently. `clock-core` is
  already `implemented` and stays deliberately separate from both: a monotonic
  reading is not a calendar.
- **Benchmark harness** — `planned`, tier 2 (#640, #646).
- **YAML** — **`non-goal`**. TOML is the baseline configuration format and the
  toolchain's own config uses it. A second configuration language splits every
  tool that reads config, and the cost is paid forever by users who did not
  choose it. This is a refusal, not a deferral: it should not be revisited
  without a concrete consumer that TOML cannot serve.

Also classified, since #636 required the Go-style gap inventory to be explicit
rather than implied: buffered I/O, URL, secure randomness, and temporary files
are `planned`; hashes and checksums, compression and archives, MIME, and
crypto/TLS are `deferred`; database drivers are a `non-goal`.

Three of those deserve their reason stated. **Hashes and checksums** are
deferred because there is no language-level consumer — the toolchain's narrow
integrity CLI is not a general standard-library API, and an API written before
something needs it will be the wrong API. **MIME** is deferred to the HTTP client contract, because content
negotiation is where it acquires meaning. **Crypto and TLS** are deferred *and*
pinned to tier 4: they must never enter the portable tier, whatever their state,
because that would put them on the compiler's release cadence.

## Engineering rules

- Prefer Kofun source over trusted or native code. Keep the trusted platform
  surface small and audited.
- Third-party native dependencies are not forbidden, but must be declared,
  pinned, licensed, reproducible, replaceable behind a Kofun contract, and
  absent from targets and profiles that do not opt in.
- **No ambient authority.** Filesystem, process, clock, randomness, and network
  operations retain explicit effect and capability boundaries. `stdlib/random`
  already follows this: one adapter file is the sole point at which
  nondeterministic input enters, and the core is deterministic.
- Resource APIs use `read` / `edit` / `take` with deterministic cleanup. Raw
  handles and errno values do not leak into user code.
- **Pay for what you use.** An unused standard module must not enlarge a static
  artifact, and the code-size and startup cost of included modules is recorded.
- Parsers and protocols carry adversarial limits, fuzz fixtures, and typed
  `Result` errors. No undocumented sentinel values.
- Every public module has a short recipe, a precise reference, a runnable
  example, and a way for `kofun` tooling to list and search its exported
  operations.
- Security-critical tier 4 modules have an update channel and support window
  separate from compiler releases.

## Compatibility

Two promises, deliberately distinct and separately testable.

**Core compatibility** covers the prelude, the portable standard library, and
the platform adapters. Within an edition, source compatibility is kept: a
program that compiles against one toolchain compiles against the next. Removing
or renaming a public operation is an edition-level change.

**Module compatibility** covers tier 4. Each module carries its own version and
its own compatibility statement. A module may make a breaking change without an
edition, and the distribution may ship a newer module against an older compiler.
This is the whole reason the tier exists.

A capability that moves between tiers changes which promise applies to it. That
is an edition-level change and must be recorded here, not only in the matrix.

## What this charter does not do

- It does not implement anything.
- It does not promise Ruby API compatibility or clone Go package names. Those
  are prior art for *coverage and documentation discipline*, not an API to copy.
- It does not make convenience functions implicit in the prelude.
- It does not treat frameworks as language core.
- It does not turn the generated `#479`–`#503` catalogue into 25 simultaneous
  implementation tasks. Those issues describe subjects; this document describes
  policy; neither is executable evidence.

## Validation

| Check | Command | Expected |
| --- | --- | --- |
| Matrix | `task capabilities` | every row valid, every named capability present, 9 mutations refused |
| Existing seed | `task stdlib` | pass without widening the trusted surface |
| Repository | `task verify` | pass |

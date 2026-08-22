# RFC-0018: Kofun is a self-contained native toolchain, not a hosted-language frontend

- Shepherd: hjosugi
- Opened: 2026-08-11
- Status: accepted
- Decided: 2026-08-11

> **Amended: `RFC-0018/A01` (2026-08-13).** The accepted text below is
> preserved as written. Its Linux-only minimum is superseded: the completion
> profile now requires Linux, Windows, and macOS on both x86-64 and AArch64,
> with direct ELF64, PE32+, and Mach-O 64 image writing. The ledger amendment
> and `spec/native-toolchain-v1/contract.json` are authoritative.

This RFC records the completion contract behind the native-toolchain direction
in [#1218](https://github.com/kofun-lang/kofun/issues/1218), the bootstrap
reproduction work in [#274](https://github.com/kofun-lang/kofun/issues/274),
and the 1.0 tracker [#1119](https://github.com/kofun-lang/kofun/issues/1119).
It is a target contract, not an implementation or release claim.

## Summary

Kofun's product target is a Rust/Zig-class systems language and toolchain whose
supported native path is implemented in Kofun and emits complete ELF images
directly. A production Kofun release must compile, link, package, test, and
rebuild its own full-language compiler without requiring a C/C++ compiler,
assembler, system linker, Rust, Cargo, Zig, Node.js, Python, or another build
language.

The operating-system kernel ABI, a firmware or WebAssembly host ABI, and an
explicit versioned foreign-library adapter remain legitimate external
boundaries. They are runtime/platform contracts, not hidden build tools.

The machine-readable form is
[`spec/native-toolchain-v1/contract.json`](../spec/native-toolchain-v1/contract.json).

## Motivation

Kofun already has direct x86-64 and AArch64 ELF checkpoints and a bounded
Kofun-written fixed point. The normal repository gate still needs a C compiler,
shell, Node.js, and go-task, and the C11 path still dominates many language
slices. Without an explicit end-state those useful bootstrap tools can become
permanent architecture by accident.

"Kofun compiles Kofun" is also too weak. A compiler that emits C but needs the
host linker, a package manager written in JavaScript, or a test runner that
requires Cargo is not a self-contained Kofun toolchain. This RFC makes the
whole path, rather than one executable, the unit of completion.

## Detailed design

### Completion profile

The profile name is `kofun-only-native/v1`. It is complete only when all rows
below are independently evidenced on the exact release commit.

| Surface | Completion requirement |
|---|---|
| compiler | Full supported language, diagnostics, ownership/effects, generics, and backend are Kofun source executed by the preceding released Kofun compiler. |
| native image | `native-x86_64-linux-elf64` and `native-aarch64-linux-elf64` emit deterministic complete ELF images directly, including the selected runtime; no assembler or linker process runs. |
| portable image | `wasm32-hostabi1` is the versioned object-capable portable target. Bare `wasm32` keeps its distinct bounded identity. |
| build | Manifest evaluation, dependency planning, incremental identity, image assembly, and build scripts required by a release are Kofun programs or compiler built-ins specified as Kofun semantics. |
| package | Resolution, lockfile verification, signature/digest checks, archive handling, and source-free KIF consumption are Kofun paths. |
| test | The release qualification suite can be orchestrated by the shipped Kofun toolchain. Foreign differential or bootstrap-diversity tests may remain additional evidence, never required to use the toolchain. |
| bootstrap | Starting from a released Kofun compiler, two clean full-language generations reach a byte-identical compiler/toolchain fixed point. Independent builders reproduce it. |
| host operations | Files, environment, processes, clocks, entropy, and network use explicit typed authorities. The build core requires no ambient process-spawn authority. |
| release | Binaries, source, KIF/package artifacts, hashes, capability manifest, and fixed-point evidence all bind the same exact commit and are read back publicly. |

### Allowed external boundaries

Three classes are allowed:

1. an operating-system kernel ABI called by emitted machine code;
2. an explicitly versioned firmware or WebAssembly host ABI; and
3. an explicitly imported, versioned foreign-library adapter whose capability,
   ABI, ownership, and audit boundary are visible in Kofun source and package
   metadata.

An allowed foreign adapter is optional program functionality. It may not be a
hidden requirement for compiling, linking, packaging, testing, or rebuilding
the core toolchain. In particular, a Rust shim can remain an interop example
without making `rustc` or Cargo part of Kofun's completion profile.

### What is in neither list, and why that is not an omission (#1467)

The forbidden requirements and the allowed boundaries do not partition the
universe of external programs, and reading them as though they did produces a
false question: *which list does `readelf` belong to?*

A forbidden core build requirement is a **non-Kofun thing this profile promises
Kofun will replace** — either it produces or transforms the shipped artifact
(`cc`, `c++`, `assembler`, `system-linker`, `system-sdk`, `import-library`,
`rustc`, `cargo`, `zig`), or it is the language, runtime, or driver the build
itself is written in (`node`, `shell-build-driver`, `go-task`, `python`,
`non-kofun-build-language`). An allowed external boundary is a **runtime or
platform contract of the produced program**, which is why the three classes
above are scoped to emitted machine code, a host ABI, or an imported adapter.

A program that is neither — one the build merely *runs* to inspect what it
produced, or to compare, filter, or move bytes — is in neither list, and that
is deliberate. `readelf`, `nm`, `ar`, `file`, `ldd`, `cmp`, `sed`, `grep`,
`awk`, `git`, `timeout`, `script` and `qemu-aarch64` are all in this third
region. So was `sha256sum` before #1213 replaced it: a real, GNU-only
dependency across dozens of files, whose remedy was replacement, with no
contract entry and no boundary claim in between.

The rule is not "external and unshipped". Measured with the census's own
command-position detector, that criterion would admit `cmp` at 955 invocations,
`grep` at 935 and `sed` at 467 — against `readelf`'s 57 — and the forbidden
list would become an installation profile rather than a statement about Kofun's
completion. That list already exists, three times over:
`docs/GETTING_STARTED.md`'s prerequisites, `release/claims.json`'s
`reproduction.prerequisites`, and the published
`artifacts/release-evidence/REPRO.md`.

**Where the third region is checked** is therefore the prerequisite manifest,
not this contract — and that is where #1467 found the real defect: the check is
one-directional. It fails when a *declared* prerequisite is named by no
reachable script, and never when a *required* tool is declared by no claim.
`readelf` is the second kind: three of fifty-three claims declare it while
eleven files require it.

### Bootstrap and provenance

The trusted starting binary is always named and hash-pinned. It compiles the
canonical Kofun toolchain source to generation A, A compiles the same source to
B, and B compiles it to C. The qualification gate requires B and C artifacts,
KIF, package graph, and normalized diagnostics to be byte-identical. Repeating
the build in a normalized clean directory produces the same bytes.

The current C seed and host C compiler are bootstrap provenance for the bounded
checkpoint. They are not forbidden historical inputs and they are not evidence
for this full completion profile.

### No semantic fallback

No target may invoke a foreign compiler or switch backend identity because a
construct is unsupported. It must either execute the selected Kofun backend or
refuse before publishing an artifact. Source shape, installed tools, PATH, and
host probes never select a different backend.

### Capability truth

`release/claims.json` remains the implementation authority. This RFC is
`accepted`, not `implemented`; the machine-readable contract therefore says
plainly that it does not claim today's bounded compiler meets the profile.
Each completion row needs a named executable gate and exact release evidence
before a future amendment may record implementation.

## Semantics

The RFC changes no source-language expression. It defines what the name
"self-contained Kofun native toolchain" means:

- the required build graph contains only Kofun toolchain artifacts and declared
  data inputs after the trusted starting Kofun binary;
- a process invocation of `cc`, `c++`, an assembler, a linker, `rustc`, Cargo,
  Zig, Node.js, or Python makes the completion gate fail;
- direct kernel syscalls in the produced program do not count as build-tool
  dependencies; and
- an optional explicit foreign adapter does not promote the core build to a
  foreign-hosted toolchain.

## Diagnostics

No source diagnostic is added. The future completion gate reports the first
undeclared executable, unexpected process, non-Kofun tool artifact, target
fallback, digest mismatch, or fixed-point mismatch with the path and phase that
introduced it. It publishes no partial success artifact.

## Ownership and effects

Toolchain I/O follows the same authority and affine-resource rules as user
programs. Build planning is pure. Reading source/package state requires an
attenuated filesystem authority; publishing artifacts requires a distinct
write authority; optional process adapters require `ProcessAuthority`. The
core direct-native build never acquires `ProcessAuthority` merely to run a
compiler, assembler, or linker.

## Alternatives

**A Kofun frontend hosted permanently on C, Rust, Zig, or LLVM.** Rejected. It
can be a bootstrap or optional backend experiment, but it cannot satisfy the
product objective.

**Only the compiler is written in Kofun.** Rejected. A foreign package manager,
linker, build orchestrator, or mandatory test runtime leaves the toolchain
hosted.

**Forbid all foreign libraries.** Rejected. Explicit adapters are necessary for
real systems work; the important boundary is that they are optional, versioned,
capability-visible, and never a hidden build dependency.

**Reuse a system linker for convenience.** Rejected for the required native
targets. A separately named interoperability target may use one, but it cannot
replace or silently serve the direct target.

## Drawbacks

The contract requires Kofun implementations of mundane tooling and object/image
work that mature languages often delegate. Supporting a new object format or
OS needs explicit engineering. The fixed-point and process-audit gates are
costly, and optional foreign adapters create two evidence classes that must
never be conflated.

## Compatibility and migration

Category: `none`. This RFC changes no accepted program and promotes no
capability. Existing C11, shell, Node.js, Rust-shim, and go-task paths remain
valid bounded bootstrap, test, or interoperability evidence. They simply do
not satisfy `kofun-only-native/v1` until replaced on the required core path.

## Implementation plan

1. Preserve and expand the direct ELF backends while every unsupported shape
   fails closed.
2. Complete full-language self-hosting and source-free KIF/package builds.
3. Move build, package, test orchestration, archive, hashing, and image writing
   onto shipped Kofun surfaces.
4. Add process-trace evidence proving forbidden tools were not executed.
5. Reproduce the clean full-language fixed point independently.
6. Only then add an `implemented` ledger record and release capability claim.

The host-authority, numeric, HTTP, and generics decisions in RFC-0014 through
RFC-0017 are aligned children of this completion contract.

## Validation

`task native-toolchain-contract` checks the versioned contract and adversarial
mutations. `task rfc-registry`, `task release-claims`, and
`task repository-check` prove that accepting it creates no implementation
claim. A future `native-toolchain-complete` gate must additionally inspect the
actual process graph and artifacts; this RFC deliberately does not add a green
placeholder with that name.

## Unresolved questions

The completion definition is closed. Platform expansion beyond Linux ELF64 and
`wasm32-hostabi1`, the audit body for a 1.0 release, and the schedule remain
separate work. None can weaken the two required native targets or introduce a
hidden hosted build.

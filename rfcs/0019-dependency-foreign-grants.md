# RFC-0019: A dependency contains foreign code only under its consumer's `foreign` grant

- Shepherd: hjosugi
- Opened: 2026-10-04
- Status: accepted
- Decided: 2026-10-04

Decision record for [#1712](https://github.com/kofun-lang/kofun/issues/1712).
The decision owner accepted
[the proposed answers](https://github.com/kofun-lang/kofun/issues/1712#issuecomment-5976832007)
to the issue's nine questions on 2026-10-04, as
[recorded on the issue](https://github.com/kofun-lang/kofun/issues/1712#issuecomment-5977469215).
This document states those answers as target semantics. It implements nothing:
no manifest field, resolver check, KIF field, diagnostic, or release capability
exists because of it.

It amends no accepted decision. It is orthogonal to RFC-0012, consistent with
RFC-0014, and does not touch #1196's adapter descriptor.

Measured against `origin/main@7d2caf6f3fa3bf733533b08ccf20b6551c3e13f0` unless a
row says otherwise.

## Summary

Each dependency is built under a **grant** that its consumer writes in the
manifest: `plain` or `foreign`. A `plain` dependency may contain no foreign
code. Foreign code means a `trust raw-foreign` module, an `extern "C"`
declaration, or a native artifact. A `foreign` dependency may contain all
three. A dependency with no grant is `plain`.

Grants follow Flix's propagation rule. A package's grant caps the grants of
everything below it. A package reached along several paths gets the most
restrictive grant of those paths. No package can grant more than it was given.
The package being built is always `foreign`.

The package resolver checks all of this before anything is compiled. It reads
the module-trust bytes that KIF already carries, so it never needs dependency
source. `kofun.packages.toml` `format = 1` keeps its meaning. From
`format = 2`, a native-artifact entry needs an explicit `foreign` grant.

Nothing changes for a program today. No tracked manifest exists, the current
resolver refuses `format = 2`, and there are no source packages.

## Motivation

Kofun has two trust mechanisms, and neither answers whether a third-party
package may *contain* foreign code.

- **RFC-0012 is façade-local by design.** `trusted import` admits a raw module
  into exactly the module that writes it. So *"trust never forwards"* (§5),
  and a downstream consumer *"cannot discover from the façade's interface that
  a raw module exists behind it."* RFC-0012 controls who may **name** raw
  declarations inside a package. It says nothing about whether a package may
  **contain** them.
- **#1196 is per adapter.** It admits one environment-read adapter through an
  internal descriptor. It says the descriptor is not a *"public manifest
  grant"*, and it says: *"Native code can read the operating system directly
  without any Kofun authority."*

RFC-0014 makes host access explicit. Environment, process, and directory
operations need an authority value that the caller hands over. Foreign code is
the remaining way around that. Once source packages exist, any dependency could
ship a `trust raw-foreign` module with an ordinary façade over it. A consumer
could neither see it nor refuse it.

Measured on `7d2caf6f3fa3bf733533b08ccf20b6551c3e13f0`:

| Surface | Command | Result |
|---|---|---|
| manifest formats | `bin/kofun package lock` on a manifest whose first line is `format = 2` | `kofun package: kofun.packages.toml:1: unsupported manifest syntax`, exit 2 |
| a grant field | `bin/kofun package lock` on a `format = 1` manifest with a `grant = "foreign"` line in a dependency | `kofun package: kofun.packages.toml:6: unsupported manifest syntax`, exit 2 |
| trust in the resolver | `git grep -n -i -E 'trust\|security\|grant' -- package/manager.sh` | no matches, exit 1 |
| tracked manifests | `git ls-files \| grep -c 'kofun.packages.toml$'` | `0` |
| resolver boundary | `package/README.md` § *Current boundary* | `static-library` is the only artifact kind; resolution is *"direct and one level"*, with no transitive dependencies, install scripts, or package-provided build steps |
| module trust in KIF | `task kif-module-trust-profile` | `PASS`: required tag `0x800A` carries exactly `ordinary` or `raw-foreign` |
| the class decides admission | `task raw-imports` | `PASS`, including the mutation proving the decision is read from the **serialized** class |
| `extern "C"` implies the class | `task raw-imports`, case `extern_without_trust` | an `extern "C" fn` in a module without `trust raw-foreign` is refused with `E2S174` (`bootstrap/stage2/imports_qualified.c`, #1422) |

The last three rows are why the check can be source-free. Every module of a
built package has KIF bytes saying `ordinary` or `raw-foreign`. A module that
declares `extern "C"` cannot be `ordinary`.

Deciding before source packages exist costs nothing to migrate. Flix added its
equivalent after its package manager shipped (0.66.0, below), so every existing
manifest needed a default.

### Prior art: Flix security contexts

All Flix citations are pinned:

- [`flix/flix@35533f982dd75ee806dde039e60702c71a432c2d`](https://github.com/flix/flix/tree/35533f982dd75ee806dde039e60702c71a432c2d)
  - `main/src/ca/uwaterloo/flix/language/ast/shared/SecurityContext.scala`: the lattice
    `paranoid < plain < unrestricted`, `Default = Plain`, and `glb`.
  - `main/src/ca/uwaterloo/flix/tools/pkg/ManifestParser.scala`: an absent
    `security` key is `SecurityContext.Default`. An unknown value is
    `FlixUnknownSecurityValue`.
  - `main/src/ca/uwaterloo/flix/tools/pkg/FlixPackageManager.scala`:
    - `minSecurityLevels` starts every manifest at `unrestricted`. Each round
      lowers a manifest to the `glb` of its immediate dependents' levels and
      its incoming declarations, until nothing changes. *"The project is the
      root of the graph and is not lowered."*
    - `findSecurityViolations` refuses two things: a dependency declared above
      its declarer's level, and a Maven or JAR dependency below
      `unrestricted`.
  - `docs/CHANGELOG.md`: *"Version 0.66.0: Package Manager: Added support for
    security trust levels"*.
- [`flix/book@687ccf7c6bd6a9872568c4dd8b2def7a7665c614`](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/trusting-dependencies.md)
  `src/trusting-dependencies.md`. It covers:
  - the three contexts;
  - per-dependency `security` in the consumer's manifest;
  - transitivity, and the most restrictive context for a shared package;
  - *"Our own code is always unrestricted"*;
  - the warning that *"Even building or compiling code that includes
    `unrestricted` dependencies can by itself expose us to a supply-chain
    attack"*;
  - the core/handlers library split.
- [`flix/museum@bfccaed599572a533db10a713834695b9bda9889`](https://github.com/flix/museum/blob/bfccaed599572a533db10a713834695b9bda9889/README.md)
  `README.md`. It quotes both violation messages verbatim: a Maven dependency
  of `museum-restaurant` under `plain`, and a dependency that `museum` declares
  `unrestricted` while `museum` itself was given only `plain`.

Kofun takes Flix's per-dependency grant, default, propagation, root rule, and
library split.

It does not take the `IO` axis (answer 2). It also moves where `plain` is
enforced. Flix builds a dependency's code under its context, so the compiler
refuses Java interop in a `plain` package. Kofun checks KIF bytes at
resolution, before any compilation (answer 6).

## The decision

The decision owner accepted these answers as written. Each is quoted from the
proposal. The sections after this one state them as target semantics.

1. **Adopt now.** *"Add the grant to the manifest schema before the first
   source-package manifest exists. Flix had to add security contexts to
   manifests that already existed (0.66.0). Kofun has no source-package
   manifests yet, so adopting now costs no migration."*
2. **(a) Two levels: `plain` and `foreign`. Defer `pure`.**
   - *"Kofun passes authority as values (RFC-0014), so Flix's `paranoid` ban
     on `IO` buys little here. Environment, process, and directory access
     already need a value the caller hands over. The only ambient `io` root is
     `print`."*
   - *"A `pure` level would rest on effect facts that are not sound until #1711
     lands."*
   - *"It would also refuse a dependency for logging."*
   - *"Revisit after #1713."*

   `plain` means no `trust raw-foreign` module, no `extern "C"` declaration,
   and no native artifact. `foreign` permits all three. These are the
   issue's candidate (a).
3. **Flix's propagation rule.**
   - *"The grant applies transitively."*
   - *"A shared package gets the most restrictive grant requested (meet)."*
   - *"No package can grant a dependency more than it was given itself."*
   - *"The grant is **orthogonal** to RFC-0012. The grant decides whether a
     package may *contain* a `trust raw-foreign` module, an `extern "C"`, or a
     native artifact. RFC-0012 decides who inside the package may *name* one.
     Neither replaces the other."*
4. **Default `plain`.**
5. **The package being built is always `foreign`.** *"It is your own code."*
6. **Checked at resolution time, from KIF module-trust bytes, without
   source.** *"This matches the native-toolchain contract's 'source-free
   dependency build from KIF and package artifacts'. KIF already carries
   `ordinary` / `raw-foreign` (`task kif-module-trust-profile`). The RFC picks
   the diagnostic band, as a package-resolution band."*
7. **A native artifact requires an explicit `foreign` grant, starting with
   `format = 2`.**
   - *"`format = 1` keeps its meaning. It has no transitive resolution, and
     only the root declares artifacts, so escalation is impossible there."*
   - *"A `format = 2` `static-library` entry with no `foreign` grant is
     refused. It is not grandfathered, in the spirit of RFC-0012 §4: 'an
     artifact missing the tag is never grandfathered'."*
8. **Yes.** *"Record the split as package guidance in
   `docs/STANDARD_LIBRARY_CHARTER.md` or `package/README.md`. A core package
   takes authority values and is `plain`. A separate adapter package holds the
   raw-foreign façade and is `foreign`."*
9. **Record an invariant instead of a grant rule.**
   - *"Building a dependency never executes its foreign code."*
   - *"Law evaluation, macros, and type-level reduction run under the
     empty-effect sandbox (`docs/LAW_SYSTEM.md`)."*
   - *"There are no package-provided build steps (`package/README.md`
     § Current boundary)."*
   - *"So the grant constrains what a package may contain, never what the
     build runs."*

## Detailed design

### 1. Two levels

A grant is exactly one of two values, ordered `plain < foreign`.

| Level | `trust raw-foreign` module | `extern "C"` declaration | native artifact |
|---|---|---|---|
| `plain` | forbidden | forbidden | forbidden |
| `foreign` | permitted | permitted | permitted |

The set is closed. An unknown value is refused. It is never read as either
level, for the same reason RFC-0012 §1 refuses an unknown trust class: a value
the resolver does not understand may not be treated as absent.

`plain` restricts no effect. A `plain` package may reach `print` and be `io`
under `spec/effects/pure-io-v1.md`. It may also take RFC-0014 authority values
that its caller hands it.

### 2. Where a grant is written

A grant is a property of a **dependency edge**, written by the consumer:

- It sits on the consumer's entry for that dependency in
  `kofun.packages.toml`. A dependency never declares its own grant, and no
  manifest field grants the package being built anything.
- It exists only from `format = 2`. In `format = 1` a grant is refused, as any
  unknown manifest syntax is today.
- An absent grant is `plain` (answer 4). The one exception is a native-artifact
  entry, which needs an explicit `foreign` (§5).
- Its values are spelled exactly `"plain"` and `"foreign"`.

The accepted answers fix this shape, not the key's spelling. The manifest-field
implementation issue chooses the key, within the constraints above. The first
source-package manifest carries the grant (answer 1). Nothing else about
`format = 2` is decided here.

### 3. Propagation

Write `g(u → d)` for the grant written on the edge from consumer `u` to
dependency `d`, `plain` when absent. Write `meet` for the minimum under
`plain < foreign`. The **effective grant** of every package in the resolved
graph is defined as follows:

- The root `r`, the package being built, is `foreign` (answer 5).
- For every other package `d`, `effective(d)` is the meet, over every edge
  `u → d` into it, of `meet(g(u → d), effective(u))`.

This is what *"applies transitively"* and *"most restrictive grant
requested"* mean (answer 3):

- A package's effective grant is never above any consumer's.
- A package reached along several paths takes the lowest grant of those paths.

A grant does not flow down by default. A dependency of a `foreign` package is
`plain` unless that package's own manifest grants it `foreign`. This matches
Flix, where every declaration without a `security` key is `plain`
(`ManifestParser.scala`) and the level is a fixpoint over all incoming
declarations and dependents (`minSecurityLevels`).

Effective grants are computed the way Flix computes its levels, so the
definition is total even if the graph has a cycle. Every package starts at
`foreign`. Each round lowers a
package to the meet of its incoming grants and its consumers' current levels.
The root is never lowered. A round never raises a level, so the computation
ends. Whether a Kofun package graph may contain a cycle is not decided here.

**No escalation.** An edge `u → d` with `g(u → d) = foreign` is refused when
`effective(u) = plain`. The edge is refused, not silently lowered. This is
Flix's `checkGraphErrors`, and the `museum` README shows the message it
produces.

### 4. What `plain` excludes, and how it is checked

The resolver checks every package `d` with `effective(d) = plain`. Answer 6
fixes when and from what: at resolution time, from KIF module-trust bytes, and
without source.

- **No `trust raw-foreign` module.** Every module that `d` contributes to the
  build has a KIF whose required tag `0x800A` is exactly `ordinary`. A
  `raw-foreign` value is refused. A missing or unknown value is already
  RFC-0012/A01's rebuild-required rejection, and this RFC adds nothing to it.
- **No `extern "C"` declaration.** This needs no separate fact. `E2S174`
  refuses an `extern "C" fn` in any module that does not declare
  `trust raw-foreign`. So an `ordinary` module contains no `extern "C"`, and
  the previous check covers this one.
- **No native artifact.** This is a manifest fact, and §5 and the escalation
  rule enforce it.

The check reads no source, runs no dependency code, and happens before any
module of the dependency is compiled into the consumer.

A façade is the case that distinguishes this check from RFC-0012. RFC-0012
deliberately makes a raw module invisible behind its façade. The grant check
sees the raw module anyway, because it reads the module's own KIF rather than
the façade's interface.

### 5. Native artifacts and manifest formats

In `format = 1`, nothing changes:

- `kind = "static-library"` stays the only kind.
- Only the root declares artifacts.
- No grant is read or accepted.

Answer 7 gives the reason. There is no transitive resolution, so no package
other than the root, which is always `foreign`, can bring in an artifact.

In `format = 2`, a native-artifact entry carries an explicit `foreign` grant:

- An entry with the grant absent is refused.
- An entry whose grant is `plain` is refused.
- Neither case is grandfathered (answer 7).

Combined with the escalation rule, only a package whose effective grant is
`foreign` can declare a native artifact. So the case Flix reports separately,
a Maven or JAR dependency in a `plain` package, never needs its own check
here:

- a `plain` package's artifact entry lacks `foreign`, and §5 refuses it; or
- it writes `foreign`, and §3 refuses the escalation.

### 6. The build-time invariant

**Building a dependency never executes its foreign code** (answer 9). The grant
is therefore a rule about what a package may contain. It is never a rule about
what the build runs.

The evidence, mechanism by mechanism, measured on
`7d2caf6f3fa3bf733533b08ccf20b6551c3e13f0`:

| Build-time mechanism | Accepted text | What it permits |
|---|---|---|
| law evaluation | `docs/LAW_SYSTEM.md` § *Compile-time sandbox and `standard-v1`*; DD-016–DD-018 | an empty effect set: *"The empty-effect rule denies … file/network/process access, FFI, async work, and global mutation. Capability possession does not override the rule."* |
| type-level reduction | RFC-0008 § *Ownership and effects* | *"Type-level reduction is pure"*; a type function has *"no reflection, effects, or I/O"* |
| macros and compile-time functions | DD-013 → `docs/METAPROGRAMMING.md` § *Sandboxing*, § *Stage 0* | a default sandbox with no network, process, ambient filesystem, clock, or random. It may read manifest-declared input files. Execution is *"Unimplemented"* |
| package-provided build steps | `package/README.md` § *Current boundary* | none: *"no … install scripts, extraction, or package-provided build steps"* |
| linking a native artifact | `package/README.md` § *Fetch, use, and work offline* | the library is passed to the host linker as an ordinary argument. Linking does not run it |

The macro row does not match answer 9's wording exactly; see *Unresolved
questions*. It does not break the invariant today, because no macro executes.
Any future mechanism that runs dependency code during a build must keep the
invariant or come back to this decision. That includes a macro sandbox, a build
step, or an evaluator that admits a foreign call.

### 7. Orthogonality

**RFC-0012.** The two mechanisms answer different questions, and neither
replaces the other (answer 3).

- The grant decides whether a package may **contain** raw-foreign code. Its
  unit is a package edge, and the resolver checks it.
- RFC-0012 decides which module inside a package may **name** a raw module. Its
  unit is a module import, and the compiler checks it.

A `foreign` grant admits nothing into any module: an ordinary import of a raw
module is still `E2S171`. A `trusted import` never makes a `plain` package
acceptable. RFC-0012's §5 *"trust never forwards"* and its re-export refusal
are unchanged. This RFC reads RFC-0012's KIF tag and does not amend it.

**#1196.** The trusted-adapter entitlement descriptor admits one authority
crossing at one native symbol. It is internal: *"not a safe Kofun value,
public manifest grant, semantic sidecar fact, KIF record, or serializable
authority"*.

- The grant is public and admits no authority crossing. `E355` still refuses
  an authority passed through a default foreign boundary, inside a `foreign`
  package as anywhere else.
- If the package that owns the admitted adapter is a dependency, it declares
  `extern "C"`, so it needs a `foreign` grant like any other.

Neither mechanism implies the other.

**RFC-0014.** The grant creates, attenuates, and transfers no authority. A
`plain` package reaches the host only through `print` and through authority
values its caller hands it. That is the property RFC-0014 needs, and foreign
code was the remaining way around it.

## Semantics

A resolution is accepted when all of the following hold for the resolved graph
and the effective grants of §3:

1. every grant value is `plain` or `foreign`;
2. no `format = 1` manifest writes a grant;
3. every `format = 2` native-artifact entry writes `foreign` explicitly;
4. no edge `u → d` writes `foreign` while `effective(u) = plain`;
5. every module of every package whose effective grant is `plain` has a KIF
   whose `0x800A` is exactly `ordinary`.

Otherwise the resolution is refused, and nothing downstream of it runs.

The root package is always `foreign`. It is subject to RFC-0012 like every
other package, and to nothing in this RFC.

The grant is not an effect. It does not appear in signatures, effect facts,
typed sidecars, or KIF. It describes the package graph, not any value or
computation.

Deliberately left undefined:

- the rest of `format = 2`: source dependency kinds, versions, version
  selection, mounts or namespaces, and whether the graph may contain cycles;
- whether the lock file records grants. A lock is never a source of a grant:
  the manifest's grants are authoritative, and nothing in a lock can widen one;
- whether toolchain-shipped modules (standard-library charter tiers 2–4) are
  packages subject to grants;
- any level other than `plain` and `foreign`;
- any finer grant, such as one artifact without raw modules, or one
  dependency's subtree but not another's.

## Diagnostics

Every refusal below is new. Answer 6 places them in a **package-resolution
band**: the package resolver emits them before any compilation, and a refusal
publishes no lock file and no build output.

This RFC chooses the band's kind. It does not allocate its prefix or numbers.
Following RFC-0012's precedent, codes are allocated in
`tests/diagnostics/registry.tsv` at implementation time, by the diagnostics
implementation issue, within these constraints:

- **One prefix, owned by the resolver.** It is distinct from `E2S`, the Stage 2
  compiler's codes, and from the `E3xx`/`E4xx` design identities, because the
  emitter is not the compiler.
- **A registry phase for resolution.** The registry's phase vocabulary is
  closed: `compile|frontend|backend|runtime|host-io`
  (`tests/diagnostics/check.sh`). None of these is package resolution, so the
  diagnostics issue widens it or records why an existing phase is right.
- **Executable evidence.** Each code has a fixture owner, a fixture, and a
  golden, like every other registered code.
- **Deterministic reporting.** Reporting order does not depend on the order in
  which a manifest declares its dependencies.

| Situation | Refusal | Rests on |
|---|---|---|
| a grant value other than `plain` or `foreign` | refused; never read as either level | answer 2 |
| a grant written in a `format = 1` manifest | refused, as unsupported manifest syntax is today | answer 7 |
| a `format = 2` native-artifact entry whose grant is absent or `plain` | refused; the remedy names `foreign` | answer 7 |
| an edge granting `foreign` from a package whose effective grant is `plain` | refused, naming the package, the edge, and the path from the root that made it `plain` | answer 3 |
| a package whose effective grant is `plain` with a module whose KIF `0x800A` is `raw-foreign` | refused, naming the package, the module's `ModuleId` and display path, and the path from the root | answers 3, 6 |
| a dependency module's KIF with `0x800A` missing or unknown | RFC-0012/A01's rebuild-required rejection; no new code | RFC-0012/A01 |

Each message names:

- the package, by identity and source;
- the grant it has and the grant it would need;
- the path of edges from the root that produced its effective grant;
- the remedy.

A remedy that raises a grant to `foreign` says what that permits: the
dependency, and everything it depends on, may run native code with no Kofun
authority. Flix's messages carry the same warning: *"Increase security level.
WARNING: This can be dangerous and may expose you to supply chain attacks."*

## Ownership and effects

There is no interaction with `read`/`edit`/`take` or with affine resources. A
grant classifies a package edge. It does not classify a value or a computation,
and it carries no obligation into any signature.

The grant also has no interaction with the effect discipline:

- `plain` restricts no effect, and `foreign` grants no authority.
- Effect facts are not consulted. That is why the `pure` level is deferred:
  #1711 shows the current facts are not yet sound (answer 2).

## Alternatives

**Defer to a named issue.** Rejected (answer 1). There are 0 tracked manifests
today. Deferring until source-package manifests exist would repeat Flix 0.66.0,
which had to give every existing manifest a default.

**Three levels, adding `pure` (candidate (b)).** Deferred (answer 2). It would
rest on `pure`/`io` facts that #1711 shows are not yet sound. It would also
refuse a dependency that only logs.

**Flix's three contexts on Flix's axes.** Rejected (answer 2). `paranoid`
forbids `IO` because in Flix `IO` is ambient authority. In Kofun, authority is
a value (RFC-0014) and the only ambient `io` root is `print`.

**An amendment to RFC-0012.** #1712 offered this. Not chosen, because the two
mechanisms are orthogonal (answer 3). Folding containment into a module-naming
rule would make one of them read as the other.

**Check at compile time instead.** Rejected (answer 6). The native-toolchain
contract asks for a *"source-free dependency build from KIF and package
artifacts"* (`spec/native-toolchain-v1/contract.json`), and KIF already carries
the fact.

**Grandfather native artifacts in `format = 2`.** Rejected (answer 7), in
RFC-0012/A01's spirit. A default that silently grants native code is the
downgrade the explicit grant exists to prevent.

**A grant rule for build-time execution.** Rejected in favor of an invariant
(answer 9). No build step runs dependency foreign code, so there is nothing for
a rule to constrain.

**Do nothing.** Rejected. Once source packages exist, any dependency could
contain raw-foreign code behind a façade, and RFC-0012 makes that invisible by
design.

## Drawbacks

**Ceremony.** Every native artifact in `format = 2` must write `foreign`, even
in a manifest whose only dependencies are native artifacts.

**Coarseness.** `foreign` admits all three forms, and it is the ceiling for the
whole subtree below that package. A consumer cannot grant one native artifact
without also permitting raw modules.

**Non-local failure.** The meet makes a shared package's grant depend on every
path to it. Adding an unrelated `plain` path to a package can lower its
effective grant, and then a graph that resolved before is refused. Flix has
the same property. The diagnostic's path from the root exists to make the
cause visible.

**The check is as strong as the KIF it reads.** KIF is a build output.

- When the consumer's own toolchain built a dependency's KIF from its source,
  `0x800A` is the compiler's statement.
- If prebuilt KIF were ever accepted from a publisher, the bytes would be the
  publisher's claim.

This RFC does not decide whether prebuilt KIF is accepted, or how KIF is bound
to its source.

**No effect guarantee.** A `plain` dependency can still print, and can use any
authority it is handed. The grant closes the native bypass. It does not make a
dependency harmless.

## Compatibility and migration

`additive`. No tracked program or manifest changes meaning, and none stops
resolving or compiling.

```sh
base=7d2caf6f3fa3bf733533b08ccf20b6551c3e13f0
git ls-tree -r --name-only "$base" | grep -c 'kofun.packages.toml$'
# 0
git grep -h -o -E 'format = [0-9]+' "$base" -- '*.sh' '*.md' '*.toml' | sort | uniq -c
#       7 format = 1
```

No tracked manifest exists. The seven `format = 1` spellings are:

- the resolver's own parser and lock writer: five in `package/manager.sh`;
- its README example: one in `package/README.md`;
- the manifest `tests/package_manager.sh` writes: one.

No tracked file spells `format = 2`.

- **`format = 1` keeps its exact meaning.** A grant written in it stays refused
  as unsupported syntax, as it is today.
- **Grants exist only in `format = 2`.** The current resolver refuses that
  format outright.
- **Nothing acquires a default it could fail.** There are no source packages,
  so no dependency acquires a `plain` default.
- **Root programs are unaffected.** The package being built is always
  `foreign`. That covers `kofun build --package` and every root C ABI program
  that declares `extern "C"`.
- **KIF is unchanged.** The check reads RFC-0012's existing required tag
  `0x800A` and adds no tag, so no artifact rebuilds.

Migration: none today. A manifest that later moves from `format = 1` to
`format = 2` writes `foreign` on each native-artifact entry.

## Implementation plan

Acceptance commits to no schedule. Three implementation issues carry the work,
each with its own gate:

1. **The manifest field.** This covers:
   - `format = 2`;
   - the grant key and its closed values;
   - the explicit-`foreign` rule for native artifacts;
   - an unchanged `format = 1`.

   It lands in the resolver that `bin/kofun package` runs at the time.
2. **The resolver/KIF check.** This covers:
   - effective grants;
   - the escalation refusal;
   - the `0x800A` check over every module of every `plain` package.

   It needs source-package resolution. No issue owns that yet. When an issue
   is filed for it, that issue becomes this check's blocker.
3. **The diagnostics.** This covers:
   - the package-resolution band;
   - its registry phase;
   - a registered code with executable evidence for every refusal in
     *Diagnostics*.

The core/adapter guidance of answer 8 is recorded in `package/README.md` with
this RFC. It is not an implementation step.

## Validation

This document is checked by `task rfc-registry`. It records no `implementation`
in the ledger, because nothing is implemented.

The implementation issues own the executable gates:

- **The manifest field: `task packages`, extended.**
  - A `format = 1` lock stays byte-identical.
  - A `format = 2` native artifact is refused without `foreign` and accepted
    with it.
  - An unknown grant value is refused.
- **The resolver check: a gate it adds.**
  - **The façade fixture.** A dependency whose only foreign code is a
    `trust raw-foreign` module behind an ordinary façade must be refused under
    `plain`, with the dependency's source absent and only its KIF present. A
    version of the gate that omits this fixture proves nothing this RFC adds.
  - **The escalation fixture.** It mirrors `museum` → `museum-restaurant`.
- **The diagnostics: `task diagnostics`.** Every code is registered with its
  fixture and golden.

Existing gates that must stay green: `task kif-module-trust-profile`,
`task raw-imports`, `task raw-re-exports`, `task packages`, and
`task rfc-registry`.

## Unresolved questions

- **The manifest key's spelling.** Left to the manifest-field issue (§2). One
  consideration it must weigh: RFC-0012 already uses `trust` and `trusted` for
  the orthogonal module mechanism.
- **The band's prefix and numbers.** Left to the diagnostics issue
  (*Diagnostics*).
- **Source-package resolution.** No issue owns it at the audited commit.
  `format = 2`'s source dependency kind, versions, and transitive graph are a
  separate decision. The resolver check cannot start before it.
- **Macros and answer 9.** Answer 9 groups macros with law evaluation under
  *"the empty-effect sandbox (`docs/LAW_SYSTEM.md`)"*. The accepted macro text
  (DD-013, normative spec `docs/METAPROGRAMMING.md` § *Sandboxing*) is a
  different sandbox:
  - it admits manifest-declared input files;
  - it does not name FFI.

  The invariant holds today because no macro executes. This RFC does not
  amend DD-013. Whether the macro sandbox must deny foreign calls explicitly
  is for the decision owner. Settled when DD-013 is amended, or when macro
  execution is implemented.
- **Native Core syscall intrinsics.** The native Core profile recognizes
  `__linux_syscall0`–`__linux_syscall6` at any call site
  (`bootstrap/native/README.md` § *Linux syscall intrinsics*). They reach the
  kernel without an authority value, and they are none of this RFC's three
  forms. No package can reach them today:
  - native Core has no import path;
  - Stage 2, which produces KIF, recognizes no such intrinsic.

  The measurement: `git grep -c '__linux_syscall' -- bootstrap/stage2` finds
  nothing (exit 1). Whether `plain` forbids them is open until a
  package-consuming compiler exposes them.
- **The `pure` level.** Answer 2 defers it until after #1713.
  - #1713 closed on 2026-10-04 with `docs/research/callable-effects.md`, which
    does not discuss a package-level grant.
  - #1711, on which the soundness of the effect facts depends, is open.

  A third level is a further decision. The refusal of unknown values keeps it
  from being made by accident.
- **Prebuilt KIF and toolchain-shipped modules.** See *Drawbacks* and
  *Semantics*.

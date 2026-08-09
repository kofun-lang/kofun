# RFC-0002: Environment access requires attenuated affine authority

- Shepherd: hjosugi
- Opened: 2026-08-02
- Status: proposed

Proposal for [#569](https://github.com/kofun-lang/kofun/issues/569). Review opened with the ledger's announced window; it closes when the
shepherd closes it, and the ledger records that day. This document
specifies target semantics only. It does not claim that the compiler,
runtime, standard library, package tooling, or documentation generator
implements them.

## Summary

Safe Kofun code may read a process environment value only by presenting an
opaque affine `EnvironmentAuthority` whose finite key set contains the
requested key. The runtime creates the program's sole `RootAuthority`; code
holding that root may derive an environment authority, monotonically reduce
it, partition it into disjoint children, borrow it for a read, or transfer it
with `take`. It may never copy, widen, serialize, forge, or recover the
authority. `Environment.get` remains an `io` operation: possession answers
"may this caller read this key", while the effect row answers "may this
function interact with the environment". Both conditions are required and
receive different diagnostics. Package metadata and generated documentation
make requested authority auditable but grant nothing. Trusted runtime and FFI
code remain an explicitly reported escape boundary.

## Motivation

Kofun already says two things that an environment API must preserve.
[`docs/STANDARD_LIBRARY_CHARTER.md`](../docs/STANDARD_LIBRARY_CHARTER.md)
forbids ambient authority, and [`docs/TYPE_SYSTEM.md`](../docs/TYPE_SYSTEM.md)
models external interaction with an inferred effect row. An ordinary
`Environment.get(key)` API guarded only by `io` would satisfy the second and
violate the first: every dependency allowed to perform any I/O could also read
credentials, service tokens, or deployment configuration from every process
environment key.

An effect and an authority answer different questions:

| Fact | Question | Example |
|---|---|---|
| effect row | what may this function do? | `Environment.get` contributes `io` |
| authority value | what may this caller access? | this value grants only `API_HOST` |

Neither implies the other. A pure function may carry an unused authority
without becoming impure. An `io` function with no environment authority may
perform some other I/O but cannot read any environment key. Supplying an
authority does not remove `io` from `Environment.get`, and admitting `io`
does not manufacture an authority.

The current repository makes the absence concrete. At
`e270143665789e452495ea1bdf13e17db9bbf779`, the compatibility query in
§Compatibility and migration finds no safe `RootAuthority`, environment
authority, or capability-gated environment API. The general `read`/`edit`/
`take` model is also target design, not a shipped compiler guarantee, as
[`docs/MEMORY_MODEL.md`](../docs/MEMORY_MODEL.md) §13 records. This RFC must
therefore settle one implementable contract without turning design prose into
a capability claim.

Austral is useful prior art, not a surface to copy mechanically. Its
[capability tutorial](https://austral-lang.org/tutorial/capability-based-security)
uses an unforgeable linear root passed to the entrypoint, derives an opaque
environment capability by borrowing the root, and requires a capability
borrow at each access. Its
[specification](https://austral-lang.org/spec/spec.html) makes the root a
linear built-in value and treats unsafe FFI as outside the capability
discipline. Kofun adopts explicit derivation, non-forgeability, and value-level
delegation. It adapts them to Kofun's affine cleanup and parameter modes, and
adds key-set attenuation so a dependency need not receive authority over the
entire environment.

## Detailed design

### Authority types

This proposal adds three opaque public types to the target language model:

```kofun
opaque affine RootAuthority
opaque affine EnvironmentAuthority
opaque EnvironmentKey
```

Their rules are:

- `RootAuthority` is created exactly once by the runtime for a program
  invocation and transferred to that program's entrypoint. Safe source has no
  constructor for it. The root is affine, non-copyable, non-comparable,
  non-hashable, and non-serializable.
- `EnvironmentAuthority` is an affine handle to an immutable finite set of
  canonical `EnvironmentKey` identities. Its representation, set, and runtime
  identity are opaque. It has no public field, literal, cast, reflection,
  decode, or raw-handle constructor.
- `EnvironmentKey` is an unrestricted validated name, not an authority. It can
  be copied and serialized; knowing a key never grants access to its value.
- A record, union, tuple, closure, or collection containing an authority is
  itself affine by containment. An authority cannot be hidden in an
  unrestricted container.
- Root authority is the common source of resource-specific authority, but this
  RFC defines only environment derivation. It does not define or change the
  allocator authority proposed by RFC-0001, filesystem or network authority,
  or a generic `IOCapability`.

The target entrypoint shape is conceptually:

```kofun
fn main(take root: RootAuthority) -> ExitCode
```

The exact entrypoint grammar is a later compiler artifact. The semantic fact
fixed here is that the runtime transfers one root to the entrypoint and safe
code has no second creation path.

### Portable environment keys

Version 1 deliberately accepts a conservative portable key profile:

```ebnf
environment_key = ( "A" | ... | "Z" | "_" ),
                  { "A" | ... | "Z" | "0" | ... | "9" | "_" } ;
```

A key contains 1 through 255 ASCII bytes. There is no case folding, Unicode
normalization, prefix, glob, or wildcard form. `EnvironmentKey.parse(text)`
returns `Err(InvalidEnvironmentKey)` for anything outside that profile. This
means names such as `Path`, non-ASCII names, names containing `=`, and empty
names are unsupported in the safe v1 API even where a host operating system
accepts them. The restriction prevents platform-specific name aliasing from
turning a narrow grant into a wider one; a later portable-key amendment may
expand it only with an equally precise canonical identity rule.

Within a set, keys are ordered by ascending ASCII byte sequence. Repeated
keys are rejected as `DuplicateEnvironmentKey`; they are never silently
deduplicated. The empty set is valid and represents an authority that cannot
read any key. One authority contains at most 256 keys; a longer input is
rejected as `EnvironmentAuthorityKeyLimitExceeded` before duplicate or subset
checking. A set of keys is data supplied to a derivation operation; no source
syntax creates an authority literal.

### Creation and derivation

The conceptual safe surface is:

```kofun
fn Environment.authorize(
    edit root: RootAuthority,
    read keys: List[EnvironmentKey],
) -> Result[EnvironmentAuthority, EnvironmentGrantError]

fn Environment.restrict(
    take authority: EnvironmentAuthority,
    read keys: List[EnvironmentKey],
) -> Result[EnvironmentAuthority, EnvironmentAttenuationFailure]

record affine EnvironmentPartition {
    delegated: EnvironmentAuthority,
    remainder: EnvironmentAuthority,
}

fn Environment.partition(
    take authority: EnvironmentAuthority,
    read delegated_keys: List[EnvironmentKey],
) -> Result[EnvironmentPartition, EnvironmentAttenuationFailure]

fn Environment.get(
    read authority: EnvironmentAuthority,
    read key: EnvironmentKey,
) -> Result[Option[Text], EnvironmentReadError] ! {io}
```

These signatures are target-design notation. Landing this RFC does not add
them to the current standard library.

Let `keys(a)` be the hidden finite set carried by authority `a`.

1. `authorize(edit root, K)` validates `K`, records a new environment grant
   under the runtime root, and returns a fresh live authority `a` with
   `keys(a) = K`. The `edit` borrow lets one root issue more than one resource
   authority while serializing issuance and its audit identity. It does not
   transfer or duplicate the root. Only code already holding the root may
   choose an arbitrary initial environment set.
2. `restrict(take a, S)` succeeds only if `S ⊆ keys(a)`. It consumes `a`,
   returns a fresh authority over exactly `S`, and permanently discards
   `keys(a) − S`. It does not provide a remainder. On a dynamic validation
   error it returns ownership of the original authority in the error variant,
   so a failed attempt cannot destroy authority accidentally.
3. `partition(take a, D)` succeeds only if `D ⊆ keys(a)`. It consumes `a`
   and returns two fresh authorities: `delegated` over exactly `D`, and
   `remainder` over exactly `keys(a) − D`. The two sets are disjoint and their
   union equals the consumed set. Input order cannot change either result.
   Empty `D` and `D = keys(a)` are valid.
4. Neither operation has an inverse. There is no union, merge, recover,
   broaden, parent lookup, or root lookup operation. Possessing two children
   does not permit construction of their union.
5. `get(read a, k)` is authorized exactly when `k ∈ keys(a)`. It reads only
   that host environment entry. An absent entry returns `Ok(None)`; a present
   valid UTF-8 value returns `Ok(Some(value))`; a present value that cannot be
   represented as `Text` returns `Err(InvalidEnvironmentEncoding)`. A dynamic
   key outside the grant returns `Err(UnauthorizedEnvironmentKey)` without
   consulting the host environment.

`EnvironmentGrantError` is a closed unrestricted error with
`DuplicateEnvironmentKey` and
`EnvironmentAuthorityKeyLimitExceeded { limit, actual }` variants.
`EnvironmentAttenuationReason` adds `AttenuationWouldWiden` to those two
reasons. A failed `restrict` or `partition` returns the unchanged input
authority in an affine `EnvironmentAttenuationFailure { authority, reason }`,
so validation cannot destroy authority accidentally. Validation order is
key-count limit, duplicate detection in canonical key order, then subset
membership. `EnvironmentReadError` is a closed typed error with
`UnauthorizedEnvironmentKey` and
`InvalidEnvironmentEncoding`. These are anticipated data-dependent results,
not compiler diagnostics.

Derivation, attenuation, partition, transfer, and cleanup do not inspect or
modify the host environment and do not contribute `io`. `get` does, even when
the requested key is absent or refused. An implementation must perform the
authority membership check before the host lookup, so an unauthorized caller
cannot use timing or encoding errors to distinguish whether the key exists.

### Borrowing, transfer, and cleanup

The target affine states are precise enough to implement independently:

| State | Permitted operation | Next state | Rule |
|---|---|---|---|
| `live(K)` | `read` borrow for `get` or a non-escaping call | `live(K)` after the borrow | any number of non-conflicting read borrows; no transfer or cleanup while borrowed |
| `live(K)` | `take` into a callee, package, callback, or one task | caller becomes `moved`; callee owns `live(K)` | ownership is transferred exactly once |
| `live(K)` | `restrict(take, S)` | old value `moved`; result `live(S)` | requires `S ⊆ K`; `K − S` is destroyed |
| `live(K)` | `partition(take, D)` | old value `moved`; results `live(D)` and `live(K − D)` | results are disjoint and exhaustive |
| `live(K)` | lexical cleanup or explicit drop | `dropped` | destroys the handle; it does not alter the environment |
| `moved` or `dropped` | borrow, transfer, attenuate, partition, or drop again | refusal | no operation can recover a live value |

An authority may cross a package boundary only as an explicit `read`, `edit`,
or `take` parameter/result. Package imports convey no authority. A synchronous
callback may receive a `read` borrow whose lifetime is bounded by that call,
or may take ownership. An escaping callback may not capture a borrow; it must
take and thereby become an affine closure. A task may receive one transferred
authority, or a scoped read borrow if every use and the join complete before
the borrow ends. The parent cannot use a transferred value unless the task
returns ownership at its typed join. These rules do not claim that the current
compiler implements general closure or task ownership checking.

Cleanup is deterministic under Kofun's target affine model on normal return,
`Result` propagation, and other structured exits. Cleanup only invalidates the
authority handle and releases its runtime bookkeeping. Dropping the root stops
future derivation but does not revoke already-issued child authorities.
Dropping a parent after partition is impossible because the parent was
consumed. Process abort and trusted-runtime failure do not promise user-level
cleanup, and this RFC adds no finalizer or revocation mechanism.

The returned `Text` is an ordinary managed value. Authority controls the act
of reading; this proposal is not an information-flow type system. Code that
was deliberately given `API_TOKEN` authority may return, log, or transmit the
value if it separately holds the required authority and effects for those
operations. Such leakage is a review and policy concern outside this v1
contract.

### Worked disjoint-dependency example

The application, and only the application, starts with root authority. It
derives one bounded environment grant, then consumes it into disjoint pieces:

```kofun
fn main(take root: RootAuthority) -> ExitCode ! {io} {
    let api_host = EnvironmentKey.parse("API_HOST")?
    let db_url = EnvironmentKey.parse("DB_URL")?

    let all = Environment.authorize(edit root, [api_host, db_url])?
    let split = Environment.partition(take all, [api_host])?

    let api_result = ApiDependency.run(take split.delegated)
    let db_result = DbDependency.run(take split.remainder)
    return combine(api_result, db_result)
}
```

The resulting facts are:

| Dependency | Authority set | Allowed | Refused |
|---|---|---|---|
| `ApiDependency` | `{API_HOST}` | `get(API_HOST)` | `get(DB_URL)`, widening to `DB_URL`, serializing or copying the authority, recovering `all` or `root` |
| `DbDependency` | `{DB_URL}` | `get(DB_URL)` | `get(API_HOST)`, widening to `API_HOST`, serializing or copying the authority, recovering `all` or `root` |

The proof is structural, not a package-manager promise. `partition` consumes
`all`, the child sets are disjoint by construction, neither dependency
receives root, opaque types prevent construction, and no widening or union
operation exists. Even if either package metadata asks for both keys, the
runtime operation still checks the actual value it received.

### Package metadata and generated documentation

A package may declare the maximum authority it expects a host to consider:

```toml
[capabilities]
environment-read = ["API_HOST", "DB_URL"]

[[capability-attenuation]]
dependency = "api-dependency"
kind = "environment-read"
keys = ["API_HOST"]

[[capability-attenuation]]
dependency = "db-dependency"
kind = "environment-read"
keys = ["DB_URL"]

[trusted]
capability-bypasses = []
```

`environment-read` uses the same key grammar, canonical ordering, uniqueness,
and 256-key bound as runtime key sets. Each `capability-attenuation` entry names
a direct locked dependency identity, a resource kind, and a subset of the
application's declared key set. Entries for one dependency/kind pair are
unique; their keys are canonical and must be a subset of the application row.
Both forms are audit declarations, not grants, implicit parameters, or proof
that every listed key is needed. A host may deny the package, grant a stricter
subset, or never call the relevant API. Omitting either form grants nothing.
The package manager must not synthesize, partition, or pass an authority from
this text; application source still performs the value-level derivation and
transfer.

Generated package and API documentation presents the declaration separately
from the compiler-derived signature:

```text
Requested authority (audit declaration; not a grant)
  Environment read: API_HOST, DB_URL

Declared attenuation plan (audit declaration; not a grant)
  api-dependency: Environment read: API_HOST
  db-dependency: Environment read: DB_URL

Value-level enforcement
  Explicit EnvironmentAuthority parameter required

Trusted bypasses
  None declared
```

For a native package that bypasses the safe API, `capability-bypasses` lists
`environment-read`, and generated documentation labels it **trusted native
bypass; not enforced by Kofun authority values**. The manifest and generated
view make review, organization policy, and dependency inspection possible;
only possession of an unforgeable live value authorizes safe Kofun code.
No package-manager or documentation-generator implementation is part of this
RFC issue.

### Trusted runtime and FFI boundary

Authority objects never cross the default C ABI as bytes, integers, raw
pointers, or serializable records. A default safe foreign declaration cannot
return `RootAuthority` or `EnvironmentAuthority`, cannot construct either from
an address, and cannot accept an authority in an ABI-safe slot.

A trusted runtime adapter may expose a Kofun-facing function with an explicit
authority parameter. The Kofun caller transfers or borrows the opaque token;
the adapter receives only an internal checked entitlement, not a forgeable ABI
representation. The adapter declaration must report:

- capability kind and operation (`environment-read`);
- whether it borrows or takes the authority;
- the native symbol and owning package;
- whether the native side can access environment state without the checked
  entitlement; and
- the review/evidence identity for that trusted bypass.

Trusted native code can still call the operating system directly and ignore
all of these rules. The type system cannot prevent that. Such code is outside
the safe sandbox and must appear in package metadata and generated trusted-
surface documentation. Marking it trusted does not make it safe, and bytes
returned by FFI can never be decoded into an authority. This is an honest
boundary, not a claim of FFI sandboxing.

## Semantics

Let `R` be the unique runtime-created root for an invocation. Let an
environment authority be an unforgeable pair of runtime identity and hidden
finite key set, written `A[K]` only in this specification.

1. **Root creation.** Before invoking `main`, the runtime creates `R` and
   transfers it exactly once. No safe evaluation rule creates `R`.
2. **Environment derivation.** Given a live edit borrow of `R` and valid set
   `K`, `authorize` returns fresh `A[K]`. It preserves `R` after the borrow.
3. **Monotonic attenuation.** A transition from `A[K]` to a child `A[S]` is
   valid iff `S ⊆ K`. The only result sets of `partition(A[K], D)` are `D`
   and `K − D`. No safe transition increases a key set.
4. **Affine use.** `take` changes the source binding to `moved`. Cleanup
   changes a live binding to `dropped`. Neither state has a transition back
   to live. A read borrow temporarily prevents transfer, mutation, or cleanup
   and never creates a second owned authority.
5. **Authorization.** `get(read A[K], k)` may consult the environment iff
   `k ∈ K`. Membership refusal precedes the host lookup. The operation carries
   `io` whether the entry is present, absent, invalidly encoded, or refused.
6. **Orthogonality.** A call is well-formed only if its explicit authority
   argument is valid and the enclosing effect boundary admits `io`. One
   condition cannot discharge the other.
7. **Cleanup.** Destroying an authority destroys only its entitlement handle.
   It neither erases environment values nor revokes independent children.
8. **No implicit flow.** Import, package metadata, documentation, an `io`
   effect, a key string, deserialization, and safe FFI data grant no authority.

Deliberately undefined: the in-memory representation and identity width of an
authority; the storage structure used for key membership; audit-log transport
and retention; operating-system calls; process-environment mutation by
trusted code; revocation; environment writes; secret-taint tracking; and
authority kinds other than environment reads. Implementations may choose
these only without changing the rules above or observable diagnostics.

## Diagnostics

The proposal reserves `E350` through `E356`. They are adjacent to, but do not
renumber or change, RFC-0001's `E340` through `E344` allocator family.
Data-dependent failures described above remain typed `Result` values.

| Code | Refusal | Stable message shape |
|---|---|---|
| `E350` | an environment operation has no explicit authority argument in scope | `environment read requires an EnvironmentAuthority argument; io permission does not grant authority` and names the call |
| `E351` | a statically known `restrict` or `partition` set is not a subset of its parent | `environment authority cannot widen from {…} to {…}` and lists only source-written keys |
| `E352` | safe code constructs, casts, decodes, or obtains an authority from a non-authority value | `RootAuthority and EnvironmentAuthority are runtime-issued opaque values and cannot be forged` |
| `E353` | an authority is copied, serialized, compared, hashed, or stored in an unrestricted container | `EnvironmentAuthority is affine and non-serializable` and names the attempted operation |
| `E354` | code uses, borrows, transfers, or drops an authority after `take` or cleanup | `environment authority was already transferred` or `… already dropped`, with the consuming site |
| `E355` | an authority borrow escapes, or an authority crosses the default safe FFI ABI | names the return, capture, storage, task, callback, or foreign boundary and requires an explicit affine transfer or trusted adapter |
| `E356` | an otherwise authorized environment read reaches a boundary whose effect row excludes `io` | `environment read is impure; this boundary does not admit io` and names the boundary |

Diagnostic precedence for one call is deterministic:

1. parsing, name resolution, ordinary arity/type checking, and existing
   ownership errors are reported first;
2. forging, affine-state, attenuation, escape, and explicit-authority checks
   run next (`E351`–`E355`, then `E350`);
3. only a structurally valid, explicitly authorized operation is checked
   against the effect boundary (`E356`).

Therefore this source:

```kofun
pure fn load() -> Text {
    return Environment.get(EnvironmentKey.parse("API_TOKEN")?)?
}
```

first reports `E350`, not `E356`: the call has no authority. After the author
adds `read authority: EnvironmentAuthority` and supplies it, the same pure
boundary reports `E356`. An implementation may accumulate unrelated errors,
but it must not emit both codes for the same unresolved call or suggest that
adding `io` creates authority. If a literal key is outside a statically known
grant, `E351` precedes `E356`; a dynamic mismatch is
`Err(UnauthorizedEnvironmentKey)` at runtime and still carries `io`.

## Ownership and effects

- **`read`.** `Environment.get` and non-escaping callees borrow an authority
  without changing its key set or ownership. Concurrent read borrows are
  permitted only where the target ownership model proves their lifetime ends
  before transfer or cleanup.
- **`edit`.** Environment authority itself has no v1 edit operation because
  attenuation is consuming. `authorize` takes an edit borrow of the root so
  root-derived identity and audit issuance are exclusive without consuming
  the root.
- **`take`.** Delegation, return, task ownership, `restrict`, and `partition`
  transfer ownership. The source cannot be reused. Successful attenuation
  returns new owned values; a failed dynamic attenuation returns the original
  authority inside the error value.
- **Affine cleanup.** A live authority may be used zero or one ownership-ending
  times because Kofun is affine rather than Austral's exactly-once linear
  model. If it is not explicitly transferred or dropped, structured scope
  cleanup drops it once. Copying and double cleanup are forbidden.
- **Effects.** `Environment.get` contributes `io`. Local key parsing,
  authority derivation, attenuation, partition, transfer, and cleanup do not.
  Holding, borrowing, or passing an authority does not itself add `io`.
- **No implementation claim.** These interactions bind later implementations
  to the target model. The current bounded ownership and effect slices are not
  evidence that these rules ship.

## Alternatives

1. **Ambient environment access plus `io`.** Rejected. It classifies the
   operation but grants every dependency with any I/O permission access to
   every environment secret. It cannot express least privilege or disjoint
   delegation.
2. **One undifferentiated `IOCapability`.** Rejected. A caller that needs one
   environment key would also receive filesystem, network, process, clock, and
   future I/O authority. This recreates ambient authority in one explicit but
   overpowered token.
3. **Package-manifest declarations without value-level tokens.** Kept only as
   an audit surface and rejected as enforcement. Metadata is static intent;
   it does not identify the caller at a particular call, support borrowing or
   transfer, or prevent native and dynamically selected code paths from
   acting outside the declaration.
4. **Opaque but copyable tokens.** Rejected. Opacity prevents forging but
   copying defeats revocable ownership, disjoint delegation, deterministic
   cleanup, and review of who retained authority. A token copied before
   attenuation would preserve the wider grant indefinitely.
5. **Affine root and attenuated resource-specific capabilities.** Selected.
   It combines unforgeable provenance, explicit value flow, monotone key sets,
   disjoint partition, and deterministic cleanup while keeping effect
   inference orthogonal. Its cost is ownership ceremony at privileged
   boundaries and compiler/runtime work not yet implemented.
6. **No safe environment API; trusted FFI only.** Rejected as the permanent
   answer. It avoids overstating the type system but forces ordinary programs
   across an unauditable trust boundary for routine configuration, provides no
   least-privilege delegation among safe dependencies, and makes every use a
   native-security review. It remains the honest current boundary until later
   implementation gates pass.

Doing nothing is alternative 6 in practice: no safe API now, and no common
contract for later compiler, standard-library, package, and FFI work. The cost
of choosing this RFC is new affine/effect machinery; the cost of doing nothing
is either permanent ambient access or permanent trusted-native escape.

## Drawbacks

- The host must thread or borrow a value through dependency boundaries. This
  is deliberate ceremony, but it is still more code than an ambient getter.
- The conservative uppercase ASCII key profile cannot access every name an
  operating system may expose. Portability and non-aliasing win over breadth
  in v1.
- Affinity identifies ownership, not confidentiality. Once read, a secret is
  ordinary `Text`; preventing its later disclosure requires a different
  information-flow design.
- Root holders remain highly privileged and may issue overlapping grants.
  Partition proves disjointness only after a bounded parent is created; code
  review must keep root at the composition boundary.
- Runtime membership checks and entitlement identities have nonzero cost.
  The representation may optimize them but cannot erase the check.
- Trusted native code can bypass the model. Reporting narrows the lie; it does
  not sandbox FFI.
- The proposal depends on target affine cleanup and effect checking that the
  current compiler does not generally implement. Acceptance settles design,
  not delivery timing.

## Compatibility and migration

Classification: **additive**.

Everything named here is new target surface: `RootAuthority`,
`EnvironmentAuthority`, `EnvironmentKey`, the four `Environment` operations,
diagnostics `E350`–`E356`, manifest fields, and trusted-surface rendering.
There is no existing safe environment API to change, and this proposal does
not modify the allocator contract in RFC-0001.

Measured at `e270143665789e452495ea1bdf13e17db9bbf779`:

```sh
git grep -nE 'RootAuthority|Environment(Capability|Authority)|Environment\.(acquire|get)' -- '*.kofun' 'spec/**' 'stdlib/**'
# no output; exit 1

git grep -nE '\b(RootAuthority|EnvironmentAuthority|Environment\.authorize|Environment\.restrict|Environment\.partition|Environment\.get|E350|E351|E352|E353|E354|E355|E356)\b' -- '*.kofun' 'spec/**' 'stdlib/**'
# no output; exit 1

git ls-files '*.kofun' | wc -l
# 763
```

Thus zero of 763 tracked Kofun sources collide with the proposed type,
operation, or diagnostic names, and the exact current-boundary query returns
zero matches. Existing programs keep their meaning. There is no migration for
this RFC-only change. A future unsafe or ambient environment prototype, if one
lands before implementation, must migrate to an explicit authority parameter;
that later change would need its own compatibility measurement and cannot cite
this zero-match result as current.

## Implementation plan

Acceptance is not a commitment to a schedule. After acceptance, create
separate issues and do not add an RFC ledger `implementation` record or a
release capability claim until the relevant executable gates exist.

1. **Compiler authority model and diagnostics.** Add opaque affine capability
   identities, entrypoint root injection, parameter-mode checking, static
   attenuation facts, and `E350`–`E356`. Gate with one focused pass fixture and
   pinned compile-fail fixtures for forge, copy/serialize, widening,
   use-after-transfer, escape, missing authority, and effect mismatch. This
   issue must state exactly which general ownership/effect prerequisites it
   implements rather than borrowing historical claims.
2. **Runtime and environment standard library.** Add bounded root issuance,
   key validation, membership-before-lookup, derivation, partition, cleanup,
   invalid-encoding handling, and a deterministic injected environment
   provider for tests. Gate disjoint `API_HOST` / `DB_URL` reads and prove an
   unauthorized key never reaches the provider. Environment writes stay out
   of scope.
3. **Package audit metadata and generated docs.** Add schema validation for
   canonical unique keys and trusted bypass declarations, then render the
   three labeled sections from §Package metadata. Gate that deleting all
   metadata does not make a capability-taking program compile or run: the
   surface is audit only.
4. **Trusted adapter audit.** Define the internal entitlement ABI and require
   native symbol, mode, capability kind, and evidence identity. Gate default
   FFI rejections and one explicitly trusted adapter. The result is an audited
   boundary, not an FFI sandbox claim.
5. **Integration and release evidence.** Run the full repository gates, add
   normative spec text, and record implementation/release evidence only for
   the exact profiles proven. Acceptance alone never advances ledger state to
   `implemented`.

Filesystem, network, process, random, clock, environment writes, allocator
authority, revocation, and secret information-flow are independent proposals.

## Validation

This RFC issue is complete when the proposal and ledger validate. The later
behavioral rows are acceptance gates for the follow-up implementation issues,
not evidence produced here.

| ID | Gate or artifact | Required evidence |
|---|---|---|
| R1 | `node tests/rfc/validate-registry.mjs schema` | ledger schema passes |
| R2 | `node tests/rfc/validate-registry.mjs validate` | RFC-0002 is `proposed`, carries no closing or decision date while proposed, no implementation record, and valid compatibility evidence |
| R3 | `nix shell nixpkgs#go-task -c task rfc-registry` | focused registry gate passes without changing RFC-0001 |
| C1 | `accept_environment_partition.kofun` | root derives `{API_HOST, DB_URL}`; partition yields two disjoint children; each reads only its key |
| C2 | pinned forge/copy/serialize/widen/moved/escape negatives | each maps to the exact `E351`–`E355` code and message shape |
| C3 | missing-authority then pure-boundary pair | first source reports only `E350`; after authority is supplied it reports `E356` |
| R4 | injected environment-provider trace | unauthorized lookup is absent from the trace; absent, invalid UTF-8, and present values produce their specified typed results |
| M1 | manifest/schema/docs golden | sorted unique key request and trusted bypass render as audit declarations, never grants |
| F1 | default and trusted FFI pair | default ABI refuses authority crossing with `E355`; trusted adapter is listed with mode, symbol, kind, and evidence identity |

The threat model maps every required negative to one of those gates:

| Threat | Attempt | Safe result | Boundary/gate |
|---|---|---|---|
| forging | construct from bytes, address, reflection, cast, or fake record | `E352`; no public constructor | C2 |
| ambient access | call `Environment.get(key)` or rely on `io` alone | `E350`; no lookup occurs | C3, R4 |
| widening | restrict `{API_HOST}` to `{API_HOST, DB_URL}` or recover parent | `E351` when static; typed `AttenuationWouldWiden` when dynamic; no union operation | C2 |
| use after transfer | read or drop source after `take` | `E354`, naming transfer | C2 |
| serialization or escape | encode, copy, place in unrestricted container, or capture a borrow | `E353` or `E355` | C2 |
| FFI bypass | pass token through default ABI or native code reads environment directly | default ABI `E355`; direct native read is an explicitly reported trusted bypass | F1 |

No validation step executes user code, macros, network requests, subprocesses
from user programs, or ambient environment reads. Runtime tests use an
injected bounded provider. A future release claim must name the exact compiler,
runtime, standard-library, metadata, and FFI evidence it covers.

## Unresolved questions

No semantic question required by #569 is deliberately left open: the type
hierarchy, creation path, key algebra, borrow/transfer/cleanup states,
package/task/callback/FFI boundaries, diagnostic precedence, metadata role,
and compatibility category are decided above.

Representation, audit transport, revocation, environment writes, richer key
profiles, and information-flow tracking are explicitly unsupported rather
than silently implementation-defined. Changing any normative rule after this
RFC is accepted requires a ledgered amendment; before acceptance, review may
revise this proposed document.

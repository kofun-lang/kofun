# RFC-0014: Host operations use explicit bounded authorities

- Shepherd: hjosugi
- Opened: 2026-08-11
- Status: accepted
- Decided: 2026-08-11

This RFC closes the decision surfaces in
[#1241](https://github.com/kofun-lang/kofun/issues/1241),
[#1231](https://github.com/kofun-lang/kofun/issues/1231), and
[#1234](https://github.com/kofun-lang/kofun/issues/1234). It refines accepted
RFC-0002 and RFC-0004; it implements no compiler, syscall, or standard-library
capability.

## Summary

Kofun v1 uses compiler-known `RootAuthority`, `EnvironmentAuthority`,
`EnvironmentKey`, `ProcessAuthority`, and `DirectoryAuthority` types. Programs
receive root authority only through the exact opt-in entrypoint
`fn main(take root: RootAuthority) -> Int`; the existing zero-argument entrypoint
remains valid and receives nothing implicitly.

Environment access has structured known/unknown key facts and an assertive
`pure fn` boundary. Process execution names an approved absolute executable and
digest, never a shell or PATH search. Directory enumeration is relative to an
attenuated open directory, treats filenames as bytes, refuses symlink escape
before lookup, and sorts by unsigned bytes.

## Motivation

The language cannot replace a native toolchain while delegating host behavior
to ambient shell, PATH, current directory, environment, descriptor inheritance,
or locale. Those inputs are both a security problem and a reproducibility
problem. RFC-0002 settles environment authority semantically, but its compiler
surface and the process/directory siblings were still open.

## Detailed design

### 1. Environment compiler profile

Option A from #1241 is selected.

- The v1 types are compiler-known nominal types. General user-defined
  `opaque affine` declarations and effect rows are not introduced.
- `fn main() -> Int` retains its exact meaning. The only root-aware form is
  `fn main(take root: RootAuthority) -> Int`. A program may define one or the
  other, never both. There is no hidden root name.
- `EnvironmentKey.parse("NAME")` over a literal and a canonical literal list
  produce a sorted, duplicate-free known-key fact. Dynamic input produces the
  distinct fact `unknown`; it never means empty, all keys, or unrestricted.
- `pure fn` asserts that the existing inferred least-fixed-point effect summary
  stays `pure`. It adds no polymorphic effect row.
- Before the carrier ABI exists, `check` may validate and publish typed facts.
  `build` and `run` refuse the root/environment carrier before emitting an
  artifact.
- Diagnostic precedence is parse/type/ownership, E351-E355, E350, then E356.

Structured HIR records use nominal type IDs, sorted key bytes, a known/unknown
tag, ownership mode, and the profile ID
`kofun.environment-authority/compiler-v1`. Display spelling and source paths
are not identity.

### 2. Process authority

`ProcessAuthority` is affine and derived from `RootAuthority` by an explicit
allowlist. Each entry binds an approved absolute executable path, artifact
digest, allowed argument prefix/domain, optional cwd authority, environment
authority, and stdio mapping. Attenuation can only remove choices or lower
limits.

The portable synchronous operation takes the authority and a `ProcessRequest`:

```kofun
fn spawn_wait(
    take authority: ProcessAuthority,
    take request: ProcessRequest,
) -> Result[(ProcessAuthority, ProcessOutcome), ProcessError]
```

`ProcessRequest` carries executable identity, `List[Bytes]` argv, explicit
environment entries, optional directory authority, and explicit stdin/stdout/
stderr modes. Shell metacharacters are ordinary bytes. There is no shell, PATH
search, ambient environment, ambient cwd, or inherited descriptor. Only the
three descriptors explicitly mapped for stdio and capabilities deliberately
transferred into the child can cross.

`Child` is affine. A successful start must end in exactly one reap. Start
failure creates no child. Capture drains stdout and stderr concurrently under
independent 8-MiB limits, reaps the child on capture failure, and returns no
truncated bytes as success. Outcomes distinguish `Exited(code)`,
`Signaled(signal)`, `CaptureLimitExceeded`, and `Cancelled`.

Limits are 256 arguments, 65,536 bytes per argument, 1 MiB total argv, and
8 MiB for each captured stream. Exceeding a limit fails before spawn where it
is known, otherwise kills and reaps the child before returning the typed error.

The self-contained native build in RFC-0018 may not require this authority to
run a compiler, assembler, or linker. It exists for explicit application and
optional adapter behavior.

### 3. Directory authority

`DirectoryAuthority` owns an already-open directory handle plus stable root
identity, rights, and limits. It is derived or attenuated component by
component. No operation consults the process cwd.

A relative component is nonempty bytes other than `.` or `..` and contains no
NUL or separator. The default profile refuses symlinks before following them
and performs every lookup relative to the authorized handle with a
stay-beneath/no-magic-link rule. Unauthorized sibling lookup is therefore not
attempted and cannot leak existence through a later authorization check.

Filenames are `Bytes`. `Text.from_utf8` is the explicit validated conversion;
invalid UTF-8 is a filename value, not record corruption. `.` and `..` are
excluded. Results sort lexicographically by unsigned filename bytes,
independent of kernel, locale, or filesystem order.

One enumeration admits at most 65,536 entries, 255 bytes per name, 64 MiB of
name bytes, and derivation depth 64. Malformed kernel records, overflow,
identity/version change during enumeration, permission failure, and resource
failure yield a typed error and no partial successful snapshot. All handles and
buffers are released on every path.

Linux uses a direct `getdents64` adapter. WASI maps the same language contract
to a preopen-relative adapter; a WASI implementation that cannot enforce the
same stay-beneath and byte-name semantics refuses the profile.

### 4. Error and diagnostic boundary

Compile-time authority/effect errors use:

| Code | Meaning |
|---|---|
| E350-E356 | RFC-0002 environment authorization, attenuation, escape, and pure-boundary failures in their accepted precedence. |
| E402 | a process operation has no suitable `ProcessAuthority`. |
| E403 | a statically known process request widens its executable, argv, cwd, environment, descriptor, or capture grant. |
| E404 | a directory operation has no suitable `DirectoryAuthority`. |
| E405 | a statically known path contains an escape or symlink-following request outside the grant. |
| E406 | a statically known enumeration bound exceeds the authority. |

Runtime failures are typed ADT variants, not forged compile diagnostics. Host
errno is retained as bounded adapter detail where disclosure is allowed and is
never the cross-platform semantic identity.

## Semantics

An authority is non-forgeable, affine, and monotonically attenuated. Taking it
transfers the grant; reading it may inspect metadata but cannot create a second
live owner; restricting it returns a successor whose set is a subset.

Permission is checked against normalized intent before host lookup. `unknown`
static environment facts move the check to the typed runtime result; they do
not widen authority. Process and directory operation order, output, and error
classification are independent of hash iteration, locale, cwd, PATH, and
declaration order.

## Diagnostics

Every compile refusal names the operation, required grant, available attenuated
grant, and source span. It does not print secret environment values, unapproved
paths, sibling existence, or captured child bytes. Runtime variants preserve
which phase failed: authorize, start, capture, wait/reap, enumerate, decode, or
limit.

## Ownership and effects

All three domains have `io`. `pure fn` excludes them and produces E356 only
after syntax, type, ownership, and authority checks. Authorities and live child
or directory handles are `Owned`; container propagation follows RFC-0004.
Terminal summaries, exit outcomes, filenames, and validated text are managed
values. Cancellation consumes the active handle and leaves no un-reaped child
or open directory cursor.

## Alternatives

General `opaque affine` and effect rows are deferred: they widen the language
without improving this bounded profile. Hidden root and inference-only purity
are rejected because authority would be invisible and E356 unexpressible.

Shell/PATH execution is rejected because it moves program identity into ambient
state. Automatic cwd/env/fd inheritance is rejected for the same reason.

A broad path-string filesystem capability is rejected. An open directory
handle with stay-beneath lookup is smaller, avoids ambient cwd, and has a Linux/
WASI mapping. Lossy Text filenames and kernel-order results are rejected.

## Drawbacks

Callers must construct explicit requests and handle typed outcomes. Digest-
pinned executables require package/build integration. Symlink refusal is less
convenient than path following and needs a separately authorized future mode.
Snapshot invalidation can force retries on actively mutated directories.

## Compatibility and migration

Category: `additive`. Existing zero-argument entrypoints and programs retain
their meaning. The new contextual `pure fn` form and compiler-known types are
currently unimplemented; no accepted program loses behavior. Existing host
helpers remain implementation tools but cannot be presented as these language
capabilities.

## Implementation plan

1. Land the environment typed-HIR/model child, then authority kinds and effect
   boundary, then the runtime/ABI children already sequenced under #1193.
2. Implement process start/wait first, capture second; reuse the trusted-adapter
   entitlement ABI without granting ambient descriptors.
3. Implement directory derivation/enumeration with a pure adversarial model,
   then Linux and WASI adapters.
4. Promote capability rows only after each target executes its focused corpus.

## Validation

The committed decision model is gated by:

- `task environment-authority-compiler-contract`;
- `task host-process-authority-contract`;
- `task directory-authority-contract`;
- `task rfc-registry capabilities release-claims repository-check`; and
- full `task verify`.

The model rejects implicit root, ambient PATH/cwd/env, symlink following,
underspecified bounds, and partial success.

## Unresolved questions

Async jobs, signals sent by the parent, PTYs, shell modules, symlink-following
grants, directory watches, and write authority are separate versioned profiles.
They cannot widen these defaults implicitly. The v1 decisions above are closed.

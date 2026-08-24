# Directory enumeration carrier profile v1

Normative schema: `kofun.directory-enumeration-carrier-v1/v1`.
Decision owner: Issue #1534. Selected: **Option C**, canonical packed immutable
`DirectorySnapshot`. This profile advances no target or capability.

## Target and owners

The compiler backend is `c11-stage2`; release/CLI target is
`linux-x86_64`. Other targets refuse before artifact publication. #1235 owns
compiler `DirectoryAuthority`, E404-E406 and directory E356 integration, the
packed carrier, and final Linux adapter as independently gated commits. #1536
owns the sole runtime root/provider and #1196 owns the one directory-listing
entitlement ABI row. Environment, AtomicWrite, raw syscalls, and WASI file-read
evidence do not count.

## Public operation and authority return

Conceptually:

```kofun
fn list_snapshot(
    take authority: DirectoryAuthority,
    take request: DirectoryListRequest,
) -> DirectoryListResult
```

Every success/error carries `DirectoryReturn.Ready(authority)` or
`DirectoryReturn.Revoked(authority, reason)`. Prelookup authorization,
lookup, decode, allocation, bound, snapshot, sort, and cleanup therefore
cannot erase an affine authority.

Success contains only a complete immutable `DirectorySnapshot`. Errors are
`Unauthorized`, `InvalidComponent`, `UnsupportedKernel`,
`UnsupportedFilesystem`, `UnsupportedSnapshotProvider`, `LookupRace`,
`MalformedRecord`, `PermissionDenied`, `ResourceFailure`,
`EntryLimitExceeded`, `NameLimitExceeded`, `TotalNameLimitExceeded`,
`SnapshotChanged`, `SortFailure`, and `CleanupFailure`. Detail may carry
counts/digests and adapter phase, never unauthorized sibling names or invalid
filename bytes. No partial prefix is successful.

Empty directories produce the canonical empty snapshot. Duplicate names in a
stable scan are malformed; repeated records while the provider generation
changes become `SnapshotChanged`. `d_ino`, `d_type`, and `d_off` are adapter
facts, never portable entry identity.

## Packed carrier and numeric bounds

The arena is the concatenation of sorted unsigned-byte filename values with no
padding. Each 8-byte index row is `{u32le offset, u16le length, u16le zero}`.
Rows are sorted by filename bytes, offsets are monotonic and in range, and the
arena has no unindexed bytes. Entry access checks the index and copies at most
255 bytes into the existing `Bytes` identity; it does not expose a second
target-private `Bytes` or a dangling view.

The empty value has count zero, empty index, and empty arena. Equality is the
canonical index+arena bytes. Digest uses domain
`kofun.directory-snapshot/v1`, little-endian count, and each length+name in
row order. Drop frees the one arena and one index exactly once.

Bounds are inclusive: 0/1/65,535/65,536 entries succeed if every other bound
holds; 65,537 refuses. Names 1/254/255 bytes succeed; empty names and 256 bytes
refuse. The mathematically reachable total is narrowed from RFC-0014's loose
64 MiB ceiling to `65,536 * 255 = 16,711,680`; 16,711,681 refuses.

The index is at most 524,288 bytes, sort scratch 262,144, raw getdents buffer
65,536, provider state 4,096, and total live working storage 17,567,744 bytes.
At most two descriptors are live. A retry releases the first attempt before
allocating the next, so the ceiling is not doubled. Allocation failure is an
error, never empty/partial success.

## Snapshot provider and concurrency

V1 admits only a trusted provider that returns a stable 128-bit root epoch,
128-bit object identity, and monotonically changing 128-bit directory
generation for the open handle. A namespace mutation changes generation;
values do not wrap or reuse within the root epoch. The entitlement review is
evidence for that property. Without it, enumeration refuses before getdents;
mtime, ctime, `d_off`, or two apparently equal scans are not substituted.

The adapter samples identity/generation before and after a complete scan. A
change discards everything and retries once; a second change returns
`SnapshotChanged` with no names. Non-cooperating unprivileged mutations are in
scope through the provider generation. Provider/kernel compromise and
privileged mutation outside its guarantees are the explicit threat boundary.

Precedence is authorization/path validation, supported kernel/filesystem/
provider, lookup, decode/permission/resource/bounds, post-scan snapshot,
sort, then cleanup. A concrete malformed/resource error is not hidden by a
later version sample; cleanup failure records the prior terminal state and
revokes the returned authority.

## Linux lookup and decoder

Authorization and byte-component validation happen before lookup. `openat2`
uses `RESOLVE_BENEATH|RESOLVE_NO_MAGICLINKS|RESOLVE_NO_SYMLINKS`,
`O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW`, and `open_how` size 24. `EAGAIN`
retries eight times; the ninth is `LookupRace`. `ENOSYS`, old structure size,
or unsupported flags return `UnsupportedKernel`. There is no `openat` fallback.
Enumeration and final identity samples use the same handle.

The `linux_dirent64-strict-v1` decoder requires a complete 19-byte header,
aligned nonzero `d_reclen`, record end within the buffer, no integer overflow,
a NUL terminator inside the record, and name length 1..255. It excludes exact
`.` and `..`; accepts `DT_UNKNOWN`; preserves invalid UTF-8 bytes; retries
`EINTR`; treats zero read as EOF; and never advances on malformed data.
Buffers/descriptors/provider tokens are released exactly once on every exit.

## Capability boundary

The existing adapter row remains `directory-listing`. The reserved claim is
`authorized-directory-listing-v1`, state `checkpoint`, exact target
`linux-x86_64`. It eventually binds the provider threat model, boundary/one-
over fixtures, same-handle lookup, strict decoder, cleanup, and explicit
exclusions: recursion, mutation, watches, ambient cwd, symlink following,
Text coercion, and unsupported targets. Adding it is a later MINOR event.

Options A/B cannot carry 65,536 arbitrary byte names with current public
types; D changes synchronous value semantics; E defers a realizable carrier
decision. `task directory-enumeration-carrier-decision` independently mutates
target, carrier, numeric ceilings, authority return, provider, retry,
openat2/fallback, decoder, and release identities.

# Atomic publish-if-absent profile v1

Normative schema: `kofun.atomic-publish-if-absent-v1/v1`.
Decision owner: Issue #1578. Selected: **Option A**, Linux
`renameat2(RENAME_NOREPLACE)`. This profile grants no filesystem capability and
advances no release claim.

## Inputs and authority

The operation receives one affine publication authority for a preopened local
directory, a caller-verified and fully synced regular temporary file handle in
that same directory, and a final basename of 1..255 `Bytes`. There is no path
walk, ambient cwd, absolute path, second directory, or cross-device source.
The authority binds the stable directory identity, temporary identity, final
basename, admitted filesystem, and exact operation.

The filesystem allowlist is ext4, xfs, btrfs, and tmpfs, matching the existing
atomic-write profile. Unknown, NFS, FUSE, and overlay filesystems refuse before
reservation or syscall. The temporary must be a regular file with one link and
the bound directory/device identity. Digest verification and winner rehash are
consumer operations and do not widen this primitive.

## Linearization and outcomes

The one linearization point is:

```text
renameat2(directory, temporary, directory, final, RENAME_NOREPLACE)
```

`Published` means the temporary entry was consumed and the final entry was
created once. `EEXIST` is `AlreadyExists`: the existing entry, including a
symlink, is untouched and unopened, and the caller receives responsibility for
the unchanged temporary handle. `EXDEV`, unsupported kernel/flag/filesystem,
permission, resource, and other provider failures are separately typed and
also return the temporary when no commit occurred.

After a successful rename, directory-sync or cleanup failure is
`CommittedDurabilityUnknown`; it carries `committed: true`, consumes the
temporary, and cannot be relabelled as failure-before-publication. The caller
may inspect/recover the final entry under new authority but cannot retry the
same consumed operation.

Plain rename and check-then-rename can replace or race and are forbidden.
Hard-link publication is not a fallback: it changes link-count/cleanup facts
and would create a second protocol. `ENOSYS` or unsupported
`RENAME_NOREPLACE` therefore refuses. macOS, Windows, WASI, and every non-Linux
target explicitly refuse before artifact publication until their own profile
proves equivalent no-replace semantics.

## Cancellation and ownership

An explicit cancellation observed during preflight returns the untouched
temporary and `Ready` authority. Once the kernel operation is entered there is
no `Cancelled` result: returning it would make the commit state ambiguous.
The syscall reaches one terminal result, then the adapter returns `Ready` or
`Revoked` authority and exactly one owner for every surviving handle. No branch
leaks, double-closes, or silently deletes the losing temporary.

Two concurrent publishers of one final basename must produce exactly one
`Published` and one `AlreadyExists`; pre-existing bytes are mutation-proved
unchanged. Implementation remains blocked on #1323 and #1196. The future
checkpoint is `linux-x86_64` only and must execute concurrency, pre-existing
symlink/file, unsupported, cross-device, cancellation, cleanup, and process-
death fixtures.

`task atomic-publish-if-absent-decision` independently mutates the syscall,
flag, directory/temporary boundary, filesystem policy, basename bound,
cancellation cut, terminal outcomes, fallback refusal, authority return,
target refusal, and no-claim boundary.

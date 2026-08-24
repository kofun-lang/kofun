# Workspace upgrade transaction v1

Normative schema: `kofun.workspace-upgrade-transaction-v1/v1`.
Decision owner: Issue #1532. Selected: **Option A**, single-file automatic v1.
The executable data record is
`spec/workspace-upgrade-transaction-v1/contract.json`.

This contract adds no writer, capability, release claim, or permission to edit
source. It defines the primitive #883 must implement after the read-only #884
artifact exists.

## Observable guarantee

One transaction changes exactly one existing regular source file. An accepted
preview containing edits to two or more files is preview-only and automatic
apply refuses before a lock, journal, stage, or target is created.

The covered observers are all direct-path readers of that one file. The
linearization point is one same-directory atomic rename: a reader sees the
complete old bytes or complete new bytes, never a prefix. No claim is made
about a repository-wide snapshot, Git index, compiler cache, or a reader that
already holds the replaced inode open.

After the rename, the source is committed. A later directory sync, journal
update, or cleanup failure is `CommittedDurabilityUnknown`; it must not be
reported as an uncommitted failure. Recovery decides durability from the
bound digests.

## Durable state and every death cut

| Durable/observable phase | Direct path | Recovery action |
| --- | --- | --- |
| `no-intent` | old | nothing |
| `intent-durable` | old | remove an authenticated empty/partial stage; keep old |
| `stage-partial` | old | remove only the journal-bound stage; keep old |
| `stage-durable` | old | remove the stage and record rollback |
| `publication-complete` | new | if the target digest is exactly new, roll forward; otherwise refuse |
| `commit-durable` | new | idempotently finish cleanup |
| `cleanup-partial` | new | idempotently finish only authenticated cleanup |

At every pre-publication phase, recovery proceeds only when the target still
has the exact old digest and selected metadata; otherwise it refuses without a
write. At every post-publication phase, it proceeds only when the target has
the exact new digest. An unexpected third digest, missing artifact, changed
path identity, corrupt journal, or unknown phase is `RecoveryDrift` and leaves
the workspace unchanged. Repeated crashes repeat the same digest-directed
transition.

Committed cleanup failure never becomes rollback. There is no operator-choice
branch in v1.

## Explicit source-write authority

`kofun.workspace-write-authority/v1` is one-shot. The invocation binds:

- the stable opened repository root identity, expected branch and HEAD OID;
- preview/patch schemas, revisions, canonical-byte digests, and graph identity;
- the single normalized repository-relative path, stable file identity,
  selected metadata, complete old/new digests, ordered spans, and replacement
  bytes;
- operation `apply`, `recover(transaction-id)`, or `undo(transaction-id)`;
- every numeric limit below.

Apply, recover, and undo each require a fresh grant. A journal narrows recovery
to its interrupted bytes but is not itself authority. Preview, LSP transport,
diagnostics, caches, issue claims, process startup, and possession of an
unfinished stage grant nothing.

The grant covers source bytes only. It cannot write `.git`, index, refs,
commits, checkout state, hooks, submodules, remotes, another repository, or an
unlisted path.

## Repository and path boundary

The caller supplies a preopened repository root. Its device/inode identity and
explicit branch/OID are bound; ambient cwd and mutable root spellings are not.
Each component is opened with Linux `openat2` beneath that root using
`RESOLVE_BENEATH|RESOLVE_NO_MAGICLINKS|RESOLVE_NO_SYMLINKS`. Absolute paths,
empty/dot/dot-dot/NUL components, case-fold aliases, duplicate normalized
paths, symlinks, mount crossings, and submodules refuse before artifact
creation.

The admitted filesystems are ext4, xfs, btrfs, and tmpfs, matching the
one-target AtomicWriteAuthority profile. Unknown, NFS, FUSE, and overlay
profiles refuse. The target must have link count one; hard-link identity is not
silently broken. Mode bits are preserved. A target whose owner/group cannot be
preserved, or which carries xattrs/ACLs the provider cannot reproduce, refuses.
Timestamps intentionally change at publication.

The lock key is stable repository identity plus normalized path. One process
registry and one kernel advisory lock serialize cooperating writers. Locks do
not exclude Git, editors, privileged writers, or any non-cooperating process;
immediate pre-rename digest/identity revalidation is the boundary, not a claim
that advisory locking freezes the world.

## Journal, staging, sync, and bounds

The journal schema is `kofun.workspace-upgrade-journal/v1`, canonical JSON
UTF-8 followed by one newline, stored under the preopened
`.kofun/transactions` directory with owner-only permissions. It binds the
transaction ID, repository/branch/OID/graph/patch identities, operation,
single target, old/new bytes and digests, selected metadata, phase, stage
basename, recovery direction, and limits. Duplicate/unknown fields and
non-canonical bytes refuse.

Creation is exclusive. A pre-existing stage or journal is adopted only when
its authenticated content and provenance name this exact transaction.
Filenames alone never establish provenance.

The order is: write and sync intent journal; sync journal directory; create and
write stage; sync stage; record/sync stage-durable journal; rename stage to
target; sync target directory; record/sync committed journal; authenticated
cleanup; sync journal directory. The target rename is the commit point.

V1 bounds are one file, 16,777,216 source bytes, 1,024 path bytes, 4,096 edits,
32 retained transactions, and 536,870,912 retained bytes. Reaching a retention
bound refuses a new apply. Explicit authorized garbage collection may remove
only terminal records and never the sole recoverable undo record.

## Undo

Undo is a fresh one-file transaction, not continuation authority. It requires
the completed transaction ID and rechecks repository, branch/OID, path
identity, current new digest, and selected metadata before writing the old
bytes. Undo-of-undo is another explicit transaction; repeated undo of the same
lineage refuses once current bytes no longer equal that transaction's new
digest. Interrupted undo uses the same phase table. Concurrent apply/undo
serialize on the same key. No drift case changes the workspace.

## Relationship and rejected options

#1317/#1323 provide the one-target replacement authority after this profile's
root/path checks; they are not widened into multi-file or repository authority.
#884 stays read-only. #883 is narrowed to this one-file primitive and may be
remeasured independently after #884 lands.

Option B admits mixed old/new direct-path observation and is unnecessary for
the v1 consumer. Option C protects only indirection-aware readers. Option D
would defer a useful realizable subset. Option E adds Git authority that the
source-write grant deliberately excludes.

`task workspace-upgrade-transaction-decision` mutates scope, commit reporting,
recovery direction, authority, path, hard-link, lock, bounds, and undo
independently. `task upgrade-patch` and
`task atomic-write-authority-contract` remain separate existing boundaries.

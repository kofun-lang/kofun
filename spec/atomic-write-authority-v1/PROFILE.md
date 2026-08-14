# AtomicWriteAuthority profile v1

The contract for one unforgeable, affine authority that grants **exactly one**
bounded atomic replacement in a preopened local Linux directory.

This document and the model beside it add no compiler carrier, no runtime
authority, no syscall adapter, no capability, and no release claim. They are
the thing an implementation is checked against, written before the
implementation exists so the contested parts can be argued as executable
properties rather than as prose.

Option A was selected on
[#1317](https://github.com/kofun-lang/kofun/issues/1317) on 2026-08-14. Option
C — a caller Boolean, path spelling, or filename convention — was rejected
because safe source can forge all three, filenames prove no ownership, and NFS
behaviour cannot be made local by assertion. Option B, a trusted adapter with
no safe Kofun surface, may exist as internal evidence and closes nothing here.

## 1. The admitted filesystem allowlist

The provider calls `fstatfs(2)` on the separately opened
`O_RDONLY|O_DIRECTORY|O_CLOEXEC` descriptor and admits exactly these magics:

| filesystem | magic |
|---|---|
| ext4 | `0xef53` |
| xfs | `0x58465342` |
| btrfs | `0x9123683e` |
| tmpfs | `0x01021994` |

NFS, FUSE, overlayfs, and **every unknown magic** refuse. Widening this list is
a profile revision that carries its own error-is-noncommit argument; it is not
a configuration change.

The refusal happens **before** the name is validated and before anything is
reserved or created. That ordering is normative: it is what makes "a refused
filesystem never creates a temporary or takes a lock" true. `model.mjs`
encodes the order, and the gate's `a refused filesystem reserves nothing`
property fails if it is rearranged.

The deterministic provider injected into the model fakes the magic value and
never the decision made from it.

## 2. Directory acquisition: there is no path

v1 performs **no path resolution at all**. The provider creates or opens its
dedicated publication directory and hands the already-open descriptor to
issuance.

Absolute and relative walking, `..`, and symlink traversal are therefore
refused **by construction rather than by validation** — there is no path input
to traverse. This is the strongest form the profile can take and the reason it
is chosen: a validator can be wrong, and a missing parameter cannot.

## 3. Target basename

`Bytes`, 1 to 255 bytes. No `/` and no NUL. Not `.`, not `..`, and not any of
the 32 reserved temporary names.

Bytes rather than text, because RFC-0014 states filenames are `Bytes` and
`Text.from_utf8` is the explicit validated conversion. 255 because that is
Linux `NAME_MAX` — the bound refuses exactly what the filesystem refuses,
rather than reserving headroom nothing uses: the temporary namespace is fixed
and independent of the target name.

The basename is a **directory-entry name only**. A symlink at the target is
replaced as an entry and never followed, and the target is never reopened by
path after issuance.

## 4. The reserved namespace and the reservation

The complete fixed namespace is `.kofun-atomic-00.tmp` through
`.kofun-atomic-31.tmp` — 32 names, shared by **every** target in that
directory.

That sharing is why the reservation is per **directory**, not per target. Two
different basenames in one directory contend, and an implementation that
reserved per target would pass a naive test and corrupt on the second
publication. The gate's `one directory carries one live reservation` property
exists for that mistake specifically, and the `reserve per target instead of
per directory` mutation is caught by it.

Acquisition is basename and profile validation, then in-process reservation on
the stable directory key, then the kernel lock. Any lock failure releases the
registry entry. `EWOULDBLOCK` is `ReservationBusy`, `ENOLCK` is
`UnsupportedLockService`, `EINTR` retries at most **128** consecutive times and
the 129th is `InterruptedIssuance`. Every other errno is `ProviderFailure`.

Process death releases the reservation once the kernel closes the last
same-OFD descriptor. `flock` is advisory: arbitrary non-cooperating writers are
outside the threat model, and this profile never claims otherwise.

## 5. Stale recovery needs provenance, never a filename

Reservation alone never adopts a pre-existing matching filename.

Initial enrollment happens under both locks and refuses if any of the 32 names
already exists. A later holder may recover a stale name **only** when the same
trusted provenance proves the whole namespace was granted to this protocol. A
generic directory with an ambiguous matching name refuses and never unlinks.

The reason is one sentence: a filename is not a capability. Anyone can create
`.kofun-atomic-07.tmp`.

## 6. Typed outcomes

**Issuance** — `Issued`, `ReservationBusy`, `UnsupportedLockService`,
`InterruptedIssuance`, `UnsupportedFilesystem`, `InvalidTargetName`,
`EnrollmentConflict`, `ProviderFailure`.

**Replacement** — `Replaced`, `WriteFailed`, `SyncFailed`, `RenameFailed`,
`CleanupFailed`, and `Declined` for the explicit unused release.

Every outcome consumes the one-shot authority **exactly once**. A second use of
a consumed authority is refused, and the gate proves that for both `replace`
and `release`.

### A committed rename is never relabelled a failure

`CleanupFailed` carries `committed: true`. The rename has happened; the
caller's question — did the target change — is already answered yes, and a
cleanup error afterwards does not un-answer it.

This is the profile's most specific instruction to an implementer, because the
tempting shape is to fold it into the failure branch. The
`relabel a cleanup failure as a failure` mutation exists to make that shape
fail the gate.

## 7. What this profile does not do

It composes with, and does not redefine, the authority identity and facts owned
by #1241/#1193/#1242-#1246, #1194's runtime root, and #1196's entitlement ABI.
It adds no syntax, no HIR fact, and no effect identity. `check` may validate
while `build` and `run` refuse, until those foundations exist.

Bounded v1 has no in-flight cancellation token and no ambient cancellation
state. A caller may decline before replacement; an invoked adapter runs to one
terminal syscall outcome.

## The gate

```sh
task atomic-write-authority-contract
```

It asserts 13 properties on the pure model, then damages the model eight ways
and requires each damage to be caught **by a distinct set of properties**. Two
mutations caught by the same properties would mean the model cannot tell those
two mistakes apart, and the gate treats that as a failure rather than a pass —
the same rule the model applies to its own outcome names, which must not be
shared between issuance and replacement.

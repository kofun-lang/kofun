# Process capture carrier profile v1

Normative schema: `kofun.process-capture-carrier-v1/v1`.
Decision owner: Issue #1533. Selected: **Option A**, the bounded singular
`Bytes` checkpoint. This profile clarifies RFC-0014 without claiming an
implementation.

## Target and implementation split

The first compiler backend is `c11-stage2`; the release and CLI target spelling
is separately `linux-x86_64`. Those identities are related by the eventual
adapter and are not aliases. Every other backend refuses this profile before
artifact publication.

#1232 owns compiler-known `ProcessAuthority`, E402/E403 and process E356
precedence, request/outcome carriers, root derivation, and the one #1196
entitlement entry. #1233 owns the Linux capture adapter after #1232. Existing
Environment evidence proves none of those facts.

## Operation, authority, and values

The checkpoint operation is conceptually:

```kofun
fn spawn_wait_capture(
    take authority: ProcessAuthority,
    take request: ProcessRequest,
) -> ProcessCaptureResult
```

Every branch returns `ProcessReturn.Ready(authority)` or
`ProcessReturn.Revoked(authority, reason)` together with its outcome/error.
Start, capture, overflow, read/allocation, termination, wait, and cleanup
cannot lose a consumed authority into an unstructured `Err`.

Successful values are `Exited(code, stdout: Bytes, stderr: Bytes)` and
`Signaled(signal, stdout: Bytes, stderr: Bytes)`. Each stream is a separate
existing Stage 2 `Bytes` value with inclusive maximum 65,536. Empty output is
zero-length `Bytes`. Byte order within a stream is preserved; no cross-stream
ordering is invented.

Errors are `StartError`, `StdoutLimitExceeded`, `StderrLimitExceeded`,
`ReadFailure`, `AllocationFailure`, `TerminationFailure`, `WaitFailure`,
`DescendantWriterTimeout`, and `CleanupFailure`. Error detail may carry stream,
phase, errno class, and an observed lower-bound count, but never captured child
bytes. Partial prefixes are dropped and cannot inhabit successful output.

The first synchronous profile has no reachable cancellation source, so
`Cancelled` is absent rather than a decorative variant. The portable RFC
profile retains cancellation as later work with an explicit authority/source.

## Exact limits and resources

The successful boundary is inclusive at 0, 1, 65,535, and 65,536 bytes;
65,537 and every larger length overflow. The portable 8,388,608-byte-per-stream
contract is not reinterpreted and remains a future profile.

Two payloads retain at most 131,072 bytes. One shared 16,384-byte read scratch
buffer plus at most 4,096 bytes of descriptor/event state gives a hard
151,552-byte working ceiling. At most eight parent descriptors are live.
Allocation failure is typed and cannot become empty output or truncation.

Known argv/capture grant excess refuses before spawn. Output overflow exists
only after spawn and triggers termination plus exactly one reap before return.

## Linux adapter and terminal state

The adapter uses `openat2` to open the approved executable, hashes that open
file description, and uses `execveat(AT_EMPTY_PATH)` on the same description;
path replacement cannot substitute bytes after verification. `pipe2` creates
private `O_CLOEXEC|O_NONBLOCK` stdout/stderr pipes. `epoll` drains both. Only
explicit stdio/capability descriptors survive exec.

The child starts in a dedicated process group. On overflow, read/allocation
failure, or terminal retained-writer exhaustion, the adapter sends `SIGKILL`
to that group through the pinned process handle, closes parent writers, drains
terminal pipe state, and calls `waitid` exactly once for the leader. After the
leader becomes waitable, eight terminal polls are allowed for ordinary EOF;
then the group is terminated so a descendant cannot hold success open forever.

Success requires both pipes at EOF/HUP and the leader reaped. `EINTR` retries;
`EAGAIN` returns to epoll; zero read is EOF. Cleanup is exactly once on every
branch. A cleanup failure after a complete reap is not relabelled as start or
capture failure.

Within one event batch the precedence is read failure, stdout overflow,
stderr overflow, termination failure, wait failure, then exit/signal. Equal
stream cuts choose stdout before stderr. This is deterministic classification,
not cross-stream byte ordering.

## Capability and release truth

Implementation adds an adapter-tier `process-capture` row, distinct from
`process-spawn`. The reserved claim is `authorized-process-capture-v1`, state
`checkpoint`, exact target `linux-x86_64`. Its future evidence must cover both
pipes beyond kernel capacity, limit/one-over, EINTR/EAGAIN/EOF/HUP, allocation
and read injection, retained writers, descriptor leaks, and zombies.

This decision advances neither row nor claim. Adding the claim is a later
MINOR release event. Shell, PATH, ambient cwd/env/descriptors, global stream
order, public signals, pipelines, PTYs, and async jobs remain excluded.

Options B/C/D require new incompatible carrier work. Option E discards a
realizable existing-Bytes checkpoint. `task process-capture-carrier-decision`
pins and mutates the selected target, carrier, exact bounds, authority return,
exec identity, drain/termination, precedence, and release identities.

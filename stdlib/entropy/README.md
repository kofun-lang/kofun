# Entropy

One operation, and the whole capability is its guarantee:

```kofun
fn entropy_fill(edit destination: Bytes) -> Result[Void, EntropyError]
```

`Ok(())` means every byte of `destination` came from `getrandom(2)`. Anything
else is an `Err`, and the caller is told the buffer is not usable. There is no
partial success, and no fallback to a clock, a PID, a constant, or
`/dev/urandom` — a fallback is the failure this capability exists to make
impossible.

This is where keys, nonces, tokens, salts, and passwords come from.

## Why it is not in `stdlib/random`

`stdlib/random` is a deterministic Park-Miller core with one adapter that seeds
it from eight bytes of `getrandom(2)`. Its own README says that adapter "does
**not** turn Park-Miller into a cryptographically secure generator", and
`stdlib/random/tests/verify.sh` asserts that exactly one file under that
directory obtains system entropy — "system entropy must remain in one explicit
adapter". A second entropy caller added there would break that assertion rather
than extend it. This module is outside it so that rule keeps holding, unchanged.

## What it is not

- **Not a generator.** It has no state, no seed, and no sequence. Ask for the
  bytes you need, once.
- **Not portable.** Linux x86-64. The `adapter` tier requires an unsupported
  target to fail at build time rather than degrade silently, and a second target
  is a second adapter, not a fallback inside this one.
- **Not configurable.** `flags` is `0` and is not a parameter. `GRND_RANDOM` and
  `GRND_NONBLOCK` change whether the call blocks, and a capability whose
  blocking behaviour depends on a caller-supplied integer cannot state one
  guarantee.

## Failures

```kofun
type EntropyError =
    | EntropySystem(SysError)
    | EntropyImpossibleCount(Int)
```

`EntropySystem` carries the operation and `errno` of a call that failed for a
reason other than `EINTR`, which is retried. `EntropyImpossibleCount` carries a
count the kernel promised could not happen — zero, which would loop forever, or
one past the space remaining, which would write outside the destination. Both
are reported rather than trusted.

A zero-length destination succeeds without calling the syscall. That is the loop
condition rather than a special case.

## Evidence

`tests/verify.sh`, reached by `task stdlib`. Three instruments, because the
adapter cannot be compiled or run — `bin/kofun check` on any file in
`stdlib/linux_x86_64` stops at its first `import`, and `trusted intrinsic` is
refused at top level in both pipelines, so `raw_getrandom` is unreachable from
any compilable program:

1. **Source properties** on the adapter: the `EINTR` retry, the continuation
   from the offset already filled, the request for exactly the bytes still
   missing, the impossible-count guard in both directions, and the absence of
   every fallback name.
2. **An executable Int-Core projection**, `tests/checkpoint.kofun`, of the fill
   loop driven by a scripted sequence of syscall returns — nine scripts covering
   a single full fill, a fill across three calls, `EINTR` at the first, middle
   and repeated positions, an empty destination, a zero return, a hard error,
   and an over-long return — against `tests/checkpoint.stdout`.
3. **An independent C11 oracle**, `tests/entropy_reference.c`, written from the
   adapter's rules rather than translated from the projection, running the same
   scripts and compared byte for byte. A wrong loop has to be written twice, in
   two languages, to pass.

`tests/oracle-binding.json` binds both digests, so a change to the adapter or
the oracle fails the gate until someone re-reads them together. It also records
what is **not** proved: that the real `getrandom(2)` is called with the right
arguments. That is the same gap `stdlib/linux_x86_64/io.kofun` has, and it is
closed the same way, by a committed native image — which this module does not
add.

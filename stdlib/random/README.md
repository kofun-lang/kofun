# Deterministic Random checkpoint

[`random.kofun`](random.kofun) is the public Kofun-facing API for explicit,
mutable, seeded pseudo-random generators. There is no module-global generator
and no clock-derived default seed:

```kofun
let mut generator = random_seeded(20260721)
let die = match random_below(generator, 6) {
    Ok(value) => value + 1,
    Err(_) => 0, # unreachable for the literal positive bound
}
random_shuffle_int(generator, values)
```

The checkpoint provides:

| operation | contract | cost |
|---|---|---|
| `random_seeded(seed)` | accepts every `Int`; congruent seeds modulo `2147483647` share a stream; residue zero maps to state 1 | O(1) |
| `random_next(generator)` | advances version 1 and returns `0 .. 2147483645` | O(1) |
| `random_below(generator, upper)` | unbiased `0 .. upper - 1` for `1 .. 2147483646`; invalid or larger bounds are `Err` | expected O(1) |
| `random_fill_bytes(generator, bytes)` | deterministic byte filling of existing storage | expected O(n) |
| `random_shuffle_int(generator, values)` | in-place Fisher-Yates | expected O(n), O(1) auxiliary storage |
| `random_sample_int(generator, values, count)` | sample positions without replacement; preserves the input | O(n + count²), O(n + count) storage |

The version 1 algorithm is Park-Miller MINSTD advanced with Schrage reduction.
The reduction is essential because ordinary Kofun `Int` multiplication is
checked and must not silently wrap. Bounded integers use rejection sampling,
not `% upper` alone. Bounds at most `2147483646` draw from the generator's
whole exact domain. A bound larger than that domain is explicitly unsupported:
combining several outputs from this 31-bit-state generator would not justify a
claim of uniform 64-bit values. A successful bound of one still consumes state,
keeping state transitions unsurprising.

Error results do not consume generator state. Empty byte fills, shuffles of
zero or one item, and zero-count samples also consume no draws. Sampling is
without replacement by input position: equal values at distinct positions can
both appear. Invalid sample counts return `InvalidSampleSize` before copying or
drawing.

## Reproducibility and compatibility

Given the same seed, algorithm version, and ordered API calls, all conforming
backends must return the checked vectors in
[`tests/checkpoint.stdout`](tests/checkpoint.stdout). Version 1 includes seed
normalization, rejection rules, the order in which shuffle/sample consume
draws, and byte order. An incompatible algorithm or consumption change must
introduce a new explicit version/API; it must not silently change version 1.
Serialized generator state is not yet a supported interchange format.

Reproducibility is intentionally limited to the deterministic module. It does
not cover thread interleavings over a shared generator (sharing one is outside
this API), calls to the system adapter, or a future algorithm version.

## Entropy and security boundary

[`linux_x86_64.kofun`](linux_x86_64.kofun) explicitly seeds `Random` from
Linux `getrandom(2)`. It retries `EINTR` and short reads and never falls back to
a clock, PID, fixed value, or partially filled buffer. That adapter makes a
simulation stream nondeterministic; it does **not** turn Park-Miller into a
cryptographically secure generator. `random_next`, `random_below`, and
`random_fill_bytes` must never produce keys, passwords, salts, tokens, or
nonces. Security-sensitive callers must use `entropy_fill` in
[`stdlib/entropy/linux_x86_64.kofun`](../entropy/linux_x86_64.kofun), which fills
a caller's buffer from `getrandom(2)` completely or returns an error.

"Use the platform entropy API directly" is what this paragraph used to say, and
it pointed at `random_fill` in `stdlib/linux_x86_64/process.kofun` -- one
`getrandom(2)` call, which surfaces `EINTR` and returns `Ok(n)` with `n`
possibly smaller than the buffer. A caller who wanted key material and believed
that `Ok` would have been handed a partially filled buffer. The retry loop that
makes this file's eight seeding bytes trustworthy was never available to them;
`entropy_fill` is that loop, for any length, with the guarantee stated (#1511).

## Current compiler boundary

The canonical API uses records, ADTs, mutable bytes, and mutable lists. The
active compiler still rejects that full combination before code generation.
The executable test is therefore an audited Int-Core projection of the same
state transition, rejection rules, byte sequence, shuffle, and sample. It is
differentially checked against an independent C11 test oracle. The C file is a
test oracle only; the standard-library implementation remains Kofun.

The collection surface is deliberately `List[Int]`. Generic and affine-element
shuffle/sample require the still-unimplemented trait bounds and move-aware list
mutation; this checkpoint records that boundary instead of specifying unsafe
implicit copies.

Module-private record fields are also not implemented yet. Callers must create
`Random` through `random_seeded` or `random_from_system`; manually fabricating a
record with an out-of-range `state` is outside the contract until the type can
be made opaque.

Run the Python-free gate with:

```sh
sh stdlib/random/tests/verify.sh
```

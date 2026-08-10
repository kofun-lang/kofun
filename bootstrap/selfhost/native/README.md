# Self-host Core native parity

This directory holds evidence that the frozen self-host **Core** reaches a real
native binary through two fully independent backends, tying the self-hosting
track to direct native-binary production.

Two programs go through both paths.

The first is the canonical single-expression Core, which is what this gate
started with and is unchanged:

```kofun
fn main() {
    print((6 + 1) * 6)
}
```

The second is `../driver/corpus_answer.kofun` — the self-host driver's success
corpus, the program `A1` already compiles on the C11 path — and it is the one
that makes the claim worth something:

```kofun
fn main() {
    let six = 2 * 3
    let answer = six * 7
    print(answer)
    print(1 + 2 * 3)
    print(-7 // 2)
    print(-7 % 2)
    print((answer - 2) / 8)
}
```

Five `print` statements, two locals whose types come from their initializers,
floor division, floor modulo, and truncating division. Until the direct native
backend grew the division operators, inferred `Int` locals, and a fallback from
the single-`main` Core to the function profile, this program was *refused* by
the native backend, and this gate recorded that refusal as its negative
evidence.

`check-native-corpus.sh` lowers both to native executables two ways and
requires each to print its pinned golden (`corpus_core.stdout` is `42`;
`../driver/corpus_answer.stdout` is `42 / 7 / -4 / 1 / 5`):

1. **Self-host C11 path.** The compiler built from the frozen `S`
   (`bootstrap/stage1/compiler.kofun`) — call it `A1` — is produced exactly as
   in `../check-compiler-driver.sh`: the trusted Stage 2 seed runs
   `kofun-stage2 --selfhost-compile` to emit the checked-in
   `../driver/S.c`, and the declared host `cc` builds `A1` from it. `A1` then
   compiles the frozen Core to deterministic C11, which `cc` links into a native
   binary.
2. **Direct-native path.** `kofun build ... --target x86_64-linux` and
   `--target aarch64-linux` drive the `bootstrap/native/core_compiler.c`
   backend, which writes a statically linked ELF64 image directly, with no
   assembler, linker, or `cc`.

The gate also checks that both direct-native images, on both targets, are:

- **deterministic** — two builds of the same source are byte-identical;
- **path-independent** — the same relative source compiled from two different
  directories produces byte-identical images, so no absolute build path leaks;
- **correctly shaped** — `readelf -h` reports `ELF64` with the expected machine
  (`Advanced Micro Devices X86-64` and `AArch64`), and `readelf -l` shows no
  `INTERP` or `DYNAMIC` segment, so the image is genuinely static.

Each x86-64 image is executed and its output compared both to its pinned golden
and to the self-host C11 path's output, so the two independent backends must
agree. The AArch64 images are executed when a `qemu-aarch64` runner is
available (or `QEMU_AARCH64` is set); otherwise their ELF64 machine is still
verified and execution is reported as skipped.

## Bounded surface, stated honestly

The direct-native Core is still a bounded subset, and the gate still records
that with negative evidence — it is just no longer this corpus that supplies
it. `bootstrap/native/fixtures/unsupported_native_core.kofun` needs `List[Int]`,
which only the single-`main` front end lowers, together with several `print`
statements, which only the function profile accepts. Neither front end can take
it, so it is refused with the stable `unsupported Core` diagnostic and writes no
image.

What the success corpus does **not** demonstrate:

- general source-language lowering beyond the bounded function profile, even
  though that profile now carries literal magnitudes through `INT64_MAX`;
- semantics beyond the shared numeric corpus; canonical per-operator
  `error[R010]` observations are covered separately by
  `tests/conformance/numeric`;
- anything about `S` compiling `S`, which is unchanged and is not this gate's
  subject.

## What this is and is not

- It **is** parity evidence that the self-host Core — including the driver's
  own success corpus — produces a real native binary through two independent
  backends.
- It is **not** self-application: `A1` compiles an ordinary Core input, exactly
  like the `../driver` gate. It makes no claim that `S` compiles `S`.
- It does **not** add a direct-native dependency to the C11 bootstrap fixed
  point tracked by #271/#272, which stays `cc`-based and native-independent per
  those issues. This gate is a separate artifact.

## Validation

```sh
task selfhost-native
# or
sh bootstrap/selfhost/native/check-native-corpus.sh
```

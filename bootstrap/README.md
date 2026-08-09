# Kofun bootstrap

- `stage1/compiler.kofun`: canonical Kofun compiler source
- `stage1/compiler.c`: audited C11 bootstrap artifact
- `stage1/SHA256SUMS`: source and seed digests
- `stage1/check.sh`: Python-free build and fixture gate
- `stage2/compiler.kofun`: Kofun lexer, structural parser, IR, and stable emitter
- `stage2/compiler.c`: audited executable checkpoint seed
- `stage2/check.sh`: deterministic source/token/IR round-trip gate
- `native/encoder.kofun`: direct ELF64/x86-64 encoder
- `native/check.sh`: Kofun Core to executable Linux image gate
- `c_abi/compiler.c`: audited canonical compiler for the bounded C ABI profile
- `c_abi/check.sh`: libc, archive, Rust cdylib, and C caller ABI gate
- `selfhost/check-inputs-sufficient.sh`: the declared acquisition set rebuilds
  the fixed point on its own
- `selfhost/check-diverse-double-compilation.sh`: B7, the two-toolchain gate
- `selfhost/check-diverse-double-compilation-refusals.sh`: its refusal corpus
- `fixtures/answer.kofun`: arithmetic Core compatibility fixture

Run the four listed checkpoints:

```sh
sh bootstrap/stage1/check.sh
sh bootstrap/stage2/check.sh
sh bootstrap/native/check.sh
sh bootstrap/c_abi/check.sh
```

Stage 1 builds the Kofun-written compiler seed, preserves the existing corpora
byte for byte, and verifies its bounded Int/Bool/Text/List[Text] comparison,
short-circuit, nested-block, loop, Text runtime, `chars`/`len`, and Text/List
indexing profile. Stage 2 validates a deterministic semantic-frontend boundary.
Native builds and executes a static ELF64 fixture.
`selfhost/check-inputs-sufficient.sh` answers the question the other
reproduction gates cannot. `declare-inputs.sh` writes what a builder must
obtain and `check-declared-inputs.sh` refuses a declared input that is
missing, altered, or undeclared; together they prove the manifest *describes*
the checkout. Neither proves a builder holding exactly that manifest can build
anything, and before this gate one could not: 59 files were declared, 70 were
needed, and a tree containing only the declared set failed at
`bootstrap/stage1/SHA256SUMS does not match the checkout` before compiling a
line. The eleven missing files were the two the sums manifests list, the
seed's own `#include` siblings, the Unicode runtime `.c` and its table, the
vendored utf8proc, and the two pinned answer artifacts `check-a1-a2.sh` reads
unconditionally. The gate now copies the declared files and nothing else into
a clean directory and runs the manifest's own reconstruction command there, so
an input that stops being declared fails the build rather than passing
silently.

The C ABI profile deliberately uses the host C compiler and dynamic linker; it
is not part of the static direct-native path. Semantic self-recompilation is
closed for the frozen profile — `task selfhost-fixed-point` proves
`C2 == C3` and `A2 == A3`.

## Diverse double compilation, and what it is worth

`task selfhost-diverse-double-compilation` closes B7. It builds the whole
generation chain twice, under two host C compilers that are different
binaries reporting different identities, and requires that the two resulting
Kofun compilers **emit the same bytes**: C1 and C2 byte-identical, and every
driver corpus case agreeing in emitted C, stdout, stderr, and exit status.
The executables differ, and that difference is reported rather than required
— equality there would be a claim about GCC and Clang, not about Kofun.

The gate is worth stating carefully, in both directions.

**What it buys.** Every other chain gate compares this checkout against
evidence checked into it, and that evidence was recorded by one toolchain. A
payload present in that toolchain when the evidence was recorded is pinned
along with it, and reproduces forever. This is demonstrable rather than
theoretical: with a payload wrapper that alters the compiler it builds while
restoring the source it found — so every `SHA256SUMS` still verifies — and
the checked-in evidence regenerated from that chain,
`bootstrap/selfhost/build-a1-a2.sh` exits 0 with every check green. The same
tree under two diverse toolchains exits 1, naming the toolchain that
disagrees and the byte it disagrees at. B7 is the gate that runs a compiler
which did not produce the baseline.

**What it does not buy.** It does not close B6 (#274). Both chains run on one
machine, against one libc and one kernel, from one checkout. A payload below
the C compiler is shared by both chains and survives this gate untouched. B7
narrows the trusted set to what the two toolchains have in common; it does
not empty it.

Independent reproduction (B6), a Kofun-written C ABI compiler, and a general
native compiler remain open.

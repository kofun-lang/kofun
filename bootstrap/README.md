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
`C2 == C3` and `A2 == A3`. Independent reproduction (B6), diverse double
compilation (B7), a Kofun-written C ABI compiler, and a general native
compiler remain open.

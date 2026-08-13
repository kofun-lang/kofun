# Native backend

`bootstrap/native/encoder.kofun` implements the direct-native checkpoint:
little-endian encoding, ELF64, PE32+, and Mach-O 64 image headers, ELF
program/section headers, separate RX/RW segments, immediate moves, Linux
syscalls, generic DWARF v4 metadata, and the big-endian CodeDirectory/SHA-256
records used by the Mach-O ad-hoc-signing checkpoint. The PE32+ checkpoint is
no-import; the Mach-O checkpoint declares the libSystem runtime dependency
needed by dyld after `LC_MAIN` returns. Both write complete x86-64 and AArch64
images directly and validate their structure/determinism. The signed Mach-O slice embeds
`__LINKEDIT`, `LC_CODE_SIGNATURE`, and a Kofun-hashed ad-hoc CodeDirectory for
both architectures. None of these image checkpoints yet exposes Windows/macOS
CLI/runtime targets or host-execution, Apple-validation, notarization, or
certificate claims.
The repository CLI exposes the supported arithmetic Core for x86-64 and
AArch64 Linux. Both targets lower local `Int` and `List[Int]` bindings; List
literals, length, indexing, and generated `map`/`filter`/`fold` loops with typed
inline lambdas. Both also lower UTF-8 Text concatenation, equality,
grapheme-cluster length, `chars`, grapheme indexing, and explicit `bytes` /
`codepoints` views. A separate bounded Int profile
lowers up to six function arguments,
returns, forward and mutual recursion, comparison-guarded early returns,
checked arithmetic, and signed Int64 output directly. A `return` whose value is
a direct call is lowered as a branch instead of a call on both targets: a call
to the enclosing function reassigns the parameters and jumps past the prologue,
and a call to any other function restores the registers the body claimed, drops
the frame, and jumps, so it returns straight to this function's caller. Direct
and mutual recursion written that way therefore run in constant stack. It also
lowers `//` and `%` with the floor semantics `docs/SEMANTICS.md` defines, and
does not define `/` on `Int`: with no implicit numeric promotion it cannot
produce a fractional value from two `Int` operands, so both targets refuse it
with one diagnostic and emit nothing (#687). Both targets guard
a zero divisor and the one non-representable quotient before dividing, and bind
as many locals as fit the shared 32-slot parameter/local frame, taking a
local's type from its initializer when no annotation is written. That function profile is
shared by both backends: the same target-independent parsed program is lowered
to x86-64 and to AArch64, and both emit the same checked, per-operator
`error[R010]` diagnostic bytes and exit status:

```sh
./bin/kofun build source.kofun \
  --target x86_64-linux -o build/program
./bin/kofun build source.kofun \
  --target x86_64-linux -g -o build/program-debug
./bin/kofun build source.kofun \
  --target aarch64-linux -o build/program-aarch64
```

Both selectors additionally implement a bounded compiler-shaped Text function
bridge: two Text parameters/results through the existing pointer ABI,
direct/forward calls, concatenation, immutable frame locals, and
`print(Text)`. Direct and CLI-produced static ELF artifacts are byte-identical
and compared with an independent C11 reference; AArch64 images are always
built/audited and execute under `qemu-aarch64` when available.

`-g` covers the single-`main` Core on both Linux targets. It adds
source-specific `.debug_line`, `.debug_info`, symbols, and section headers
without changing release output or loaded code/data. Both targets emit one
shared metadata contract: the same sections, the same `main` symbol and DIE,
and the same retained source lines, each at its own instruction addresses. The
executable gate validates the structures with `readelf` for both targets and,
when the tooling is installed, proves source stepping and a named `main`
backtrace with GDB — natively for x86-64 and through the `qemu-aarch64` gdbstub
for AArch64. Missing emulator or debugger tooling skips only the stepping
check. `-g` on the function profile (including a single-main fallback), and on
the AArch64 List/Text aggregate Core, remains an explicit rejection that
writes no artifact.

Run:

```sh
sh bootstrap/native/check.sh
```

The remaining native backend work includes:

- general AST/IR lowering, and register allocation for AArch64 functions;
- accumulator-style loops for recursion that is not already in a returned
  position;
- broader Text/List calls and types beyond the bounded two-target bridge;
- local bindings and general control flow inside user-defined functions;
- allocator reuse/reclamation and general raw syscall intrinsic lowering;
- diagnostic coverage beyond the checked-Int64 `R010` runtime paths;
- variable-location DIEs, multi-function debug information, and AArch64
  List/Text debug rows;
- unifying the currently separate function, List, and Text profiles.

Unsupported cases must be explicit skips, never implicit passes.

## What a target supplies

A target declares only the facts its ABI decides. Everything derivable from
those facts is written once, in target-independent code, and every target runs
that one copy.

A target supplies:

- **its register file** — a `TargetRegisterFile` naming the caller-saved
  scratch class, the call-safe class, and the value that means "no register";
- **its calling convention** — the argument, return, and reserved registers,
  and the frame discipline its ABI requires;
- **its emitter** — instruction encoding, the prologue and epilogue byte
  sequences, and the target's ELF machine identity.

A target supplies nothing else. In particular it does **not** bring its own
register allocator: `target_take_scratch_register`,
`target_take_call_safe_register`, `target_take_eval_register` and
`target_take_value_register` in `bootstrap/native/core_compiler.c` read the
declared register file and are the only implementation of the allocation
policy. `x86_64` and `AArch64` each carried a private copy of those four
functions until #770; the copies were identical once the `X64_`/`A64_` prefixes
were normalised away, so the pair could not disagree and proved nothing. A new
target that re-adds a copy is a defect, not a port.

`function_register_allocation.kofun` is the fixture that keeps the shared path
honest. The gate pins the leaf prologue for **both** targets — 18 bytes for
x86-64 and 20 for AArch64 — so a perturbation of the shared allocator changes
emitted bytes on both and fails the gate twice, rather than leaving one target
silently unexercised.

### What is deliberately still duplicated

The lowering pairs are not shared, and #770 did not share them. `x64_*` and
`a64_*` still carry independent implementations of `function_expression`,
`function_divide`, `function_compare`, `function_call`, `function_layout`,
`function_epilogue`, `function_guard_inverse`, `function_tail_call`,
`function_program`, `function_declaration`, `function_print_runtime`,
`function_print_text_runtime`, `function_trap_runtime`, `function_trap_stub`,
`function_epilogue_block`, `call_safe_registers`, `scratch_registers`,
`register_operand`, `slot_operand`, `expression`, `runtime`, `move`,
`value_operand`, `eval_operand` and `text`.

That is DD-022 applied, not an oversight: those two lowerings are genuinely
different code that the native gate requires to agree on observable behaviour
and on `R010` diagnostic bytes, so the agreement *is* the evidence. Sharing
them would delete it — one shared lowering that is wrong on both targets would
keep every gate green. Whether to share them anyway, and what would replace the
lost differential, is a separate decision that #770 explicitly did not make.

## Aggregate layout

The `Text` and `List` byte layouts this backend ships are target-specific
checkpoints, not a portable aggregate ABI. `spec/aggregate-layout-v1.md` is
the accepted portable contract; it specifies `u64` object headers where this
backend uses `i64`, and it records that difference as a versioned migration
boundary rather than treating the shipped bytes as a compatibility
requirement. This backend does not lower to AggregateLayout v1 yet, and must
not claim it until it agrees with the golden vectors under
`spec/aggregate-layout-v1/examples/`.

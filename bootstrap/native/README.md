# Direct native bootstrap

This directory advances issues #14 and #33 with a Kofun-owned, Python-free
native path. `encoder.kofun` is the canonical instruction and image
implementation. It constructs little-endian integers, x86-64 and AArch64
instruction bytes, target-parameterized ELF64 headers, and PE32+ headers and
sections, Mach-O 64 headers/load commands, big-endian code-signing records,
and SHA-256 digests directly. It does not emit assembly or invoke a linker.

## PE32+ image checkpoint

`pe32plus_image(machine, code)` is the first Windows image-writing slice of
RFC-0018/A01. It accepts bounded already-lowered bytes and returns one complete
PE32+ image: DOS header and `e_lfanew`, PE signature, COFF machine identity,
the 240-byte PE32+ optional header, and one file/section-aligned executable
`.text` section. `pe32plus_entry_image` pins distinct no-import entry sequences
for `IMAGE_FILE_MACHINE_AMD64` and `IMAGE_FILE_MACHINE_ARM64`.

The writer is Kofun and requires no assembler, linker, system SDK, or import
library. `check-pe32plus.sh` produces both 1,024-byte images twice through a
Kofun Stage 1 bridge, validates every load-bearing field with an independent
parser, proves magic/machine/entry/alignment mutations fail, and executes the
canonical request predicate for unknown-machine, empty, oversized, and
out-of-range-byte refusals. Their hashes live in `SHA256SUMS` beside the ELF
fixtures.

This does not expose a Windows CLI target or claim Windows runtime support or
host execution. Imports, OS authorities, general Core lowering, and matching
Windows-host execution evidence are separate checkpoints. The narrow bridge
exists for the same reason as the ELF bridges below: the current full compiler
does not yet lower List-returning user functions, while Stage 2 still parses
and indexes the canonical writer itself.

## Mach-O 64 image checkpoint

`macho64_image(cpu_type, code)` is the first macOS image-writing slice of
RFC-0018/A01. It returns a complete page-sized Mach-O 64 image with
`MH_MAGIC_64`, the exact x86-64 or AArch64 CPU identity, `MH_EXECUTE`,
`__PAGEZERO`, one executable `__TEXT,__text` section, `/usr/lib/dyld` in
`LC_LOAD_DYLINKER`, a macOS 11 `LC_BUILD_VERSION`, and `LC_MAIN`. x86-64 uses a
4 KiB image and AArch64 uses a 16 KiB image; both place the bounded entry bytes
at file offset 512. `macho64_entry_image` pins distinct return-zero sequences
for the function dyld calls through `LC_MAIN` and imports no library.

The canonical writer is Kofun and requires no assembler, linker, system SDK,
or foreign-language image writer. `check-macho64.sh` produces both images
twice through a Kofun Stage 1 bridge, validates every header, segment, section,
load command, CPU identity, entry offset, and padding byte with an independent
parser, proves five selected mutations fail, and executes the canonical
request predicate for invalid CPU, empty, oversized, and out-of-range byte
inputs. When present, `file` and `llvm-readobj` additionally parse the exact
outputs. Their hashes live in `SHA256SUMS`.

This checkpoint does not expose macOS CLI targets or claim macOS-host
execution. Embedded ad-hoc signing is the separate checkpoint below; OS
authorities, general Core lowering, and matching host execution evidence
remain separate work. The Stage 1 bridge exists only because List-returning
user functions do not yet lower through the full compiler; Stage 2 parses and
indexes the canonical Kofun writer.

## Mach-O ad-hoc signing checkpoint

`macho64_signed_image(cpu_type, code, identifier)` extends the complete x86-64
or AArch64 image with a read-only `__LINKEDIT` segment and
`LC_CODE_SIGNATURE`. The embedded 160-byte SuperBlob contains one version
`0x20400` CodeDirectory with `CS_ADHOC | CS_LINKER_SIGNED`, a bounded ASCII
identifier, SHA-256 type 2, one hash slot for the complete 4 KiB or 16 KiB code
page, and the executable-segment fields. `macho64_signed_entry_image` fixes the
identifier to `kofun`; its images are 4,256 and 16,544 bytes respectively.

Every producing byte is authored in Kofun. The canonical encoder includes its
own big-endian integer encoding and SHA-256 compression/padding implementation;
it does not call `codesign`, a linker, an SDK, a system digest, or a
hand-authored foreign-language image writer to construct the prefix,
CodeDirectory, or page hash. The current bounded bridge translates the Kofun
fixture through the existing C bootstrap because the full compiler does not
yet lower List-returning user functions; that bridge supplies no image-format
constant, signing field, or digest operation. Removing that bootstrap boundary
belongs to the all-Kofun toolchain work. The unsigned image functions above and
their pinned hashes remain unchanged.

`check-macho64-signed.sh` emits both signed images twice, compares the bytes,
pins their SHA-256 hashes in `SHA256SUMS`, runs the canonical request predicate,
and passes them to an independent structural/hash validator. The validator
recomputes each CodeDirectory page hash and proves that header, code,
identifier, embedded-hash, signature-magic, and signature-offset mutations are
refused. When installed, `file` and LLVM additionally identify both exact
architectures, `__LINKEDIT`, and `LC_CODE_SIGNATURE`.

This is an embedded-signature image checkpoint, not macOS runtime evidence. It
does not expose a macOS CLI target, run either image on a matching host, invoke
Apple's signature validation, claim notarization or certificate identity, add
OS authorities, or lower general Core to Mach-O. Those remain separate work.

## AArch64 Native Core v1

The CLI compiles the same deliberately small, target-independent Core through
both registered Linux targets:

```kofun
fn main() {
    print((6 + 1) * 6)
}
```

```sh
./bin/kofun build program.kofun \
    --target aarch64-linux -o build/program-aarch64
./bin/kofun build program.kofun \
    --target x86_64-linux -o build/program-x86_64
```

The shared scalar Native Core accepts exactly one zero-argument `main`, one
`print`, integer literals in `0..65535`, parentheses, `+`, and `*`. Checked
constant analysis must prove every known intermediate value fits that range
and a statically known final integer is two digits. Unsupported input fails
before an output file is written.

## Native user-defined Int functions

Both native backends accept a bounded multi-function Int Core:

```kofun
fn fib(n: Int) -> Int {
    if n < 2 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

fn main() {
    print(fib(20))
}
```

Top-level declarations are collected before bodies are parsed, so forward and
mutual recursion do not depend on source order. Calls support up to six integer
argument registers (`rdi..r9` on x86-64, `x0..x5` on AArch64). Both targets
assign parameters and intermediate values to registers from one shared
analysis (see the allocation contract below); returns come back in the first
result register (`rax` / `x0`),
and every call is resolved as a checked fixup (`rel32` on x86-64, a
26-bit `bl` immediate on AArch64). Both backends lower the same
target-independent parsed program, so the profile supports Int literals,
parameters, direct calls, unary `-`, `+`, `-`, `*`, integer comparisons,
`if { return ... }` guards, expression statements, multiple `print(Int)`
statements in `main`, and explicit or implicit main returns identically.

Runtime Int output covers zero, negative values, and the complete signed
64-bit decimal width. Arithmetic branches to deterministic, per-operator
`error[R010]` diagnostics with the same bytes and exit status on both targets.
AArch64 detects multiply overflow with a `smulh`/sign-bit comparison and
add/sub/negate overflow through the `V` flag. Unknown functions, duplicate
declarations or parameters, wrong arity, more than six arguments, non-Int or
non-Text signatures, missing helper returns, and `-g` are rejected before an
artifact is written. `-g` debug information covers the single-`main` Core on
both Linux targets, and the multi-function profile on neither.

`tests/conformance/functions` runs the same twelve programs under the C11,
direct x86-64, and direct AArch64 adapters, covering ordinary/forward calls,
recursion, mutual
recursion, signed/zero output, the six-argument boundary, register pressure
past the allocatable set, values live across calls, multiple returning
branches, calls in a returned position — including a six-parameter rotation,
which only agrees with the other backends if every argument is computed before
any parameter is overwritten — and floor division and modulo across every sign
combination. AArch64 cross-compiles every case on every host and executes all
twelve under `qemu-aarch64` when it is available.

## Function register allocation

Both function profiles decide where every value lives before they emit a
byte, instead of pushing and popping the native stack for each operand. The
decision is made per function body from two facts: how many evaluation depths
the body uses, and which of those depths can still hold a live value when a
call instruction runs. A depth stays live exactly while the sibling subtrees at
deeper positions are evaluated — an operand is consumed by its parent right
afterwards, and a call boundary is filled from the argument locations before
the `call` — so a depth survives a call precisely when one of those later
sibling subtrees performs one.

That analysis is one implementation over the target-independent parsed program
(`function_expression_calls`, `function_expression_pressure`,
`function_slot_uses`, `function_body_calls`); only the register classes and the
frame sequence differ per target.

| Target | Callee-saved | Scratch | Reserved |
|---|---|---|---|
| x86-64 | `rbx`, `r12`-`r15` | `r10`, `r11` | `rax` and the six SysV argument registers |
| AArch64 | `x19`-`x26` | `x12`-`x15` | `x0`-`x8`, `x9`-`x11`, `x16`-`x18`, `x29`, `x30` |

The callee-saved class holds values live across a call; the scratch class holds
values no call can observe and costs no save at all; the reserved set is never
allocated, so it is always free as the move scratch and the call boundary.
AArch64 stops at `x26` rather than `x28` because the shared Text runtime it
calls preserves `x19`-`x26`, which is the set that is demonstrably preserved
rather than the set AAPCS64 nominally reserves. `x9`-`x11` stay reserved because
the checked multiply and the divide sequences need fixed temporaries, and
`x29`/`x30` are already saved by the existing prologue.

Allocation runs in a fixed order, so two builds of one source always make the
same decisions:

1. evaluation depths that cross a call take callee-saved registers, lowest
   depth first, because no other class can hold them;
2. the remaining depths take scratch registers first and fall back to
   callee-saved;
3. parameters and locals take what is left, lowest slot first. A scratch
   register replaces a binding's store and every reload for free, so a single
   read already earns one. A callee-saved register also costs one save and one
   restore per invocation, so a binding only earns one once it is read more
   than once, and a binding that is never read stays in its frame slot;
4. anything still unplaced spills to a frame slot immediately below the
   locals, in depth order. Spilling is ordinary lowering in the same backend,
   not a fallback to another one: a program the profile accepts stays accepted
   at any pressure.

The frame keeps parameters and locals first, then the evaluation spill slots,
then the save area for exactly the callee-saved registers the body claimed.
Every return path restores that same set at one shared epilogue, and reloading
it never disturbs the result in `rax` / `x0`. Because no evaluation step moves
the stack pointer, a body keeps the 16-byte alignment it was entered with at
every SysV or AAPCS64 call boundary — including nested calls, which the previous
stack-machine lowering could enter with an operand pushed underneath. x86-64
addresses slots at their existing `rbp`-relative displacements; AArch64
addresses them as `[sp, #slot * 8]`, whose unsigned scaled offset reaches the
whole frame rather than the 32 slots the previous signed 9-bit `x29`-relative
form covered.

`check.sh` pins the prologue of a leaf helper that reuses its parameter on both
targets, so the parameter must arrive in a register and be read back from one,
and refuses the byte signatures the previous lowering emitted for every
operand — `mov rax,[rbp+disp32]` + `push rax`, `push rax` + `pop rdi` and
`pop rcx` + `pop rax` on x86-64, and `str x0,[sp,#-16]!`, `ldr x0,[sp],#16`
and `ldr x1,[sp],#16` on AArch64 — across the register, fibonacci, Text, and
overflow images of each target. `native-functions/` in
[`kofun-lang/kofun-benchmarks`](https://github.com/kofun-lang/kofun-benchmarks)
records the measured effect; its `README.md` documents the method and
`results.json` the raw samples.

## Returned calls become branches on both targets

`return f(...)` leaves the frame nothing to do once `f` starts: `f`'s result is
this function's result, and every location the body owns is dead at that point.
Both backends therefore hand the frame over rather than stack a second one on
top of it, so recursion written in a returned position runs in constant stack.
This is one target-independent decision — a returned statement whose value is a
direct call — applied by two instruction encoders.

| Callee | x86-64 | AArch64 |
|---|---|---|
| the enclosing function | assign the parameter locations, `jmp` to the instruction after the prologue | assign the parameter locations, `b` to the instruction after the prologue |
| any other function | fill the argument registers, reload the claimed callee-saved registers, `leave`, `jmp` | fill `x0`..`x5`, reload the claimed callee-saved registers, `mov sp, x29`, `ldp x29, x30, [sp], #16`, `b` |

A call to the enclosing function reuses the frame as it stands, so the
repetition costs neither a frame nor a saved-register round trip. A call to any
other function restores what the body claimed and drops the frame *before*
branching, so the callee runs on the frame this function was entered with and
returns straight to this function's caller — `rsp` at the branch is exactly
where a `call` would have left it, so the SysV 16-byte discipline is unchanged.
Mutual recursion written this way is therefore also constant stack.

Every argument is evaluated into its ordinary location before the first
parameter is overwritten, and no evaluation location is ever a parameter
location, so reassignment is a parallel assignment:
`return fib_loop(n - 1, b, a + b)` reads the old `a` and `b`. Nothing else
changes: a call anywhere but a returned position, and a `return` of anything
but a direct call, is lowered exactly as before.

`check.sh` runs a direct and a mutual recursion three million steps deep under
an explicitly lowered 1 MiB stack limit and requires the exact answers, and
runs a control that recurses just as deep with the call in a non-returned
position and must still die on the stack under the same limit. It also pins the
four hand-off byte sequences — the direct and the cross-function form on each
target — so a regression to `call`/`ret` cannot pass quietly.

## Two front ends, and which one reads a source

`core_compiler.c` contains two independent front ends. The single-`main`
aggregate Core lowers `List[Int]`, UTF-8 `Text`, higher-order `map`/`filter`/
`fold`, and `-g` debug information, but accepts exactly one `print` of a known
value in `10..99`. The function profile accepts several `print` statements,
full signed Int64 output, user-defined functions, and inferred `Int` locals,
but has no `List` and no debug information.

A file that declares more than one function goes to the function profile. A
file that declares only `main` goes to the aggregate Core first and, only if
that Core refuses it, falls through to the function profile. The two accepted
sets are therefore disjoint by construction: nothing that compiles today can
change, which is checked by rebuilding the whole fixture, conformance, example,
and benchmark corpus on both targets and comparing every image byte for byte.
A `-g` build never falls through, because `-g` is the aggregate Core's feature.

When both front ends refuse a single-`main` program the verdict is the Core's,
so the diagnostic keeps the stable `unsupported Core` wording and carries the
function profile's more specific reason.

## Integer division

`//`, `/`, and `%` share `*`'s precedence level in the function profile. `//`
floors toward negative infinity and `%` takes the divisor's sign, matching
`docs/SEMANTICS.md` and the C11 backend's `kofun_floor_div`/`kofun_floor_mod`;
`/` truncates toward zero, matching the compiler built from the frozen
self-host source, the Stage 1 seed, and wasm32. The normative spec's conflicting
Float claim remains explicitly tracked by #687 rather than being settled by
this bounded backend change.

Both hardware divide instructions need guarding, for opposite reasons. x86-64's
`idiv` *faults* on a zero divisor and on the one quotient that is not
representable, and a fault is a signal rather than a diagnostic. AArch64's
`sdiv` never faults: it silently returns zero for a zero divisor and
`INT64_MIN` for `INT64_MIN / -1`, so an unguarded divide there is a wrong
answer instead of a crash. Both backends therefore check before dividing.

A `-1` divisor is the whole of the second case and is answered without
dividing: the quotient is `-left`, whose overflow `neg`/`negs` reports in the
overflow flag, and the remainder is always zero — which is why
`INT64_MIN % -1` is `0` rather than an error. Everything else divides and then
corrects: when the remainder is non-zero and its sign differs from the
divisor's, `//` is one too high and `%` is one divisor short.

The function profile accepts non-negative literal magnitudes through
`INT64_MAX`. x86-64 selects the narrowest supported immediate encoding.
AArch64 preserves the existing low-halfword-first encoding through 32 bits and
extends wider values deterministically with `movk` halfwords. A literal that
fit the old 65535 range therefore emits exactly the bytes it did before.
`INT64_MIN` is written the way the numeric corpus writes it,
`-9223372036854775807 - 1`, because an atom must fit before unary minus
applies. The gate covers the wide encoding boundaries on both targets and
retains the independently constructed `INT64_MIN // -1`, `INT64_MIN / -1`,
and `INT64_MIN % -1` checks.

Arithmetic failures use the same exact per-operator `error[R010]` lines as the
C11 and wasm32 backends. Messages live in the bounded RW data page; only the
operator-specific stubs a program uses enter the RX page, and all stubs share
one write/exit runtime. The native capability entries therefore execute the
same nine-case numeric corpus. A pressure fixture references every trap kind at
once, while the large Set projection guards the one-page RX ceiling.

## Compiler-shaped Text function bridge

Both direct backends additionally lower one bounded Text path: up to two
`Text` parameters in ordinary SysV/AAPCS64 integer registers, a `Text` result
in `rax`/`x0`, direct and forward calls, concatenation, immutable frame-backed
locals, and `print(Text)` in `main`.

```kofun
fn declaration_label(kind: Text, name: Text) -> Text {
    return kind + " " + name
}

fn main() {
    let label: Text = declaration_label("fn", "main")
    print(label)
}
```

The value ABI remains `[byte length: i64][UTF-8 bytes]`. Parameters are
immutable process-lifetime views. A result is either an input/literal pointer
or a newly `mmap`-allocated exact Text object; this slice deliberately provides
no reclamation. Arguments evaluate left to right once, frame size is rounded
to preserve the target ABI's 16-byte call alignment, and every call uses a
checked target-relative fixup. Concatenation checks object-size overflow and
reports `kofun: out of memory` with status 70 through the existing bounded
allocator.

`check.sh` compares ASCII and multibyte UTF-8 fixtures with an independent C11
reference, compares direct and public-CLI artifacts byte for byte across clean
builds, verifies the static ELF shape on both targets, and pins
producer/source/reference/output hashes in
`fixtures/function_text_provenance.txt`. Wrong arity/type/result, missing
return, mutable local, `List[Text]`, loop/file operation, and forced OOM are
explicit negative gates that leave no output artifact. AArch64 execution is
compared with the same observations under `qemu-aarch64` when available.

Both Linux targets also accept local `Int`/`List[Int]` bindings and a
deliberately narrow collection Core:

```kofun
fn main() {
    let values = [1, 2, 3]
    let mapped = map(values, fn(value: Int) => value * 21)
    print(mapped[1])
}
```

List values use the historical native ABI
`[length: i64][element: i64] * length`. Literals allocate writable storage
through a raw Linux `mmap` runtime, indexing executes against that storage,
negative indexes count from the end, and `len` reads the header. An invalid
index writes `kofun: list index out of range` to stderr and exits 1. Allocation
failure writes `kofun: out of memory` and exits 70. `map`, `filter`, and
`fold` execute real generated loops over that storage. `map` allocates an
output List, `filter` records its actual result length, and `fold` carries a
runtime accumulator. Their typed inline `fn` lambdas may use integer
arithmetic, comparisons, parameters, and captured Core locals. The gate
compares bindings and every operation, including their composition, with an
independent C11 implementation.

This remains a closed collection Core rather than general collection
lowering: lambdas are inline and non-escaping, nested higher-order operations
inside a lambda body are rejected, and allocation uses one mmap chunk per
List. x86-64 and AArch64 consume the same parsed expression tree and preserve
the same frame-slot, value-layout, bounds, allocation, and output contracts.
Known List contents remain available to the shared frontend after a local
binding solely for validation: an indexed integer outside the aggregate
Core's `10..99` print boundary is refused before either target writes an
artifact. Runtime list storage and indexing are unchanged.

Both direct targets also implement immutable UTF-8 `Text` values with the
historical native ABI `[byte length: i64][UTF-8 bytes]`. The closed native Core
contains constant Text expressions, so its frontend applies the pinned Unicode
17 database and emits the resulting literal or scalar directly. `+`, `==`,
`!=`, direct Text printing, grapheme-cluster `len`, `chars`, and positive or
negative grapheme indexing execute in the generated ELF. Concatenation is
re-segmented across the join.

`chars` exposes extended grapheme clusters. `bytes` exposes UTF-8 byte values,
and `codepoints` exposes Unicode scalars, both through the existing list ABI.
A Text index outside the grapheme range
writes `kofun: text index out of range` to stderr and exits 1. The gate compares
Arabic, Hebrew, Hindi, Thai, Japanese, Hangul/Jamo, accented Latin, and complex
emoji cases and executes the Text OOM and index-failure paths.

The obsolete `tests/kofun/*.kf` acceptance path no longer exists. The active
Python-free `tests/conformance/list` and `tests/conformance/text` corpora are
registered with both native adapters and execute all 34 cases on x86-64 and,
under qemu, AArch64. General Text bindings/calls beyond the two-argument
compiler-shaped bridge and the Stage 1 compiler port remain open.

The frontend creates one AST; both instruction selectors consume it. The
equivalent canonical Kofun representation is a postfix stream of
`[opcode, operand]` pairs consumed by `x64_native_core_text` and
`a64_native_core_text`. This keeps parsing, precedence, constant validation,
and Core semantics out of the target encoders.

The AArch64 encoder writes 64-bit `MOVZ`, register `ADD`/`MUL`, `UDIV`, `MSUB`,
`STRB`, `MOVK`, and `SVC` instructions as little-endian words. Runtime code
computes the expression, converts the result to ASCII in the RW segment, calls
Linux AArch64 `write` (64), and calls `exit` (93). The ELF header uses
`EM_AARCH64` (`e_machine = 183`), entry `0x4000b0`, and no interpreter or
dynamic section. The function profile adds a stack-machine lowering that also
emits `STP`/`LDP` frames, `BL`/`RET` calls, `STUR`/`LDUR` parameter slots,
`CBZ` guards, flag-setting `ADDS`/`SUBS`/`SUBS(neg)` with `B.VS`, and a
`SMULH`/`ASR`/`B.NE` multiply-overflow check; every fixed instruction word was
cross-checked against `llvm-mc --triple=aarch64`.
The List profile additionally emits frame-backed locals, stack temporaries,
indexed 64-bit loads/stores, generated loop branches, and a leaf Linux AArch64
`mmap` helper. Its failure fixups target exact OOM and list-index diagnostics.

`core_compiler.c` is the C11 bootstrap driver used until the Kofun
compiler can self-compile the complete `List[Int]` encoder. It shares one
frontend across both targets and uses no Python, assembler, linker, or target
cross-compiler when compiling a program.

The deterministic fixture is a 188-byte static `ET_EXEC` image:

```text
0x0000..0x003f  ELF64 header
0x0040..0x0077  RX PT_LOAD (R|X)
0x0078..0x00af  RW PT_LOAD (R|W, zero-filled)
0x00b0..0x00bb  mov eax,60; mov edi,42; syscall
```

The entry point is `0x4000b0`. The RX segment maps the whole 188-byte file at
`0x400000`. The separate RW segment reserves one zero-filled page at
`0x401000`; it has no file bytes. Both segments use 4096-byte alignment.

The second fixture is a 4099-byte image that exercises a compilation-shaped
path rather than only process exit:

```text
Kofun inputs       left=40, right=2
native arithmetic eax = 40 + 2
native conversion div 10; add ASCII '0' to quotient and remainder
absolute fixups    store the two digits at the RW `output` label
raw syscall        write(1, output, 3)
raw syscall        exit(0)
observable result  exact stdout "42\n", empty stderr, status 0
```

Its RX segment ends at file offset `0x00f6`. Its RW segment maps the three
initialized bytes at file offset `0x1000` to virtual address `0x401000` and
reserves one page.

The third fixture is a compact 231-byte Core-shaped image:

```text
Core expression     (6 + 1) * 6
forward call fixup  _start -> main
message fixup       RIP-relative lea -> "42\n"
observable result   exact stdout "42\n", empty stderr, status 42
```

Unlike the page-backed print fixture, this image keeps its message in the RX
segment. It demonstrates deterministic multi-label rel32 resolution for both a
forward `call` and a RIP-relative data reference.

## Linux syscall intrinsics

`stdlib/linux_x86_64/abi.kofun` declares `__linux_syscall0` through
`__linux_syscall6` and builds its entire `raw_*` layer — `raw_read`,
`raw_write`, `raw_open`, `raw_close`, `raw_exit`, and the typed `SysResult`
wrappers above them — on those seven names. Nothing implemented them, so none
of that layer ran; the gates that appeared to cover it check that the
declarations exist with `grep`, which a declaration satisfies whether or not
anything can execute it. The x86-64 function profile now lowers them.

The names are recognised at the call site rather than declared in the source
under compilation: the native Core has no import path, and the stdlib
declaration is the specification they answer to. Defining a function under one
of those names is refused, because the call site resolves the intrinsic first
and the definition would be unreachable while looking authoritative.

`__linux_syscallN` takes `N + 1` values — the number, then the arguments — so
the six-argument form takes seven, one more than a native Core function may
take. The intrinsic therefore carries its own argument placement instead of
reusing the SysV call boundary:

| value | register |
|---|---|
| syscall number | `rax` |
| argument 1 | `rdi` |
| argument 2 | `rsi` |
| argument 3 | `rdx` |
| argument 4 | `r10` |
| argument 5 | `r8` |
| argument 6 | `r9` |

The fourth argument is the one place this differs from an ordinary call, which
would use `rcx`. `syscall` overwrites `rcx` with the return address and `r11`
with the saved flags, so the kernel ABI moves that argument to `r10`.

`r10` is also the only one of those registers this backend ever allocates, so
it is filled last: every other value is read out of its home before `r10` is
written. The emitter proves that premise on each call rather than assuming it.

The clobber is handled where the register file is decided, not at the call.
`function_expression_calls` reports the intrinsic as a call, which is what moves
every value live across it into the callee-saved class the kernel preserves —
including anything that would otherwise have sat in `r11`.

The result is whatever `rax` held, unchanged. A negative return is an errno in
the form `syscall_result` in `abi.kofun` already expects, so the backend
classifies nothing.

AArch64 enters the kernel through a different boundary — `x8` carries the
number — and is a separate checkpoint, so `--target aarch64-linux` diagnoses a
program that uses the intrinsics instead of emitting an image in which they
mean nothing.

`check.sh` executes them. `fixtures/function_syscall_probe.kofun` is the `raw_*`
layer's own bodies: it exercises all seven arities and, for the six-argument
`mmap`, changes exactly one argument at a time so the kernel's rejection names
the register that argument travelled in. It ends by writing 32 bytes of a fresh
anonymous mapping to standard output, which the kernel guarantees is zeroed, so
the gate compares bytes rather than trusting a returned count.
`fixtures/function_syscall_exit_status.kofun` leaves with status 97 and an empty
standard output, which is how the gate knows the process left through the
syscall and not through the profile's epilogue.
`fixtures/function_syscall_live_values.kofun` keeps two products live across the
instruction and prints an exact number, so a value lost to the clobber is a
wrong answer instead of a crash.

## Opt-in debug information

The general Native Core CLI accepts `-g` for both Linux targets:

```sh
./bin/kofun build source.kofun \
  --target x86_64-linux -g -o build/program
./bin/kofun build source.kofun \
  --target aarch64-linux -g -o build/program-aarch64
```

The frontend retains source lines on parsed expression nodes. Each lowering
records the exact instruction offset for each distinct line, then the shared
metadata builder appends non-allocating ELF sections:

```text
.text           executable Core code
.data           output buffer
.debug_abbrev   DWARF v4 compile-unit and subprogram declarations
.debug_info     source-specific Kofun compilation unit and `main` function DIE
.debug_line     emitted instruction addresses mapped to parsed source lines
.debug_str      producer, source path, and function name
.symtab/.strtab `main` function symbol
.shstrtab       ELF section names
```

Without `-g`, the compiler follows the original release path: a 4,099-byte
static ELF with no section table. The gate compares the release artifact to its
pre-debug SHA-256 and compares every loaded byte after the ELF header with the
debug image. Debug metadata therefore cannot change the executable code, data,
entry point, or `PT_LOAD` layout.

`core_compiler.c` mirrors the generic `dwarf_debug_*_for` builder in canonical
`encoder.kofun`; it does not maintain a second fixture-specific DWARF layout.
The compact historical fixture remains available as an independent metadata
regression:

```sh
sh bootstrap/native/emit-fixture.sh \
  -o build/core-answer-release
sh bootstrap/native/emit-fixture.sh \
  -g -o build/core-answer-debug
```

The first command reproduces the unchanged 231-byte release image with no
section headers. The `-g` command emits a 1,360-byte image with DWARF while
leaving the executable code, read-only message, entry point, and segment layout
unchanged. All layout and DWARF bytes are authored by `encoder.kofun`; the
current Stage1-compatible packed bridge only transports those bytes until
Stage1 can compile the encoder's list operations.

`check.sh` requires `readelf` and validates every section, the source path,
`main` `DW_TAG_subprogram`, symbol, and exact line rows of a CLI-built program.
When `gdb` is installed, a batch session breaks at `main`, shows Kofun line 3,
steps to line 4, and verifies a named Kofun `main` backtrace.

Debug Native Core currently admits exactly one function, `main`, so one
function DIE is complete for every debug-accepted program. The multi-function
Int profile rejects `-g` until lowering adds one DIE and symbol for each emitted
function.

AArch64 carries the same contract, not a second one. The AArch64 lowering
records a row at the same points its x86-64 counterpart does — the first
instruction of a literal and the operation that follows both operands — so both
targets describe the same source lines in the same order, each at its own
instruction addresses, and every AArch64 row lands on a 4-byte instruction
boundary. `check.sh` validates the AArch64 sections, `main` symbol and DIE,
compilation-unit source path, and decoded line rows unconditionally, pins the
debug image's SHA-256, and compares the release and debug loaded bytes. Under
`qemu-aarch64` it also proves the debug image observes exactly what the release
image observes; when the emulator's gdbstub and an AArch64-capable GDB are both
present it breaks in Kofun `main`, steps to the next mapped line, and checks the
named frame, and reports an explicit skip otherwise. Missing tooling never skips
the structural validation.

The AArch64 List/Text Core records no source-line rows yet, so `-g` there is an
explicit rejection that writes no artifact. Mach-O debug formats and
variable-location DIEs remain separate future work.

## Labels and fixups

`encoder.kofun` owns fixup resolution. `patch_u32_le` deterministically rebuilds
an image with one little-endian field replaced. `resolve_abs32_fixup` resolves
an image-base-relative label plus addend; `resolve_rel32_fixup` resolves a
signed PC-relative displacement. `resolve_rel32_fixups` validates label and
fixup tables before applying a deterministic sequence of relocations.

The page-backed print fixture uses three absolute fixups: the tens store, the
ones store, and the buffer argument to `write`. The compact Core fixture
executes both forward rel32 fixups and checks their resolved bytes.

The x86-64 encoder also provides a rel32 jump placeholder for the next
control-flow lowering step. No assembler or linker participates in any
fixture.

## Executable gate

The compatibility Stage 1 seed cannot compile lists, general function calls, or
file output. The Stage 2 C11 Core now handles bounded Int function calls, but
does not compile this List-heavy encoder. Therefore
`fixtures/exit_42.rle.kofun` is an intentionally narrow Stage1-Core bridge.
`fixtures/print_sum_42.rle.kofun` is the corresponding bridge for
`elf64_print_sum_image(40, 2)`, and
`fixtures/core_answer.rle.kofun` bridges `elf64_core_answer_image()`. Each
emits a run-length-encoded byte stream whose expansion is exactly the image
returned by its canonical encoder function.

`check.sh` compiles and runs the release bridges and debug packed bridge with
Kofun, transports their numeric streams to raw bytes using POSIX shell, compiles
Native Core v1 through both CLI targets, checks image hashes and ELF/DWARF
metadata, inspects resolved fixups and instructions, and executes every
host-compatible result:

```sh
sh bootstrap/native/check.sh
```

When `qemu-aarch64` (or `qemu-aarch64-static`) is installed, the gate executes
the AArch64 scalar, function, List, and Text differentials and compares exact
status, stdout, and stderr with the C11/x86-64 observations. Without qemu it
reports an explicit execution skip while still building List and Text
success/failure images twice and validating deterministic bytes, ELF metadata,
encoded instructions, and x86-64/reference parity.

The shell does not choose headers or instructions. Those values are authored
in Kofun and mirrored by the bootstrap seed. No Python, assembly, or
linker participates.

## Honest boundary

Implemented here:

- deterministic ELF64 and program-header byte encoding in Kofun;
- deterministic PE32+ DOS/COFF/optional/section-header byte encoding in Kofun
  for x86-64 and AArch64, with no imports, SDK, assembler, or linker;
- deterministic Mach-O 64 header/segment/section/load-command encoding in
  Kofun for x86-64 and AArch64, with no imported library, SDK, assembler, or
  linker;
- deterministic embedded Mach-O ad-hoc SuperBlob/CodeDirectory encoding and
  SHA-256 page hashing in Kofun for x86-64 and AArch64;
- x86-64 `mov r32, imm32` and `syscall` encoders;
- deterministic absolute and PC-relative label/fixup resolution;
- raw `write(1, address, length)` and `exit(status)` sequences;
- a shared Native Core parser/AST for x86-64 and AArch64 Linux;
- direct AArch64 instruction encoding and static `EM_AARCH64` ELF output;
- the public `build --target aarch64-linux` CLI path;
- native lowering of the fixture expressions `40 + 2` and `(6 + 1) * 6`;
- direct x86-64 and AArch64 Int function calls with up to six arguments,
  results, forward references, recursion, mutual recursion, and
  comparison-guarded returns from one shared parsed program;
- checked `+`, `-`, `*`, and unary negation in the function profile, with an
  identical overflow trap on both targets;
- general signed Int64 decimal output for function-profile `print`;
- bounded x86-64 and AArch64 Text function parameters/results, direct/forward calls,
  concatenation, one immutable local, and `print(Text)`, with deterministic
  provenance and independent C11 differential evidence;
- registered function conformance coverage with 12/12 cases executed by C11
  and native x86-64, and by native AArch64 under `qemu-aarch64`;
- x86-64 and AArch64 `List[Int]` literal, `len`, and positive/negative indexing
  lowering;
- x86-64 and AArch64 local `Int`/`List[Int]` bindings with frame-backed
  variable loads;
- generated `map`, `filter`, and `fold` loops with typed inline Int lambdas on
  both Linux targets;
- raw target-specific Linux `mmap` aggregate allocation with identical OOM and
  bounds diagnostics;
- x86-64 and AArch64 UTF-8 Text literals, concatenation, equality, grapheme
  `len`, and positive/negative grapheme indexing;
- `chars`, explicit byte/codepoint views, and Text/Bool printing through the
  shared aggregate ABI on both targets;
- registered Python-free Text conformance coverage with 21/21 cases executed by
  the native x86-64 and, under qemu, AArch64 adapters;
- registered Python-free List conformance coverage with 17/17 cases: 13 execute
  and four are refused before execution by native x86-64 and, under qemu, the
  AArch64 adapter;
- two-digit integer-to-ASCII conversion for the shared scalar fixture;
- distinct RX and RW mappings;
- x86-64 lowering of `__linux_syscall0` through `__linux_syscall6`, so the
  `raw_*` layer `stdlib/linux_x86_64/abi.kofun` declares executes: all seven
  arities, each kernel-ABI argument register observed by a rejection that names
  it, negative errno returned unchanged, an exact exit status, bytes of a
  mapped page on standard output, and values held live across the clobber;
- three end-to-end Linux x86-64 executable artifact gates;
- opt-in section headers, symbols, and DWARF v4 line/function information for
  arbitrary source accepted by the general x86-64 and AArch64 Native Core CLI.

Still open:

- replacing the C11 Native Core driver after lists and calls
  self-compile;
- general local bindings and statement/control-flow lowering inside
  user-defined functions;
- conditional branches, allocator reuse/reclamation, macOS signature
  validation and host execution, Windows runtime and host execution, CLI
  target admission, and additional targets;
- first-class/nested collection lambdas and general collection types;
- broader Text bindings/calls and the Stage 1 compiler port;
- variable/location DIEs, multi-function debug information, and AArch64
  List/Text debug rows.

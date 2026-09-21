# wasm32 arithmetic and bounded Int function Core

This directory is an executable first slice of issue #26. The seed compiler
parses Kofun source and writes a standard WebAssembly binary module directly;
it does not invoke Clang, LLVM, a C backend, or a text-to-Wasm assembler.

`--target wasm32` names an architecture *and* a host binding, and the name says
only the first half: it selects the bounded numeric binding described below —
`main(): void` against `kofun.print_i64` and `kofun.panic` — and it will keep
selecting it. The accepted `kofun-wasm-host-abi-v1` aggregate binding is a
different target name, `wasm32-hostabi1`. That profile emits its checked
object arena and the bounded Text/List slices below. List-bearing sources use
the separate bounded frontend documented here without changing bare `wasm32`
or the Text-only module bytes.
`spec/wasm-host-profile-v1.md` decides that split and
`sh spec/wasm-host-profile-v1/check.sh` holds this target to it.

## Aggregate arena profile

The first executable aggregate slice builds an empty entry point:

```sh
./bin/kofun build bootstrap/wasm/fixtures/hostabi1_empty.kofun \
  --target wasm32-hostabi1 -o build/hostabi1-empty.wasm
node spec/wasm-host-abi-v1/hostabi.mjs module \
  build/hostabi1-empty.wasm
```

The module exports one fixed 64-KiB linear memory, immutable
`kofun_abi_version = 1`, `kofun_start(i32)`, and
`kofun_alloc(i32, i32) -> i32`. The arena begins at offset 1024, preserving
zero as the failure/null reference and the lower region for compiler-owned
objects. Allocation is a deterministic bump: positive power-of-two alignment
is checked before rounding, size/address arithmetic is bounded before the
cursor changes, and capacity exhaustion returns zero. Memory never grows and
an allocation never writes or publishes an object by itself. A later lowering
that requires an allocation is responsible for calling the v1 `abort(2,
detail)` import when the zero result cannot be handled.

`object_arena.h` contains the single little-endian u64 header encoder for both
`Text.byte_length` and `List.length`. `object_arena_check.sh` compares it with
every header in the recomputed wasm32 boundary vectors, exercises invalid and
exhausting allocations under a real engine, and proves failures leave the
cursor and memory unchanged. The allocator itself makes no value capability
claim; Text lowering consumes it without adding a second arena.

## Bounded Text profile

`wasm32-hostabi1` accepts a deliberately small Text-only function language:
UTF-8 literals, immutable local bindings, zero-to-six direct `Text`
parameters, direct `Text` results, and `print(Text)` observation through the
v1 `text_out` import. Empty and non-ASCII literals are ordinary non-null
objects. Each evaluation requests exactly `8 + byte_length` bytes with
alignment 8 from the checked arena above, writes the little-endian u64 header,
then writes the UTF-8 payload. A zero allocation calls
`abort(2, object_size)`; no partial reference is published.

The slice has no escapes, concatenation, indexing, mutation, interning,
indirect calls, or implicit conversion. Invalid UTF-8 and every unsupported
operation are compile failures and leave no artifact. Bare `wasm32` does not
enter this frontend and retains its pinned legacy bytes.

Run its focused gate with:

```sh
sh tests/wasm-text-v1/check.sh
```

The gate validates the module with the accepted host contract before
instantiation, derives header/payload bounds from freshly recomputed wasm32
vectors, decodes `text_out` fatally, compares observations with native x86-64,
and checks deterministic and sanitized builds plus allocation exhaustion.

## Bounded List profile

List-bearing `wasm32-hostabi1` sources extend that reference slice with
`List[Int]` and `List[Text]` literals, immutable locals, `len`, checked integer
indexing, and zero-to-six direct reference parameters/results. Lists carry the
same little-endian u64 header as Text. Their wasm32 payload stride is
recomputed by AggregateLayout v1: 8 bytes for Int and 4 bytes for a Text
reference. Empty lists are non-null objects and require an explicit element
type when no surrounding signature supplies one.

`print(List[Int])` and `print(List[Text])` borrow through `list_int_out` and
`list_text_out`. Negative and upper-bound indices call `abort(1, index)` and
then become unreachable, so a host that returns from `abort` still cannot
read or publish a value. Append, mutation, nested lists, views, and host
retention remain outside this bounded profile and fail before an artifact is
written. The existing Text-only module keeps its smaller `abort`/`text_out`
import surface, and bare `wasm32` keeps its pinned bytes.

Run the focused List gate with:

```sh
sh tests/wasm-list-v1/check.sh
```

The gate derives headers, alignments, and strides from freshly recomputed
wasm32 vectors; observes both list imports through a fatal UTF-8 reference
host; compares `len` and valid indexing with native x86-64; and checks bounds
aborts, deterministic/sanitized builds, transactional refusal, and legacy
wasm32 bytes.

## WASI command memory

`wasm32-wasi-command1` (#1296) emits the minimal Preview 1 command shape: one
exported memory, `kofun_wasi_command_version`, `_start`, and no imports,
because a program that reaches no checked operation must emit none. With a
`--wasi-manifest`, the manifest's `memoryPages` becomes the module's memory
maximum (#1297); without one the module keeps its single fixed page.

`wasi_command_memory.h` is the adapter-private storage the operation slices
(#1298–#1301) will hand to `wasi_snapshot_preview1`: byte sequences
`{ u64 length; u8[] }`, pointer vectors `{ u64 count; u32[] }`, iovec vectors
`{ u64 count; { u32 buf; u32 len }[] }` — all under the AggregateLayout v1
header above, 8-aligned — plus a checked UTF-8 conversion and the
command-lifetime bump allocator behind them. The allocator never writes,
grows the memory on demand up to the manifest's ceiling and returns zero past
it with nothing changed; `scope_enter`/`scope_leave` bracket one host call and
zero everything allocated inside it, so a retained guest pointer reads zeros.
Contract violations — a bad alignment, an index past a count, a non-object
reference, a buffer outside the arena — trap before any mutation.

Nothing in `build` carries the runtime yet: no host operation is reachable in
this slice, and emitting it unreferenced would widen the module's declared
surface past its behaviour. The gate drives it through the probe module
instead:

```sh
build/wasm-core/kofun-wasm-core --wasi-command1-memory-probe build/probe.wasm 4
sh tests/wasm/wasi-command-memory/check.sh
```

The gate computes the layout three ways (JavaScript, a C probe against the
header, the running module), executes every carrier under the engine with
canary-filled memory, and shows each of four announced emitter seams
(`KOFUN_WASM_CORE_FAULT=memory-*`) caught by its own property. None of this is
the public Kofun `Bytes` identity and none of it is a capability claim.

Build and run the sample:

```sh
./bin/kofun build examples/wasm_arithmetic.kofun \
  --target wasm32 -o build/arithmetic.wasm
node bootstrap/wasm/run.mjs build/arithmetic.wasm
```

Build the Kofun-authored browser sample and serve it without package
installation:

```sh
sh examples/wasm-browser/build.sh
node examples/wasm-browser/serve.mjs build/wasm-browser
# open http://127.0.0.1:8080/
```

`app.kofun` is the program. It is compiled directly to `app.wasm`; `main.mjs`
is only the generic browser host that maps `print_i64` to text content and
checked traps to diagnostics. The host waits for the sample element to enter
the viewport before it fetches or instantiates the module. Browsers without
`IntersectionObserver` load it immediately.

The module exports `main(): void` and imports two host functions:

- `kofun.print_i64(value: i64)` observes each Kofun `print`;
- `kofun.panic(code: i32)` reports a checked arithmetic failure.

These imports are ordinary WebAssembly host bindings. `run.mjs` is the
non-skipping Node host used by the differential gate. The browser sample
supplies the same bindings and renders the two Kofun-produced values into an
`aria-live` output element.

## Supported source slice

The current profile supports a zero-argument `fn main`, immutable `Int`
bindings, `print`, Int64 literals and variables, parentheses, unary `+`/`-`,
and checked `+`, `-`, `*`, `//`, and `%`. `/` is not defined on `Int` and is
refused with a diagnostic (#687), exactly as both native targets refuse it.
Modulo and the integer quotient follow the same floor semantics and stable
runtime diagnostics as the C11 Stage 1 backend. Parenthesized expressions,
unary operators, and call argument lists share one deterministic 256-level
nesting limit: 128 nested parentheses combined with 128 unary operators are
accepted, while any combined depth of 257 is rejected. This makes hostile
inputs fail with a compile diagnostic instead of exhausting the C stack.

On top of that arithmetic the profile lowers a bounded Int function Core:
zero to six `Int` parameters and an `Int` result, direct calls in expression
position, forward calls, recursion and mutual recursion, comparison-guarded
early returns with `==`, `!=`, `<`, `<=`, `>`, and `>=`, and `let` bindings
inside a function body. Every top-level signature is collected before any body
is lowered, so a call resolves the same whether its callee is declared above or
below it. A call evaluates its arguments left to right and exactly once. This
is ordinary direct-call recursion — no tail-call proposal instruction, host
callback, or JavaScript trampoline participates — so recursion depth is
whatever the engine stack allows and the language makes no promise about it.

### Encoding

Module function indices start after the two host imports, and the declaration
table fixes them before any body is emitted. The module keeps exporting
`main(): void`, so hosts need no ABI change: when the source `main` declares no
result it *is* the export, and a program that is one `fn main` still emits the
same bytes it did before functions existed. Only when `main` declares
`-> Int` does the module gain a generated wrapper that calls the internal
`main` and drops its `i64`. Parameters occupy WebAssembly locals in source
order; expression temporaries follow them deterministically. A Kofun `Bool`
is never a value here — a comparison exists only as the `i32` branch condition
of one `if`.

### Refused, with no artifact written

Unknown functions, duplicate declarations, duplicate parameters, wrong call
arity, a seventh parameter or argument, non-`Int` parameters, a helper without
an `-> Int` result, an `-> Int` body that does not end in `return`, function
values, and calls through a binding are all compile failures. Each writes a
stable source-located diagnostic to stderr, nothing to stdout, and no `.wasm`
file. `bootstrap/wasm/fixtures/` holds one fixture per refusal and
`check.sh` asserts every one of them.

`tests/conformance/backends/wasm32-node.sh` registers the target against the
shared numeric and functions corpora. All nine numeric cases and all twelve
function cases execute under the Node WebAssembly engine and compare exact exit
status, stdout, and stderr with the C11 observations.

Run the mandatory gate:

```sh
task wasm
```

## Honest boundary

The legacy `wasm32` binding remains a bounded Int target and its module bytes
are unchanged. The separate `wasm32-hostabi1` binding has the checked
linear-memory arena and bounded Text/List lowering described above. Neither
profile has `else`, loops, mutation, tables or indirect
calls, no closures or function values, no user-declared imports, no WASI
profile, no general JavaScript value conversion, no direct DOM declarations in
Kofun, no debug information, and no optimizer. Functions are bounded at six
`Int` parameters and one `Int` result; anything wider is refused rather than
silently narrowed. The standard module loads in both Node and browsers, the
numeric and function differential corpora are executable, and the sample
renders Kofun output in a page. Wider language coverage should be tracked
independently rather than implied here.

`spec/wasi-command-profile-v1.md` reserves `wasm32-wasi-command1` and makes
its command-capability boundary executable as a reference model, and
`spec/wasi-command-projection-v1/PROFILE.md` decides which checked source
operation reaches which import. This backend emits the command shape and the
command-memory carriers described above, imports no
`wasi_snapshot_preview1` function, refuses every host operation at its span,
and claims no WASI capability.

When linear-memory objects do arrive, their byte layout is already decided:
`spec/aggregate-layout-v1.md` defines the `wasm32` target with 4-byte
references and 8-byte `u64` object headers, with golden vectors in
`spec/aggregate-layout-v1/examples/core.wasm32.json`. That contract exists
specifically so this target is not given 64-bit references to match the
native backend's bytes; `Int` stays signed 64-bit here as everywhere.

The host boundary those objects will cross is decided too:
`spec/wasm-host-abi-v1.md` pins `kofun-wasm-host-abi-v1` — the import
allowlist with exact wasm signatures, the required exports, the `Text` and
`List` representations recomputed from the layout target, and the rule that
a host may not retain a guest pointer past the call it was passed to. That is
a different host binding than the two imports above. Bare `wasm32` still
exports `main(): void` and imports `kofun.print_i64` and `kofun.panic`; the
separately named profile consumes the accepted contract without changing that
legacy surface.

How a build reaches it is decided too, and is no longer left to the reader:
`spec/wasm-host-profile-v1.md` puts the host ABI in the target name. The
aggregate profile is `--target wasm32-hostabi1`; bare `--target wasm32` stays
on the numeric binding and is not deprecated, so nothing here has to migrate.
A toolchain predating the arena slice refuses the profile name with
`kofun: unsupported target:` and writes no module. Current builds preserve the
import-free arena-only module for an empty source; Text-bearing sources add
only the v1 `abort` and `text_out` imports, while List-bearing sources import
those plus `list_int_out` and `list_text_out`. The two bindings are told apart on the module
bytes before anything is instantiated: legacy modules import from `kofun` and
export one function, `main`, while every import a v1 module has comes from
`kofun:host-abi-v1`, while its immutable `kofun_abi_version` global identifies
even the arena-only module that needs no import yet. A module is never both.

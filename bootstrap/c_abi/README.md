# C ABI profile

The C ABI profile is an explicit, dynamically linked interoperability path:

```sh
./bin/kofun build app.kofun --backend c --c-abi \
  --link-library /absolute/path/to/libexample.so -o app
```

It is separate from Kofun's direct native backend. The direct native path
continues to emit a static ELF without a C compiler, linker, libc, or dynamic
loader. `--c-abi` deliberately invokes the configured C compiler and system
linker, and foreign code is outside Kofun's memory-safety guarantees.

## Supported source slice

The checked profile accepts:

- `repr(C) struct` declarations with scalar or previously declared struct
  fields;
- `extern "C" fn` declarations;
- `Unit`, `Bool`, fixed-width integer/float types, `CInt`, `CUInt`, `CLong`,
  `CULong`, `CSize`, `CStr`, `CBytes`, and declared structs at the boundary;
- foreign calls, positional struct construction, immutable `let`, scalar
  `print`, field access, and integer `return` inside one `fn main()`.

The current ABI target is 64-bit Linux LP64. Generated C contains static
assertions for primitive widths and every generated struct's size and field
offsets. The host C compiler performs the actual platform ABI lowering,
including register/stack argument classification and aggregate pass/return.

This slice does not yet support callbacks, variadic declarations, managed
Kofun values, borrowed views, foreign exceptions, ownership transfer, or
Windows ABIs. `CStr` accepts only a double-quoted static string; it does not
make managed text ABI-safe. A static string may be passed to `CBytes`, but the
callee must use its separate `CSize` length and must not retain the pointer.

`--link-library` is repeatable and accepts only an existing library file. Kofun
canonicalizes it to an absolute path and passes it as one compiler argument;
raw linker flags are not accepted. A shared object therefore produces a
dynamic ELF, while an archive can be selected explicitly. This input is a
native-code trust boundary.

`compiler.c` is the active canonical implementation. The current
bootstrap Kofun Core cannot yet express and lower this record-rich parser, so
the compiler remains in the temporary C11 trusted base. A Kofun-written
replacement is a later bootstrap milestone; this profile does not claim one.

## Verification

```sh
sh bootstrap/c_abi/check.sh
```

The active acceptance gate requires `rustc`; an unavailable Rust compiler is
a failure, not a skip.

The gate always checks compiler determinism, malformed-source rejection, libc
`puts`, and linker-option rejection. It also builds a Rust `cdylib`, passes and
returns a `#[repr(C)]` struct from Kofun, runs a C caller against the same
function, compares their output byte-for-byte, and checks the Kofun
executable's dynamic dependency table.

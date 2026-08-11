# Linux x86-64 syscall contract

Status: canonical Stage 2 standard-library source; not connected to Stage 1.

## Kernel ABI

The native emitter lowers `__linux_syscall0` through `__linux_syscall6` to the
x86-64 `syscall` instruction.

| value | register |
|---|---|
| syscall number | `rax` |
| argument 1 | `rdi` |
| argument 2 | `rsi` |
| argument 3 | `rdx` |
| argument 4 | `r10` |
| argument 5 | `r8` |
| argument 6 | `r9` |
| return value | `rax` |
| clobbered | `rcx`, `r11`, flags |

Every argument and the return value is one signed 64-bit Kofun `Int`.
User-space addresses must be canonical and non-negative. The emitter must not
insert a libc call, inspect thread-local `errno`, or translate the return.

The x86-64 function profile of `bootstrap/native/core_compiler.c` implements
this table, and `bootstrap/native/check.sh` executes it: all seven arities run,
and each argument register is observed by a kernel rejection that could only
have come from that register. Every other backend still declares these names
without lowering them, so this contract is executable on x86-64 only. AArch64
enters the kernel through a different boundary and refuses the program rather
than emitting one whose intrinsics do nothing.

Linux reports syscall failure directly as a value in `-4095 .. -1`.
`syscall_result` is the single normalization point:

```text
raw in -4095 .. -1  -> Err(SysError(operation, -raw))
all other values     -> Ok(raw)
```

Consequently public functions return `SysResult[T]`; a raw errno integer is
never a public error channel. `SysError.errno` stores the positive Linux errno
number so it can be matched without platform-global state.

## Trusted surface

Only `linux_x86_64/abi.kofun` may declare or invoke:

- `__linux_syscall0` through `__linux_syscall6`;
- stable address views for `Text` and `Bytes`;
- unaligned byte and signed 64-bit loads/stores used by kernel structs;
- zero-initialized byte-buffer and UTF-8 byte-buffer allocation.

An address view is valid only for the dynamic extent of the syscall. The
backend must pin the source managed value for that duration. `Text` is presented
as UTF-8 followed by one NUL byte. Mutable byte-buffer views require `edit`.

All other files are ordinary Kofun and must not contain `trusted` declarations.

This rule governs the standard library, which is what `tests/verify.sh`
enforces over `stdlib/`. The backend's own execution fixtures under
`bootstrap/native/fixtures/` name the intrinsics directly, because proving that
the lowering runs is the one job that cannot be done through the wrapper.

## Ownership and errors

`File`, `Socket`, `Epoll`, and `MemoryMap` are affine resources.

- `file_close`, `socket_close`, `epoll_close`, and `memory_unmap` take ownership.
- Scope cleanup uses the corresponding consuming function and discards its
  result.
- A consuming close is never retried. On Linux the descriptor may already have
  been released even if `close` reports `EINTR`; retrying could close a reused
  descriptor.
- `read`, `write`, `accept4`, `epoll_wait`, `nanosleep`, and `getrandom` may
  return `EINTR`. Exact/high-level helpers retry; one-shot wrappers preserve the
  error value.
- Short reads and writes are success. `file_write_all` loops until complete.
  `file_read_exact` returns `UnexpectedEof` if a successful read yields zero
  before the requested buffer is full.

`MemoryMap` owns exactly `[address, address + length)`. A successful
`memory_unmap` consumes it. The allocator source requests anonymous private
pages with `mmap` and releases them with `munmap`; it never assumes libc or a
process break.

## Structures shared with the native emitter

All layouts below are Linux x86-64, little-endian:

- `timespec`: 16 bytes, signed seconds at offset 0 and nanoseconds at offset 8.
- `epoll_event`: 12 packed bytes, unsigned event mask at offset 0 and user data
  at offset 4.
- `stat`: an opaque, zeroed 144-byte output buffer in this seed. Field decoding
  will be versioned separately; callers cannot fabricate or retain its address.
- socket addresses and socket-option values are caller-owned byte sequences.
  Their addresses are borrowed only for the syscall.

The native backend must reject another target triple rather than silently using
these numbers or layouts.

## Issue #23 fixture

`tests/file_roundtrip.kofun` is the semantic fixture. It creates a file, writes
a fixed byte sequence, seeks to offset zero, reads it back, compares it, and
explicitly closes the resource. Its expected output is
`syscall-file-roundtrip: ok`.

Stage 1 cannot yet lower the ADTs and trusted intrinsics in that source, so
`tests/file_roundtrip_native.packed.kofun` is its audited Stage1-Core native
bridge. Each output pair contains up to six little-endian ELF bytes and its byte
count. The image performs raw `open`, `write`, `lseek`, `read`, and `close`,
checks syscall returns and the read-back bytes, and exits nonzero on every
failure path. It has separate RX and RW load segments.

`tests/verify.sh` compiles the bridge with Kofun, transports its numeric stream
to an ELF file, verifies the image hash and metadata, and first forces `open` to
return `-EISDIR` to prove the native failure path exits 1. It then executes the
successful round-trip, compares the output, observes the six-byte fixture, and
removes that fixture. Shell code does not select or generate ELF headers or
x86-64 instructions.

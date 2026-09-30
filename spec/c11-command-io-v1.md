# C11 Stage 2 command I/O v1

The bounded host-boundary operations by which a program compiled through the
C11 Stage 2 Core path receives its operands, reads standard input, writes a
line to standard error, and reads past the 65,536-byte `Bytes` ceiling in
bounded chunks. This is the decision recorded on
[#1665](https://github.com/kofun-lang/kofun/issues/1665) (2026-09-27).

**Every normative statement names the gate that fails if it is false.**

## Posture

A C11 command-I/O operation is a **bounded host-boundary operation with no
authority**, recorded the way [`bytes-bounded-v1.md`](bytes-bounded-v1.md) §8
records `read_file`. It is not a language capability. The exception retires when
the `#1243 → #1244/#1246 → #1536` authority chain lands and a C11
arguments/stdio grant derived from `RootAuthority` exists (the grant #1293
option A describes). Until then #1666 and #1667 do not wait on #1536.

## Source surface (#1666, gate `task command-operands`)

The three operations #1666 lowers on the C11 Stage 2 Core path are named here
so the specification and the pair cannot drift into different spellings:

- `stage2_command_operand_count() -> Int` — the operand count, including
  `argv[0]`;
- `stage2_command_operand_text(index: Int) -> Text` — one operand;
- `stage2_command_stderr(text: Text) -> Int` — the standard-error line's
  status, `0` on success.

Their runtime refusals are R034 (count over 256), R035 (index out of range),
R036 (operand over 255 bytes), and R037 (line over 255 bytes). `args()` keeps
its own `List[Text]` disposition and is not an operand alias.

## Operands (#1666, gate `task command-operands`)

- **An operand is `Text`.** A normative program observes operands as `Text`
  values; a file operand is passed straight to `read_file`, which takes `Text`.
- **A program receives at most 256 operands, each at most 255 bytes.** The
  per-operand bound is the `Text` profile's, not RFC-0014's 65,536; the larger
  RFC-0014 figures are deferred until a bounded `List[Bytes]` exists.
- **`argv[0]` is observable.** The digest CLI's `<program>:`-prefixed stderr
  line is the gate that reads it.
- **An operand over either bound is a named refusal, never a truncation.**

## Standard input (#1667, gate `task bytes-read-stream`)

- **Standard input is one bounded input stream, read by the same chunk
  operation as §"Reads past the ceiling".** End of input is a zero-byte chunk;
  a read error is a named diagnostic.
- **The `-` spelling is a tool convention, not the language's.**

## Standard error (#1666, gate `task command-operands`)

- **A program writes a `Text` line of at most 255 bytes plus a terminating
  `\n` to file descriptor 2.** A line over the bound is a named refusal.

## Reads past the ceiling (#1667, gate `task bytes-read-stream`)

- **The 65,536-byte ceiling on the single positional `read_file` stays.**
  `task bounded-bytes` proves it.
- **A new bounded operation reads a chunk of at most 65,536 bytes from one open
  stream** — a file handle or standard input — so a pipe or standard input can
  be served. It reports bytes read and an end-of-stream status; the program
  loops.
- **A file that changes between chunks is not detected**, and no promise is
  made that it is.
- **The per-chunk bound is the enforced one**; total size is bounded by the
  program's loop, not by one read.

## Failure observability (#1666, #1667)

- **A failed command-I/O operation reports an `Int` status**, as `byte_at`
  crossed under #1499 option 1. A program continues past a failed operand and
  chooses its own exit status; a compiler-owned outcome type is not declarable
  in Stage 2 today.

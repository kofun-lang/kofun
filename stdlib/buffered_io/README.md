# Buffered IO

One operation:

```kofun
fn buffered_read_line(
    read file: File,
    edit reader: BufferedReader
) -> Result[BufferedLine, BufferedError]
```

`BufferedLine` is `Line(Bytes)` or `Eof`. Every existing read in the tree needs
the length in advance — `file_read` takes a caller-sized destination and an
explicit length, `file_read_exact` loops correctly but only to `len(destination)`,
and `csv_parse` takes the whole document as `Text`. A line's length is not known
before it is read. This is the reader for that.

## The rules, all of them

- **LF only.** A trailing CR is preserved in the returned bytes. Stripping it
  silently is a decision the caller cannot undo; a caller who wants it gone can
  do that itself.
- **The final line is returned.** A file whose last byte is not a newline still
  has a last line, and a reader that dropped it would lose data silently.
- **An empty line is a line** of length zero, not a skipped one.
- **Capacity is the maximum line length including its terminator.** A line the
  buffer cannot hold together with its line feed is `BufferedLineTooLong`,
  carrying the capacity — what the caller would have to raise — rather than a
  length nobody can act on. Nothing is discarded: the buffered bytes are still
  there and the cursor has not moved.
- **`EINTR` is retried** with the offset unchanged, the same discipline
  `file_read_exact` already applies. Surfacing it would make every caller write
  this loop.
- **Reading past the end costs nothing.** `Eof` is answered from the reader's
  own state, so it makes no syscall and cannot block.
- **The file is borrowed, not owned.** `File` is affine — `file_close(take file: File)`
  — so a reader that owned it would have to re-export close and drop, and a
  caller who wanted the descriptor back could not have it.

## The two halves

`buffered_io.kofun` is the portable half: the buffer and the line-splitting
state machine. `linux_x86_64.kofun` is the adapter half: the refill over
`file_read`, and the outcome and error types, because `BufferedSystem` names
`SysError`.

The portable half names one module from the platform directory —
`stdlib.linux_x86_64.bytes`, because the byte surface lives there and a buffer
is made of bytes. That module is portable code under a platform name: it calls
five compiler intrinsics and no syscall. The gate measures both facts rather
than asserting them, so the day `bytes.kofun` grows a syscall, this half stops
being portable loudly instead of quietly.

Writing is not here. `buffered-io`'s writer half is a separate child if a
consumer appears; the counted consumer today is the package-manager rewrite's
two line-wise reads (#1457).

## Failures

```kofun
type BufferedError =
    | BufferedSystem(SysError)
    | BufferedLineTooLong(Int)
    | BufferedBuffer(ByteError)
```

## Evidence

`tests/verify.sh`, reached by `task stdlib`. Neither half compiles — `bin/kofun
check` on any file in `stdlib/linux_x86_64` stops at its first `import`, and
`trusted intrinsic` is refused at top level in both pipelines, so `raw_read` is
unreachable from any compilable program. So, as in `stdlib/entropy` and
`stdlib/random`:

1. **Source properties** on both halves, including the two measurements that
   make "portable" checkable rather than a label.
2. **An executable Int-Core projection**, `tests/checkpoint.kofun`, of the state
   machine over twelve scripted sources: two lines, an unterminated final line,
   an empty source, a lone line feed, a line longer than a four-byte buffer, a
   line of exactly capacity-minus-terminator, one byte over, one byte per read,
   `EINTR` at the first read, a line spanning two refills, a NUL inside a line,
   and a read error after a line. `Bytes` becomes a `List[Int]` and `file_read`
   becomes the script; everything else is the algorithm.
3. **An independent C11 oracle**, `tests/buffered_io_reference.c`, written from
   the rules rather than translated from the projection, over the same scripts,
   compared byte for byte.

Twelve of the golden's positions are asserted by name, so a golden that changes
shape cannot be silently re-blessed.

`tests/oracle-binding.json` binds all three digests and records what is **not**
proved: that `file_read` is called with the right descriptor, offset, and
length. That is the same gap `stdlib/linux_x86_64/io.kofun` has, closed the same
way — by a committed native image — which this module does not add.

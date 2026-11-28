# Stage 2 bounded Text results

This corpus holds the ordinary Stage 2 C11 path to three executable Text value
capabilities: direct `Text` parameters/results, canonical `to_text(Int)`, and
`Text + Text` concatenation. It also keeps `Int + Int` on the checked integer
path.

The `bootstrap_chars` fixture checks the read-only byte list used by the
bootstrap lexer, including UTF-8 byte counts, copied bindings, grouping and
the evaluation order of the receiver and index. Companion cases cover
shadowing, an invalid index type and an out-of-range read.

The bounded lifetime contract has three independent limits:

- one result is at most 255 bytes (`R020` for an invalid slice and `R021` for
  an oversized concatenation);
- one compilation unit contains at most 256 syntactic Text-producing sites
  (`E2S156`, before a C artifact is written);
- one program execution may allocate at most 4096 Text temporaries (`R022`,
  one MiB of static storage in the bounded C11 profile).

The runtime arena never wraps or reuses a slot. A returned value therefore
survives later nested calls, assignments, comparisons, slicing, concatenation,
and printing until the explicit work bound is exhausted. Exhaustion reports
once and exits non-zero instead of truncating or aliasing an earlier value.

`run.sh` builds twice and from a remapped source directory, compares C/HIR/token
bytes, compiles emitted C as strict ISO C11, executes it under the available
address/undefined sanitizers, and pins every refusal plus its artifact policy.

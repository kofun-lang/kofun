# Direct native function benchmark

This benchmark measures the direct x86-64 backend's bounded user-defined
function profile: the recursive integer shapes that profile actually supports,
compiled to a static ELF by `bootstrap/native/core_compiler.c` and executed on
the host. It is a bounded local measurement of one backend against its own
previous revision, not a language or runtime comparison.

Five workloads cover the shapes the profile lowers:

- `fib35.kofun` — recursion, a comparison guard, and checked arithmetic, with
  one value live across a call;
- `mutual_fib32.kofun` — the same tree-recursive work split across two
  mutually recursive functions;
- `six_argument_fib30.kofun` — the same work driven through a six-argument
  call, so every argument register and the whole call boundary is exercised;
- `tail_sum30000.kofun` — an accumulator threaded through a returned self-call,
  repeated so the measurement is the loop rather than the process;
- `tail_mutual30000.kofun` — the same accumulator alternating between two
  functions, so the returned call is to a different function every step.

The two tail workloads recurse 30,000 deep per round, which is deliberately
shallow enough for a producer that spends a frame per step to run them at all.
The constant-stack claim is not measured here — three million deep is past the
point where a timing comparison has two sides — it is proved by execution in
`bootstrap/native/check.sh`.

Every workload is compiled by the producer under test, executed, and compared
against its expected output before a single sample is taken, so no timing
number can come from a program that computes the wrong answer.

## Method

`cpu_samples.c` forks the measured command, waits for it, and reports the
`wait4` rusage user plus system microseconds. Process CPU time is used rather
than wall time because these workloads are single-threaded, compute-bound, and
short. Each invocation runs the command once as a warm-up and discards it.

Samples are collected one round at a time — current, then baseline, then the C
reference — so machine drift lands on every variant instead of on whichever
one ran last. The default is 11 samples; the median is the sixth sorted sample
and the recorded lowest and highest samples show the dispersion.

Emitted code size is `p_filesz` of the first `PT_LOAD` program header, which is
the actual code, not the page-aligned file size that every image shares.
Compile time is one producer run over all seventeen bounded-corpus sources.

Reproduce the recorded measurement, comparing against the revision before
returned calls became branches:

```sh
BASELINE=ba5d52aecf9ff7dfa02278eb0111a4f88ffd983d SAMPLES=11 \
    sh benchmarks/native-functions/benchmark.sh
```

`BASELINE` accepts any git revision; the harness builds that revision's
`bootstrap/native/core_compiler.c` as a second producer. With `BASELINE` set,
the recorded budgets are enforced and the script fails when one is missed:
every workload named in `IMPROVE` must reduce its median by the percentage
declared there, no workload may regress by more than 5%, and neither emitted
code nor corpus compile time may regress by more than 10%. Without `BASELINE`
the script reports the current numbers only. `SAMPLES`, `CC`, `IMPROVE`, and
`REFERENCE_CFLAGS` are the other knobs.

`IMPROVE` is a claim about one pair of revisions, so it moves when the pair
does. It defaults to what this revision claims. To reproduce the register
allocator's claim instead, name that pair explicitly:

```sh
BASELINE=fdb8e6d258312b9222f4dde4df35badee6423d68 IMPROVE=fib35:25 SAMPLES=11 \
    sh benchmarks/native-functions/benchmark.sh
```

## Recorded measurement

`results.json` holds the raw samples behind these medians, measured on an AMD
Ryzen 3 7330U with GCC 16.1.1, comparing returned-call branching against the
revision before it:

| Workload | Before | After | Change |
|---|---:|---:|---:|
| `tail_sum30000` | 28,397 us | 7,712 us | −72.84% |
| `tail_mutual30000` | 42,367 us | 12,785 us | −69.82% |
| `six_argument_fib30` | 6,874 us | 6,708 us | −2.41% |
| `fib35` | 40,157 us | 39,881 us | −0.69% |
| `mutual_fib32` | 9,796 us | 9,800 us | +0.04% |

The two tail workloads are the claim. `six_argument_fib30` improves because its
driver returns `pick6(...)` directly, so that outer call is in a returned
position too; the tree-recursive calls underneath it are not, and are untouched.
`fib35` and `mutual_fib32` have no call in a returned position at all, and
their changes are inside the run-to-run spread — which is the point of
measuring them here.

Emitted code shrank 1.75% on `tail_sum30000` and grew 0.99% and 2.12% on
`tail_mutual30000` and `six_argument_fib30`, where a frame teardown now
precedes each cross-function branch. Corpus compile time moved +1.48%, inside
the run-to-run spread of the two sample sets.

The same `fib(35)` written in C and built with `-O3` has a median of 10,998 us
on this host, so the direct backend stays at 3.626x that reference; nothing in
this change touches that shape. The remaining distance is not attributable to
value placement or call lowering alone: the Kofun program branches to a
checked-overflow diagnostic after every arithmetic operation and the C program
does not.

Earlier measurement, the register allocator (#665) against `fdb8e6d`, kept for
comparison: `fib35` 84,250 us → 39,570 us (−53.03%), `mutual_fib32` 20,168 us →
9,905 us (−50.89%), `six_argument_fib30` 15,272 us → 6,758 us (−55.75%), with
the C `fib(35)` ratio going from 7.635x to 3.586x.

## How it runs (#1139)

`benchmark.sh` enforces nothing until it is told which revision to compare
against, and for a long time nothing told it. `check.sh` is what invokes it,
and it does not invent the pair: `results.json` already records both halves —
`baseline_revision` and `budgets.declared_improvements` — so the gate and the
numbers published above cannot describe different comparisons. Recording a new
measurement is what moves the pin, which puts the move at the moment a person
looked at the numbers.

A named revision rather than committed numbers, because the harness builds that
revision's producer and measures it in the same run on the same machine,
interleaving rounds. Numbers recorded elsewhere would measure the hardware
instead — the ones above came from a laptop, and CI runners are neither that
laptop nor each other. A *moving* baseline such as `HEAD~1` would be worse than
either: the 5% per-comparison allowance would let performance decay without
limit while every run stayed green.

The gate is split in two, because enforcing it costs two producer builds and
needs the baseline commit in the object store:

```sh
task native-functions-baseline    # the pin is coherent — no benchmark, no history
task native-functions-benchmark   # the real thing, against the pinned revision
```

`native-functions-baseline` is in `task verify`. It proves the pin still names
a real revision and that every claim names a workload the harness measures,
which is what rots silently; it reads no history and runs nothing.

`native-functions-benchmark` is not in `verify`. It runs in its own scheduled
lane, `.github/workflows/benchmark.yml`, daily and on demand, with full history
checked out. Not on pull requests: a shared runner's neighbours are not this
repository's business, and a timing gate that goes red for a reason a pull
request's author cannot fix teaches people to ignore it. On `main` the same
failure is a true signal.

# Usability comparison corpus v1

The eight programs #624 makes a precondition for accepting any further syntax
decision, written in Kofun and in the comparison languages #624 names, plus
the review rubric that scores them.

Owner issue: #909. Normative input: #624's 2026-07-25 product decision.

```sh
sh tests/usability/check.sh              # the gate
sh tests/usability/check.sh --measure    # reproduce the rubric's M3 counts
task usability-corpus                    # the same gate, from Taskfile.yml
```

## What this corpus is, and what it is not

It **is** evidence for a UX decision: eight small programs written twice, so
that a proposal to change the language can be argued against something
concrete instead of against taste.

It is **not**:

- **a benchmark.** No measure in [rubric.md](rubric.md) concerns speed,
  memory, or binary size, and no program here is written to be fast. #624
  puts benchmarks under a separate child.
- **a claim that Kofun is better or worse than Go, Gleam, Kotlin, or Rust.**
  Three of the eight Kofun programs do not compile. That is recorded, not
  argued away.
- **a tutorial.** `docs/tour/` is the interactive tour. This corpus
  deliberately shows the awkward cases the tour has no reason to.
- **a proposal.** It adds no syntax and changes none. #625's labelled
  arguments are decided and execute for `Int`/`Text`/`List[Int]` carriers, and
  #1191 added the expression-bodied trailing lambda; the block-bodied form
  stays open behind `E2S158`, and #909 does not decide it — though
  [05_higher_order.kt](05_higher_order.kt) is written to be the evidence that
  decision is made against.

## The eight rows

| # | #624 row | Status | Runs / owner | Comparison |
|---|---|---|---|---|
| 1 | pure list pipeline with `map`/`filter`/`fold` | executable-today | native x86-64 backend | Gleam |
| 2 | parser returning Result through three fallible steps | executable-today | `kofun check` + `build` | Rust |
| 3 | resource function showing read/edit/take without use-after-move | executable-today | bounded record frontend | Rust |
| 4 | ADT + record + exhaustive match | executable-today | `kofun check` + `build` | Kotlin |
| 5 | higher-order API with two ordinary arguments and one callback | blocked-on | **#624** | Kotlin |
| 6 | Monad instance plus stated left/right identity and associativity | blocked-on | **#31** | Rust |
| 7 | the frozen self-host compiler profile from #618 | executable-today | `kofun check` on the frozen source | none — reason recorded |
| 8 | cancellable reactive pipeline with bounded demand and explicit scheduler boundary | blocked-on | **#624** | Go |

[manifest.tsv](manifest.tsv) is the machine-readable form the gate reads.
Each Kofun file's header carries its own status, the command that runs it or
the issue that owns it, and the diagnostics quoted in the rubric.

### Why the blocked rows name the issues they do

- **5 and 8 name #624** because the issue that would fix them does not exist
  yet. #624's decision comment commits, as refinement item 2, to linking
  implementation children for "arrow-type migration" (row 5) and "Stream
  conformance" (row 8). Until those children exist, #624 is the one open
  issue whose completion puts an owner on each row — and these two rows are
  the evidence that the children are still missing.
- **6 names #31** because #31's scope already covers what row 6 needs: trait
  declarations, implementations, bounds, and "generic law proposition IR and
  evidence requirements". #551 settled the law *design* (DD-035) and is
  closed; #31 owns making it run.

Issue states were audited on 2026-08-02 against
`origin/main@69f9179560bf57886be5c1e3c74b78d936e32a54`; #624 and #31 were
both open. Openness cannot be re-derived offline, so the gate does not assert
it. What the gate does assert is stronger against the failure that actually
matters: each blocked row is still genuinely refused, with its recorded
diagnostic. A row that starts compiling fails the gate by name.

## What the gate holds

1. Every executable-today row still compiles **and** still produces the
   recorded observations, asserted one at a time.
2. Every blocked-on row is still refused, with the recorded diagnostic.
3. Row 7 only *references* `bootstrap/stage1/compiler.kofun`; its digest
   still matches `bootstrap/stage1/SHA256SUMS`; and no file in this directory
   is a copy of it, compared by digest so a rename is caught too.
4. Two boundaries the corpus rests on are still boundaries: `edit` on a
   record is refused (E2S121, DD-021) and use-after-move is refused (E2S123).
5. Two properties are checked by breaking them: deleting an arm from row 4's
   `match` must still fail naming the missing constructor, and deleting a
   binding annotation from row 2 must still pass `check` and fail `build`.
6. The rubric still names all seven measures, still excludes character count,
   and still carries one score row per item in each of its two tables.

Go and Rust comparisons are compiled and run, and row 2's two programs are
compared observation for observation. Gleam and Kotlin are not installed in
this image; those three files are reported skipped **by name**. A skipped
comparison is never reported as a pass.

## Findings this corpus produced

Writing it surfaced things that were not written down anywhere:

- **`check` passing does not mean a program builds.** Two rows hit this. In
  row 2 the failure is emitted by the host C compiler against generated code
  the author never wrote (`error: invalid initializer`); in row 4 an inlined
  constructor argument does the same. The gate pins row 2's case so it cannot
  silently close.
- **A constructor application needs an explicit type annotation; a function
  call returning the same type does not.** `let circle: Shape = Circle(5)` is
  required, `let digits = step_digits(source)` is not.
- **Ownership modes now reach the production parameter parser, but generic
  nominal parameter types do not.** Row 8 advances past `read` and stops at
  `Stream[Reading, StreamError]` with `malformed parameter head at byte 2141`;
  the diagnostic still does not name the unsupported generic type.
- **The worst diagnostic in the corpus is row 5's**: `Core function
  'accumulate' expects 3 arguments, got -1`, an argument count that cannot
  exist.
- **`|>` has no executable form on either backend.** Naming a function
  without calling it is not an expression, so a pipeline stage has nothing to
  be: `readings |> filter` fails the native backend with "expected Int
  expression in native Core function", and `3 |> double` fails Stage 2 with
  "unknown lexical binding `double`". Neither message mentions pipelines. The
  decision #49 that #624 lists among its existing decisions cannot be
  exercised on `main`.
- **The native backend's `print` promise is 10..99, and outside it the
  program is wrong rather than refused.** Row 1's pipeline over
  `[3, 12, 7, 20, 5, 18]` folds to 114 and prints `;4`. Only *known* constants
  outside the range are rejected. Row 1 stays inside the promise; fixing the
  boundary is not this child's scope.

None of these are argued in the rubric's scores without a witness; each is
scored in [rubric.md](rubric.md) with the observation that demonstrates it.

## Boundaries

There is deliberately no Kofun formatter row: `docs/MVP_IMPLEMENTED.md`
records `formatter and REPL | open | design only`, so M6 is `n/a` for every
Kofun row rather than 0. Recording it as `n/a` is what keeps the gap to the
four comparison languages visible instead of averaged into a total.

Row 7 has no comparison implementation. The recorded reason: rewriting a
3,523-line self-hosting compiler idiomatically in Go, Gleam, Kotlin, or Rust
is not a bounded corpus item, and a fragment of one would be a strawman
rather than a comparison. #624 names four comparison languages, not four
compilers.

Row 6's comparison is deliberately not like-for-like, and
[06_monad_laws.rs](06_monad_laws.rs) says so in its first paragraph: none of
the four languages can state a Monad instance together with its laws — Go and
Gleam have no type classes, Kotlin and Rust have no higher-kinded types. It
compares against what an idiomatic Rust programmer actually writes instead,
which is three `#[test]` functions over a bounded domain.

# Usability review rubric v1

The comparison rubric #624 makes a precondition for accepting any further
syntax decision. It fixes **what is measured**, **how it is counted**, and
**what is not a metric**, so that two reviewers scoring the same corpus
independently land on the same numbers.

Normative input: #624's 2026-07-25 product decision, refinement item 1.
Owner issue: #909. The corpus this rubric scores is the eight files in this
directory; see [README.md](README.md).

## Character count is not a metric

#624 states it plainly: "Character count alone is not a metric." This rubric
goes further and excludes it entirely — not as a tiebreaker, not as a
reported-but-unscored column.

The reason is that character count rewards exactly the changes #624's
guardrails forbid. A shorter program is produced by adding a second spelling
for an operation that already has one, by inferring what an annotation used
to state, or by hiding an allocation behind an operator. Each of those makes
the count fall and makes the language worse against the outcome #624
actually wants. `docs/tour/` already teaches the language compactly; this
corpus exists to find where compact code stops being predictable.

Two consequences follow, and reviewers should apply both:

- A proposal that lengthens a corpus program while removing a surprise, an
  annotation the compiler could have inferred, or a hidden control transfer
  **scores better**, not worse.
- "It reads better" is not a score. Every measure below is either counted by
  a stated procedure or anchored to observable failure behaviour.

## The seven measures

All seven come from #624. Each is scored **0-3, higher is better**. Four are
counted mechanically; three are anchored judgements. Where a measure does not
apply, record `n/a` with the reason — never 0, because "nothing to measure"
and "measured, and bad" are different findings.

### M1 Semantic surprises

**What counts as one.** A place where a reader who has read the written rules
would predict a different outcome than the toolchain produces. Each distinct
*cause* is one surprise, however many times it appears. Record the observation
that demonstrates it; an unwitnessed surprise is not counted.

| Score | Anchor |
|---|---|
| 3 | no surprise found |
| 2 | one surprise, and the toolchain reports it |
| 1 | two or three surprises, or one that is reported by a different tool |
| 0 | four or more, or any surprise that produces a wrong answer instead of an error |

### M2 Required annotations

**Counting procedure.** Delete one type annotation in *binding* position
(`let x: T = ...`, and lambda parameters). Re-run the item's recorded command
from [manifest.tsv](manifest.tsv). If the outcome changes from success to any
failure, the annotation is **required**; restore it and continue. Count the
required ones.

Signature annotations — parameter and result types on named functions — are
deliberately **excluded**: all five languages require them, so counting them
discriminates nothing. This measure is about what the checker could have
inferred and did not.

| Score | Anchor |
|---|---|
| 3 | 0 required |
| 2 | 1-2 required |
| 1 | 3-5 required |
| 0 | 6 or more required, or an annotation is required by one command and not another |

### M3 Delimiter and indentation load

**Counting procedure**, over the whole checked-in file, counting only
non-blank, non-comment lines:

- **body** — how many such lines there are.
- **depth** — maximum block nesting depth reached, counting `{` as +1 and
  `}` as -1.
- **closers** — lines whose entire trimmed content is closing delimiters
  (`}`, `},`, `)`, `];`, and so on).

All three are printed by `sh tests/usability/check.sh --measure`. Score from
that output and nothing else; two reviewers running one command is the point.

| Score | Anchor |
|---|---|
| 3 | depth <= 2, and either body < 20 or closers <= 20% of body |
| 2 | depth 3-4, or closers 20-30% |
| 1 | depth 5-6, or closers 30-40% |
| 0 | depth 7+, or closers above 40% |

When depth and closers give different scores, **take the lower**. Files under
20 body lines are exempt from the closers rule because one closing brace in a
seven-line program is 14% and means nothing.

Two cautions this measure needs, because it is measured per file:

- It includes each file's scaffolding. A comparison file that declares an
  enum, an `impl`, and a `main` around the same algorithm scores worse than a
  Kofun file that needs none of them, and that is a real cost, but it is not
  a cost of the *algorithm's* shape.
- Where the interesting contrast is inside one function, record it in the
  notes. Row 2 is the case: the whole-file depths are 6 and 3, but the
  functions being compared are `parse` at depth 6 in Kofun and `parse` at
  depth 1 in Rust. The score follows the tool; the note carries the finding.

### M4 Hidden control flow and allocation

**What counts as one.** A place where control leaves the written path, or
memory is allocated, with no token on the line naming it. An early return
spelled `?` is **not** hidden — the token is there and its meaning is fixed.
A goroutine started by `go` inside a function whose signature does not say so
**is** hidden from the call site. Count sites, not occurrences.

| Score | Anchor |
|---|---|
| 3 | none: every transfer and allocation is named where it happens |
| 2 | one, and it is visible in the callee's signature |
| 1 | one or two visible only in the callee's body |
| 0 | three or more, or any that is invisible in both signature and body |

### M5 Diagnostic quality

Judged on the failure the item actually produces — either its recorded
refusal, or the failure produced by deleting one required annotation.

| Score | Anchor |
|---|---|
| 3 | names the construct, states the rule, and suggests the fix |
| 2 | names the construct and states the rule |
| 1 | names a location but misdescribes the cause, or reports a fact that cannot be true |
| 0 | reported by a different tool against code the author never wrote, or the program is accepted by one command and fails in a later one |

### M6 Formatter stability

**Procedure.** Format the file, parse it, format it again; the two outputs
must be byte-identical, and the parse must succeed.

Kofun has no formatter. `docs/MVP_IMPLEMENTED.md` records
`formatter and REPL | open | design only`, and its claim row
`formatter-and-repl` has no gate. So **every Kofun row scores `n/a`, not 0**:
there is no formatter to be unstable. This is the measure with the largest
gap to the comparison languages, all four of which ship a canonical
formatter, and recording it as `n/a` rather than `0` is what keeps the gap
visible instead of averaged away.

### M7 Beginner readability

**Procedure.** Give the file to a reader who knows one mainstream language
and has not read Kofun's spec. Ask them to (a) predict the output and (b)
name the role of every token. Score on what they cannot do.

| Score | Anchor |
|---|---|
| 3 | predicts output and names every token's role |
| 2 | predicts output; one construct's role needs the spec |
| 1 | cannot predict output without the spec, or two or more constructs need it |
| 0 | predicts the *wrong* output confidently |

Terminology constraint from #624: a beginner path must teach ordinary
functions, `Result`, `match`, ownership, and event streams **without Monad
terminology**. A row that can only be explained with it scores at most 1.

## Scores: Kofun

Recorded 2026-08-02 against `origin/main@69f9179`. This is a first pass by
one reviewer; the procedures above exist so a second reviewer can reproduce
or contest each number. Counted columns carry their measurement in brackets.
Row 7 was re-reviewed 2026-08-08 after
`695b863c87a194c98143d866666d8ada8a435759` expanded the audited Stage 1
source to 3,523 lines; its M7 score and measured `b11, d1, c3` remain unchanged.

| # | Item | M1 surprises | M2 annotations | M3 delimiters | M4 hidden flow | M5 diagnostics | M6 formatter | M7 beginner |
|---|---|---|---|---|---|---|---|---|
| 1 | list pipeline | 1 [2] | 3 [0] | 3 [b7, d1, c1] | 3 [0] | 1 | n/a | 2 |
| 2 | parser Result x3 | 1 [2] | 0 [3] | 1 [b47, d6, c13] | 3 [0] | 0 | n/a | 2 |
| 3 | read/edit/take | 1 [2] | 3 [0] | 3 [b17, d1, c4] | 3 [0] | 2 | n/a | 3 |
| 4 | ADT + record + match | 2 [1] | 0 [6] | 3 [b38, d2, c6] | 3 [0] | 2 | n/a | 3 |
| 5 | higher-order callback | n/a | n/a | n/a | n/a | 0 | n/a | n/a |
| 6 | Monad + laws | n/a | n/a | n/a | n/a | 1 | n/a | n/a |
| 7 | frozen self-host S | 3 [0] | 3 [0] | 3 [b11, d1, c3] | 3 [0] | 3 | n/a | 3 |
| 8 | cancellable stream | n/a | n/a | n/a | n/a | 2 | n/a | n/a |

Rows 5, 6, and 8 do not compile, so only M5 is scoreable: a diagnostic is the
only thing the toolchain produces for them. Scoring the other measures
against source that no toolchain accepts would be scoring a wish.

### Why each non-obvious score

- **1.M1 = 1.** Two witnessed surprises: the same file runs on the native
  backend and is refused by `./bin/kofun check` with "unknown Core function
  `filter`", with nothing in the program naming a backend; and a fold result
  above 99 prints a wrong value rather than failing.
- **1.M5 = 1.** "unknown Core function `filter`" names a location and
  misdescribes the cause — `filter` is not unknown, it is unavailable in that
  backend profile.
- **2.M2 = 0.** Three `: ParseResult` annotations are required, and required
  *by `build` only* — `check` accepts the file without them. That is the
  explicit 0 anchor.
- **2.M5 = 0.** Deleting one of those annotations produces
  `error: invalid initializer / KofunEnumValue kofun_match_value = k_b11;`
  from the host C compiler, against generated code the author never wrote.
- **4.M2 = 0.** Six required binding annotations: `: Shape` three times and
  `: Extent` three times.
- **4.M5 = 2**, not 3: the record diagnostic is excellent — "bind record
  construction to an explicitly typed immutable record before using it" both
  states the rule and gives the fix — and the exhaustiveness diagnostic names
  the missing constructor (`E2S25 ... missing constructors 'Empty'`). It is
  held to 2 because the same file has a shape that passes `check` and then
  fails in the C backend.
- **4.M1 = 2**, its one surprise: a constructor application needs an explicit
  type annotation, a function call returning the same type does not.
- **5.M5 = 0.** `Core function 'accumulate' expects 3 arguments, got -1`
  reports an argument count that cannot exist.
- **6.M5 = 1.** `expected top-level 'fn' or 'type'` names the location and
  does not say that `law` is a known, accepted, unimplemented form.
- **8.M5 = 2.** Was 1, when the row scored `malformed parameter head at byte
  2141`: ownership modes were recognized, but the diagnostic named neither the
  unsupported generic nominal parameter type `Stream[Reading, StreamError]` nor
  the pipeline that actually blocks the row. Since #1190 Stage 2 recognizes the
  pipeline and refuses it first, naming the construct and the boundary — `a
  pipeline target must be a top-level function, not a member call`. Still not 3:
  it names what is unsupported, not a remedy, and the generic parameter type
  behind it remains unnamed by any message this corpus now reaches.
- **7.M7 = 3.** 3,523 lines that a reader can follow without the spec is the
  strongest readability evidence in the corpus, and it is evidence about a
  deliberately small subset: no records, no ADT payloads, no generics, no
  ownership modes, no callbacks.

## Scores: comparison implementations

| # | Language | M1 | M2 | M3 | M4 | M5 | M6 | M7 |
|---|---|---|---|---|---|---|---|---|
| 1 | Gleam | 3 [0] | 3 [0] | 3 [b11, d1, c1] | 3 [0] | n/a | 3 `gleam format` | 3 |
| 2 | Rust | 3 [0] | 3 [0] | 1 [b46, d3, c14] | 3 [0] | 3 | 3 `rustfmt` | 2 |
| 3 | Rust | 3 [0] | 3 [0] | 2 [b28, d2, c7] | 3 [0] | 3 | 3 `rustfmt` | 2 |
| 4 | Kotlin | 2 [1] | 3 [0] | 3 [b16, d1, c2] | 3 [0] | 2 | 3 `ktfmt` | 3 |
| 5 | Kotlin | 2 [1] | 3 [0] | 3 [b8, d1, c2] | 3 [0] | 3 | 3 `ktfmt` | 3 |
| 6 | Rust | 1 [2] | 3 [0] | 1 [b60, d5, c20] | 3 [0] | 3 | 3 `rustfmt` | 1 |
| 7 | — | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| 8 | Go | 0 [4] | 3 [0] | 2 [b83, d4, c16] | 0 [3] | 3 | 3 `gofmt` | 1 |

M5 for a program with no failure to provoke is scored by deleting one
required annotation; where nothing is required (M2 = 3), the score is the
quality of the language's diagnostic for the corresponding deliberate error,
recorded in the comparison file's header.

### Why each non-obvious score

- **4.M1 = 2** and **5.M1 = 2.** Kotlin's one surprise in each file:
  exhaustiveness of `when` depends on whether it is used as an expression, so
  the same `when` over the same sealed type is checked in one position and
  not in another; and `f(a, b) { ... }` and `f(a, b, { ... })` are the same
  call written two ways.
- **6.M1 = 1**, **6.M7 = 1.** The laws are three test functions with nothing
  binding them to `bind` and `pure`; deleting one removes the check silently.
  The row also cannot be explained without Monad terminology, which caps M7
  at 1 by the constraint above.
- **8.M1 = 0.** Four: a missed `select` on `ctx.Done()` leaks a goroutine
  permanently; channel capacity is a buffer, not demand, so the producer runs
  ahead of the consumer; `close` is the producer's responsibility and
  double-close panics at runtime; and a dropped `cancel` leaks with no
  diagnostic.
- **8.M4 = 0.** Three hidden sites, all `go`: nothing in `source`, `filter`,
  or `mapValues`'s signature says it starts a goroutine.
- **2.M7 = 2** and **3.M7 = 2.** `Result<i64, ParseError>`, `?`, `&mut`, and
  the move rule each need explanation to a reader who knows only a
  garbage-collected language.
- **8.M7 = 1.** Predicting the output requires knowing that a `range` over a
  channel ends at `close`, that `select` picks a ready case, and that
  `cancel()` propagates upstream through `ctx.Done()`. That is three
  constructs, not one.
- **2.M3 = 1 for Rust, against 1 for Kofun — and the row is still the
  clearest win in the corpus for `?`.** The scores tie because the measure
  is per file and the Rust file carries an enum, an `impl`, and a `main` the
  Kofun file does not. The finding the tie hides is in the functions being
  compared: Kofun's `parse` reaches depth 6 and repeats its error arm three
  times; Rust's `parse` is four flat statements at depth 1. This is exactly
  the case the M3 cautions above exist for, and a reviewer should read the
  note rather than the number.
- **3.M3 = 2 for Rust, against 3 for Kofun.** Same effect, smaller: the Rust
  file spells three modes where Kofun spells two, and pays four more closer
  lines for the struct and the extra function.

## What the numbers do and do not license

- They are **per-row**, and they are not summed. A total would average a
  measure that is `n/a` for structural reasons together with one that is 0
  because something is broken, and those must not cancel.
- They compare **languages on one task**, not language implementations.
  Rows 5, 6, and 8 compare an accepted specification against a running
  program; that asymmetry is stated in each file and is the reason those rows
  are labelled `blocked-on`.
- They are **not a benchmark**. No measure here is about speed, memory, or
  binary size, and none of the corpus programs is written to be fast.
- A score changes when the language changes. `sh tests/usability/check.sh`
  fails if a row's compile status moves, which is the signal to re-score that
  row rather than to edit the number in place.

# Type-level programming v1

Status: accepted normative design for GitHub issue #657. No active compiler
implements this profile.

Decision owner: the repository maintainer. A future change to the accepted
forms, reduction limits, or trace contract requires a separately reviewed,
versioned specification change.

The words **must**, **must not**, **should**, and **may** are normative.

## Decision

Kofun selects a Type-only, named, structurally terminating profile. V1 is more
expressive than aliases alone, but deliberately smaller than either
TypeScript's type-expression language or GHC's general type-family surface.

A representative declaration is:

```kofun
type fn Flatten[T: Type] -> Type {
    match T {
        List[item] => Flatten[item]
        _ => T
    }
}
```

Type-level logic lives in module-level declarations with stable identities.
It is never an anonymous expression language embedded at a use site.

## Alternatives and accepted boundary

| Alternative | V1 decision | Reason |
| --- | --- | --- |
| Transparent aliases only | rejected as the complete profile | predictable, but cannot express bounded structural type transformations |
| Named, kinded, structurally terminating type functions | **selected** | expressive enough for reviewable transformations while keeping termination and traces decidable |
| Anonymous conditional, mapped, or inferred type expressions | rejected | encourages expanded expression soup and makes diagnostics depend on anonymous internals |
| General recursive or mutually recursive type programs | rejected | termination, cost, and error size are not statically bounded |
| Higher-kinded or effectful type computation | deferred | requires separate kind, capability, evidence, and tooling decisions |
| Turing-complete type programming | rejected as a language goal | conflicts with deterministic checking and bounded diagnostics |

The selected profile is named `kofun.type-reduction/default-v1`.

**Three of those rows have been superseded — see `DD-031/A01` (2026-08-09).**
The table above records what v1 selected and is preserved as written; it is no
longer the whole accepted boundary. The versioned specification change that
row 6 requires has happened, in two parts, both `accepted` on 2026-08-09:

| Superseded row | Superseded by | Now |
| --- | --- | --- |
| General recursive or mutually recursive type programs — *rejected* | [RFC-0008](../rfcs/0008-type-level-general-v2.md), issue #1130 | admissible when declared `type fn general`, under `kofun.type-reduction/general-v2` |
| Turing-complete type programming — *rejected as a language goal* | [RFC-0008](../rfcs/0008-type-level-general-v2.md), issue #1130 | accepted as a goal; bounded by versioned frame/step/node limits, and exhaustion is a deterministic error rather than a hang |
| Higher-kinded or effectful type computation — *deferred* | [RFC-0009](../rfcs/0009-type-level-kinds-v1.md), issue #1133 | narrowed to the effectful half. The `Nat`, `Symbol`, and `Bool` data kinds are decided, under `kofun.type-reduction/kinds-v1`. Effectful type computation stays deferred. |

Rows 1 through 3 are **not** superseded. Anonymous conditional, mapped, and
inferred type expressions stay rejected, for the reason given.

Everything else in this document remains the normative description of
`kofun.type-reduction/default-v1`, which is unchanged: its limits, its
validation sequence, and its trace contract are what an unmarked `type fn`
still gets, byte for byte. A structural declaration may not call a general
one, so a default-v1 root keeps the v1 guarantee compositionally.

As before, no active compiler implements this profile — and none implements
either successor. `release/claims.json` is the authority on what the compiler
can currently do.

## Haskell reference points

Kofun adopts five lessons from Haskell/GHC without copying its full type
language:

| Reference point | Kofun v1 consequence |
| --- | --- |
| Kind signatures make type programs typed | every type-function parameter and result explicitly has kind `Type`; kind inference and higher kinds are deferred |
| GHCi `:kind!` makes reduction inspectable | `kofun type eval` gives the named normal form and `kofun type explain` renders the same structured reduction trace used by other tools |
| Typed holes support discovery at the point of confusion | typed holes remain owned by #635/#637, but their eventual explanations must consume compiler identities and traces rather than run a separate reducer |
| `TypeError` permits domain-level diagnostics | declarations may attach bounded static literal messages; messages cannot execute type computation or expose unbounded expansions |
| Type-family errors and constraint chains can still blow up | named forms alone are insufficient, so v1 also fixes reduction, display, diagnostic-frame, and trace-size budgets |

These are design evidence, not compatibility promises. Haskell syntax,
constraint solving, open type families, and general type-level evaluation are
not accepted implicitly.

## Allowed forms

V1 permits exactly:

1. non-recursive transparent type aliases;
2. application of nominal type constructors;
3. module-level named `type fn` declarations;
4. explicit parameters and results of kind `Type`;
5. exhaustive `match` arms with non-overlapping nominal constructor heads,
   variables bound by the current arm, and at most one final residual `_`
   fallback;
6. calls to other named type functions when the complete inter-function call
   graph is acyclic; and
7. direct self-recursion only on a strict subterm bound by the current match
   arm.

This specification defines the following design grammar. It does not add
these productions to an active parser:

```text
type-function-declaration :=
    "type" "fn" TypeName "[" type-parameter ("," type-parameter)* "]"
    "->" "Type" "{" type-match "}"

type-parameter := TypeName ":" "Type"

type-match :=
    "match" TypeName "{"
        type-arm+
    "}"

type-arm := type-pattern "=>" type-expression

type-pattern :=
    "_"
  | TypeName
  | TypeName "[" type-pattern ("," type-pattern)* "]"

type-expression :=
    TypeName
  | TypeName "[" type-expression ("," type-expression)* "]"
```

Names in a pattern bind only inside that arm. Constructor heads and called
type functions resolve by stable declaration identity before reduction.
Source order does not resolve names, choose overloads, or break cycles.

## Rejected forms

V1 must diagnose, without attempting a partial reduction:

- anonymous conditional types and `infer` chains;
- mapped types and template-literal or other type-level string computation;
- type lambdas and higher-kinded parameters or results;
- implicit union distribution;
- match guards, overlapping constructor arms, a misplaced or repeated `_`,
  and non-exhaustive type matches;
- recursive aliases;
- indirect or mutual recursion between type functions;
- direct recursion on the original value or on a constructed/non-subterm
  value;
- user-supplied fuel or a source option that raises the fixed limits;
- value reflection, effects, type-level I/O, clocks, randomness, environment
  access, file access, or network access; and
- implicit invocation of trait, law, refinement, associated-type, const, or
  shape solvers.

Trait, law, refinement, associated-type, const, and shape systems retain their
own owners and evidence contracts. They may become explicit inputs to a
future version, but they are not hidden reduction steps in v1.

Static declaration- or arm-domain diagnostics may include bounded literal
metadata. That metadata cannot run a type program, compute a message, or
expose an expanded internal type expression.

## Kinding and declaration validation

Every parameter and result kind is written and resolves to `Type`. Omitting a
kind, naming another kind, or inferring a kind is unsupported in v1.

Before any root reduction, the compiler must:

1. resolve every nominal constructor and type-function identity;
2. reject duplicate or overlapping constructor arms;
3. treat one final `_` as the residual domain not matched by earlier
   constructor arms, reject `_` anywhere else, and prove exhaustiveness;
4. build the complete directed call graph;
5. reject every inter-function cycle, including mutual recursion;
6. prove that each direct self-call uses a strict subterm introduced by the
   current matched constructor pattern; and
7. record the validated declaration graph in the semantic cache identity.

Multiple direct self-calls are permitted only when every argument is a strict
matched subterm. They remain subject to the same root budget.

The structural check is necessary but not a replacement for the runtime
cycle and budget guards. A corrupt or stale internal artifact must fail
closed; it cannot make the reducer loop.

## Deterministic reduction

Reduction is independent of declaration order, hash-table order, worker
scheduling, memoization, and cache warmth.

For one root:

1. arguments are reduced left to right;
2. the single resolved declaration is entered;
3. constructor arms are tested in source order only after constructor overlap
   was statically rejected;
4. the first matching constructor arm fires, or the final residual `_` fires;
5. substitutions use stable bound-variable identity;
6. constructor arguments are reduced left to right; and
7. the result is serialized in its named form.

One transparent-alias expansion or one fired type-function arm is one logical
reduction step. Name resolution, pattern tests, memo-table lookup, and display
rendering do not add logical steps. Constructing one logical type-expression
node adds one node, whether or not the implementation interns that node. Each
completed step materializes at least its output node, so cumulative node
counts start at one and never decrease.

Memoization and interning may reduce physical work. They must not change the
selected arm, logical frame/step/node counts, result bytes, diagnostic facts,
or trace bytes. A cache hit reproduces the same logical trace as an uncached
reduction.

## Fixed reduction budget

`kofun.type-reduction/default-v1` fixes all three limits for one root:

| Resource | Limit | Exact count |
| --- | ---: | --- |
| Active frames | 32 | entered alias/type-function frames not yet returned |
| Logical steps | 256 | alias expansions plus fired type-function arms |
| Constructed logical type nodes | 256 | nodes constructed during the root reduction |

Cycle detection is mandatory and is not charged as a step. Limits are checked
before entering frame 33, performing step 257, or constructing node 257.
There is no command-line, manifest, source-language, editor, or environment
option that raises a v1 limit.

Crossing a limit is a deterministic type error. It must never produce `Any`,
an unknown type, a partial type, a successful interface, an object file, or a
cacheable successful result.

A cycle or budget diagnostic records:

- the root identity;
- the current or last declaration `SymbolId` and nullable source-order arm
  index;
- the measured active frames, logical steps, and logical nodes;
- all three fixed limits; and
- the source span of the current or last declaration or arm.

The same input and validated dependency set must select the same diagnostic
code and structured facts.

## Named display and diagnostic budget

Normal type presentation preserves aliases and type-function applications in
named form. A hover or ordinary type display is at most 4,096 UTF-8 bytes.
The renderer must not fully expand a type merely to fill that budget.

A normal diagnostic:

- contains at most eight rendered trace frames;
- selects the first four and last four when more than eight exist;
- reports the exact number of omitted frames; and
- is at most 4,096 UTF-8 bytes, including the omission marker.

A declaration-supplied static domain message is at most 4,096 UTF-8 bytes.
It is literal metadata, not a format string or executable type expression.
Truncation occurs only at a valid UTF-8 boundary and is stated explicitly.

## Structured trace contract

Every implementation of a v1 type function must produce
`kofun.type-reduction-trace/v1`. The exact JSON shape is defined by
[`type-reduction-trace/kofun.type-reduction-trace.v1.schema.json`](type-reduction-trace/kofun.type-reduction-trace.v1.schema.json)
and its additional semantic constraints are enforced by
[`type-reduction-trace/validate.mjs`](type-reduction-trace/validate.mjs).

The trace is non-authoritative tooling data. Its root contains:

- the exact schema and reduction-profile names;
- `authoritative: false`;
- the root stable identity and named display;
- the fixed limit record and measured counters;
- ordered logical step records;
- either a successful named result or a structured failure; and
- explicit status/result/failure pairing.

Each step records:

- a one-based logical step index;
- the root identity;
- a discriminant of `alias-expansion` or `type-function-arm`;
- the expanded alias or fired type-function declaration `SymbolId`;
- a null arm index for aliases, or the zero-based source-order arm index for a
  type-function arm;
- the current-source byte span of that alias declaration or arm;
- named input and output forms;
- active depth; and
- cumulative step and node counters.

Step records are ordered by logical step index. Every identity is 32 raw
bytes rendered as 64 lowercase hexadecimal characters. Spans are half-open
UTF-8 byte ranges. Unknown fields are rejected rather than treated as
authority or silently preserved.

The complete structured trace contains at most 256 step records and is at
most 4 MiB of canonical UTF-8 JSON. It retains every completed logical step;
it does not discard middle steps to meet a presentation limit. A producer
that cannot encode the complete retained trace within 4 MiB fails trace
production and cannot claim the type-function feature gate.

The checked success and failure vectors are in
[`type-reduction-trace/examples/`](type-reduction-trace/examples/). The
dependency-free gate is:

```sh
sh spec/type-reduction-trace/check.sh
```

### Canonical JSON bytes

Canonical v1 bytes are fully specified so non-JavaScript producers can emit
the same artifact:

- UTF-8 without a byte-order mark;
- exactly one JSON value followed by one LF;
- every object key unique and written in ascending ASCII byte order (all v1
  field names are ASCII);
- two ASCII spaces for each indentation level;
- an object member is `"key": value`, with one ASCII space after the colon;
- nonempty object and array members are written one per line, commas follow
  every member except the last, and closing delimiters align with the opening
  indentation level;
- empty objects and arrays, if introduced by a compatible extension, are
  written `{}` and `[]`;
- strings contain Unicode scalar values in NFC, use UTF-8 directly for
  non-ASCII scalars, escape `"` and `\`, never escape `/`, use `\b`, `\f`,
  `\n`, `\r`, and `\t` for those controls, and use lowercase `\u00xx` for
  another C0 control;
- unpaired surrogates and invalid UTF-8 are rejected;
- integers use unsigned base-10 digits with no sign or leading zero except
  the single digit `0`; and
- booleans and null are exactly `false`, `true`, and `null`.

Current v1 display and message fields reject control characters, so their
escape rules are defensive format rules rather than a way to embed multiline
presentation. Unknown fields and duplicate keys are rejected before semantic
validation.

The existing `kofun.typed-sidecar/v1` and KSE/semantic-event v1 formats are
not extended in place. Readers for those versions continue to reject unknown
fields or tags. A future transport may reference the trace as a separately
versioned artifact only after its own review.

## CLI and tooling

The first implementation ships only when the compiler trace producer and
both commands pass executable gates:

```text
kofun type eval <TypeExpr>
kofun type explain <TypeExpr>
```

`type eval` prints the named normal form. `type explain` renders complete
trace records up to 64 KiB of UTF-8 text. If text exceeds that limit, it stops
at a complete-record boundary and reports the exact omitted-step count.
Structured consumers can obtain all retained records within the 4 MiB
structured limit.

LSP one-step expansion, typed-hole discovery, inlay hints, and an interactive
type debugger are consumers of the same structured facts. They do not rerun
an editor-specific reducer or scrape diagnostic prose. Typed holes and
operation discovery remain owned by the discovery work (#635/#637); they are
not new type-language forms.

A type-level feature may ship only with a named-form renderer and trace
support that fits this contract. If its reduction cannot be explained one
named arm at a time within the fixed budgets, the feature is rejected or
bounded further.

## Implementation status and compatibility

This document is a design contract. The active compiler does not parse
`type fn`, kind-check type functions, reduce them, emit reduction traces, or
provide `kofun type eval`/`kofun type explain`.

Landing this specification and its schema vectors does not claim executable
language support. Existing source programs, compiler artifacts, typed
sidecars, and semantic-event streams gain no new accepted syntax or field.
The first executable slice requires a separate implementation change and
conformance evidence.

## Review checklist for future type-system RFCs

Every proposal that adds or changes a type-level form must state:

1. its name, owner, explicit kinds, and whether it changes the v1 grammar;
2. why an existing named v1 form is insufficient;
3. its termination proof and exact frame/step/node accounting;
4. its deterministic evaluation and cache identity rules;
5. its named input, output, hover, and diagnostic rendering;
6. every new structured trace record or schema version;
7. executable success, rejection, limit, cache-warm, and cache-cold vectors;
8. how CLI, LSP, and debugger consumers render the same facts;
9. the maximum diagnostic and trace sizes; and
10. compatibility and migration behavior for existing source and artifacts.

A proposal without bounded reduction and inspectable named traces is
incomplete and cannot be described as implemented.

Two proposals currently answer this checklist, and both are `proposed` in the
decision ledger — neither amends this document:

- [`rfcs/0008-type-level-general-v2.md`](../rfcs/0008-type-level-general-v2.md)
  ([#1130](https://github.com/kofun-lang/kofun/issues/1130)) owns the
  termination axis. It proposes a `type fn general` cost class reduced under a
  second named profile whose limits are versioned language semantics, so a
  non-structural recursion is refused with an attributable diagnostic instead
  of being unspellable.
- [`rfcs/0009-type-level-kinds-v1.md`](../rfcs/0009-type-level-kinds-v1.md)
  ([#1133](https://github.com/kofun-lang/kofun/issues/1133)) owns the kind
  axis. It proposes `Nat`, `Symbol`, and `Bool` as type-level data beside
  `Type`, keeping the structural termination discipline this document fixes
  and adding a third named profile, because the 32-frame limit above — not
  the step budget — is what a scalar-by-scalar descent over a string reaches
  first.

They are separable, and the split is deliberate: the Type-only restriction and
the structural-termination restriction block different programs, so accepting
either one alone is a different language than accepting both. Neither is an
implementation-defined knob: each proposal's limits belong to its named
profile and version with it, which is the property the row above calls
deterministic checking.

# Concrete law declaration HIR v1

`kofun-stage2 --emit-law-hir INPUT.kofun OUTPUT.json LOGICAL-PATH` resolves one
ground law family, one named implementation, and one check in an anonymous
source file. Both Stage 2 halves emit the same UTF-8 JSON document terminated
by LF. The logical path follows scope-HIR v2 and determines the existing
`kofun.id.file/v1` identity. Diagnostics precede publication and preserve a
pre-existing destination. The input and output must refer to distinct files.

The source model is specified in [the law design](../../docs/LAW_SYSTEM.md).
The bounded entry supports `Bool` and `Bool?` substitutions, first-order
schema slots, fixed-arity callable signatures, operation references and calls,
typed equation lambdas, and structural equality. The family, implementation,
check and ordinary function definitions can appear in any order. Domain
declarations retain source order. An `all_functions(input, output)` domain
uses the types of two previously declared domains. Checks can request
`bounded_exhaustive` or `proven_finite` under `standard`. Source limits are
16,384 bytes and 1,024 tokens; type nesting is bounded at 16 and expression
nesting at 32. Family, operation and domain names remain user-defined.

## Artifact

The root fields are `schema`, `file_id`, `functions`, `family`,
`implementation` and `check`. A declaration's `span` covers its identifier.
`declaration_span` covers the whole top-level declaration, operation signature,
or equation. All spans are half-open UTF-8 byte offsets in the same file.

- `functions` contains checked **signatures**. Source bodies are opaque to
  declaration analysis. Function names and parameter names have source spans.
- `family.slots` lists ground substitutions in binder order with a span for
  each ground argument. Operation parameters and results, equation parameters,
  and equation subexpressions all carry their substituted types. Callable
  types spell their argument vector explicitly, e.g. `(Bool)->Bool?` and
  `(Bool?,(Bool)->Bool?)->Bool?`.
- `family.equations` preserves declaration order. A parameter points to its
  typed domain. Each equation contains an equality with Boolean result,
  a left operand and a right operand. A `ref` points to the byte where its
  binding name begins. A `call` records a typed callee and ordered arguments.
  A `lambda` introduces a nested parameter scope and carries its body tree.
- `implementation` identifies the resolved family and maps each required
  operation to one declared function of the exact substituted signature.
  Every reference offset names a declaration within this artifact's file.
- `check` identifies the implementation, the ordered typed domains and their
  origins, the selected equality, the requested assurance, and the budget.
  These are inputs for future evaluation. The HIR contains no computed
  assurance, evidence identity, case counts, or executable proof.

## Refusals and acceptance

| Code | Trigger |
| --- | --- |
| E2S228 | Invalid declaration syntax, an input outside the bounded profile, or an invalid publication request |
| E2S229 | Unresolved, missing, or duplicate declaration, binding, or domain |
| E2S230 | Operation signature, call arguments, equality operands, or domain type mismatch |
| E2S231 | Unsupported ground type, substitution, or carrier for equality or enumeration |

Ordinary `--compile-outcome` preserves its existing outcome for a file
requiring law evaluation. `task law-declaration-hir` invokes both compiler
dispatchers and verifies the source spans, targets, expression types and
tree shape of the [canonical Boolean/Optional example](../../tests/usability/06_monad_laws.kofun).
It also exercises a second family, forward resolution, contextual identifiers,
refusal bytes, output preservation and ordinary non-law compilation.

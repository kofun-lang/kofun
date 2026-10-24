# Bounded nominal ADT frontend

This issue #328 gate parses and type-checks one deliberately small Stage 2
surface: non-generic top-level sum types with at least two flat constructors.
A constructor has either no payload or one named `Int` payload. Functions in
the gate return one constructor expression and produce typed textual IR only.
Payload expressions accept the bounded Stage 2 Int Core:

```text
int-expression := product (("+" | "-") product)*
product        := unary (("*" | "//" | "%") unary)*
unary          := ("+" | "-") unary | primary
primary        := integer | "(" int-expression ")"
```

The frontend is two phase. It first collects all ADT and constructor
declarations, then resolves function bodies, so `present` in
`maybe_int.kofun` can use `Present` before the `MaybeInt` declaration. The IR
stores a nominal `adt:<name>` ID and constructor `(AdtId, local-index)` ID at
both declarations and uses, plus exact byte spans. These bounded single-file
IDs are replaced by production ModuleId/NamespaceId/SymbolId values when #111
integrates the table into the general resolver.

This dedicated frontend intentionally has no value layout, allocation,
matching, interpreter, or backend. Its typed IR records the resolved
constructor identity and `Int` payload type, not an evaluated payload value.
Separately, the smaller concrete-enum profile in
`enum_payload_functions.kofun` lowers the same zero/one-`Int` shape through
Stage 2 C11, including function arguments, returns, guarded payload reads, and
a binding catch-all that is matched again. The syntax checkpoint also runs
this shared fixture through the public CLI. Since #1697 the same concrete-enum
profile also carries one flat `Int`/`Bool` record as a constructor's payload
(`spec/adt-record-payload-v1.md`, gated by `task http-client-errors`); this
standalone frontend still admits only the zero/one-`Int` shape. Native and Wasm lowering remain
outside both checkpoints. #120 owns the shared layout authority, while
#73/#93/#118 consume the typed constructor table for patterns, exhaustiveness,
and wider lowering.

Run:

```sh
sh tests/conformance/adt/run.sh
```

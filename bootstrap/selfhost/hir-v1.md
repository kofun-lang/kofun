# Typed HIR v1: `kofun.selfhost-hir/v1`

This document freezes the typed high-level IR contract between the #619
frontend and the #620–#622 C11 backend for the first self-host fixed point.
The HIR owns semantics: the backend consumes these records without reparsing
source text, inferring types from spelling, or scraping rendered diagnostics.
No private C struct layout is a serialized interface; this document is the
interface.

The schema covers exactly the frozen 46-row profile of the canonical source
`S` pinned by `profile.meta`. It is versioned: any record, field, kind, or
ordering change requires `kofun.selfhost-hir/v2` and an explicit profile
revision that names the affected rows, following the #618 revision rule.

## Serialization

A HIR document is deterministic UTF-8 text: one record per line, fields
separated by `|`, terminated by `\n`. Text payload fields (literal values,
diagnostic text) escape `\` as `\\`, `|` as `\p`, and newline as `\n` so every
record stays on one line. Two runs over identical input bytes must produce
byte-identical documents.

The header is exactly:

```text
schema|kofun.selfhost-hir/v1
source|PATH|SHA256
status|complete
```

or, when the input uses any construct outside the frozen profile:

```text
schema|kofun.selfhost-hir/v1
source|PATH|SHA256
status|rejected
```

A `complete` document contains the full record sequence below and no
`unsupported` records. A `rejected` document contains one or more `diagnostic`
records and may additionally contain `unsupported` records; it contains no
other record kind after the header. The frontend never emits a partial typed
document and never falls back to another compiler stage.

## Identities and spans

- `TYPEID`, `SCOPEID`, `SYMBOLID`, `BINDINGID`, and `NODEID` are dense decimal
  ordinals starting at 0, each namespace independent, assigned in the record
  emission order defined below. They are document-local; the typed sidecar's
  hashed identities remain a separate tooling artifact.
- Every span is `START|END`: 0-based byte offsets into the exact source bytes,
  end-exclusive, with `START < END`, both on UTF-8 boundary positions. Every
  declared name, expression, and statement records the exact span of its own
  source text.

## Record order

After the header, records appear in exactly this order:

1. `type` records, ordered by `TYPEID`;
2. `scope` records, ordered by `SCOPEID` (pre-order over the scope tree);
3. `symbol` records, ordered by `SYMBOLID`;
4. `binding` records, ordered by `BINDINGID`;
5. `function` records in source order, each followed by the pre-order `node`
   records of its body;
6. `diagnostic` records in source order (empty for an accepted document).

## Types

```text
type|TYPEID|int
type|TYPEID|bool
type|TYPEID|text
type|TYPEID|void
type|TYPEID|list-text
type|TYPEID|fn|RESULT_TYPEID|PARAM_TYPEID*
```

The universe is closed: exactly the scalar types, `List[Text]`, and the
function types used by `S` and its 16 builtins. `fn` parameter ids are a
possibly empty `|`-separated tail. No other type may appear in v1.

## Scopes, symbols, bindings

```text
scope|SCOPEID|PARENT_SCOPEID|KIND|START|END
symbol|SYMBOLID|KIND|NAME|TYPEID|START|END
binding|BINDINGID|SCOPEID|SYMBOLID|NAME|MUT|START|END
```

- Scope kinds: `module`, `function`, `block`. The module scope has
  `PARENT_SCOPEID` equal to its own id. Every `if`/`else if`/`else`, `while`,
  and `for` body is a `block` scope.
- Symbol kinds: `function`, `builtin`, `parameter`, `local`. Builtin symbols
  use span `0|0` markers on the module scope; all other spans point at the
  declaring name.
- `MUT` is `mut` or `imm`. Assignment targets must resolve to a `mut` binding.
- Shadowing is deterministic: a name reference resolves to the innermost
  binding whose scope contains the reference and whose declaration precedes
  it. Each `let` in a loop body introduces a fresh binding per lexical
  declaration, not per iteration.

## Builtin signatures

The 16 builtin symbols are frozen with exactly these types:

```text
args() -> List[Text]
chars(Text) -> List[Text]
contains(Text, Text) -> Bool
find(Text, Text) -> Int
is_digit(Text) -> Bool
is_space(Text) -> Bool
is_xid_continue(Text) -> Bool
len(Text) -> Int
len(List[Text]) -> Int
print(Text) -> Void
read_text(Text) -> Text
replace(Text, Text, Text) -> Text
starts_with(Text, Text) -> Bool
text_slice(Text, Int, Int) -> Text
trim(Text) -> Text
validate_unicode_source(Text) -> Text
write_text(Text, Text) -> Void
```

`len` is the only overloaded name: it is two distinct builtin symbols, and
every call site records the one resolved from its argument type. No other
overloading, coercion, or implicit conversion exists in v1.

## Functions and nodes

```text
function|NODEID|SYMBOLID|SCOPEID|START|END
node|NODEID|KIND|START|END|TYPEID|OWNERSHIP|FIELDS*
```

`OWNERSHIP` is a closed set: `copy` for produced `Int`/`Bool`/`Void` values,
`read` for borrowed `Text`/`List[Text]` reads, `edit` for assignment targets.

Node kinds and their kind-specific fields:

| kind | fields | notes |
|---|---|---|
| `literal-int` | `VALUE` | decimal, fits signed 64-bit |
| `literal-bool` | `true` or `false` | |
| `literal-text` | `ESCAPED_VALUE` | decoded escapes, then record escaping |
| `name` | `BINDINGID` | resolved reference |
| `call` | `SYMBOLID\|ARG_NODEID*` | direct or builtin call, arity checked |
| `unary` | `OP\|OPERAND_NODEID` | `!` on Bool; `-` on Int |
| `binary` | `OP\|LEFT_NODEID\|RIGHT_NODEID` | see operator table |
| `index` | `BASE_NODEID\|INDEX_NODEID` | base `List[Text]`, index `Int` |
| `range` | `LOW_NODEID\|HIGH_NODEID` | `Int .. Int`, only in `for` |
| `let` | `BINDINGID\|INIT_NODEID` | immutable local |
| `let-mut` | `BINDINGID\|INIT_NODEID` | mutable local |
| `assign` | `BINDINGID\|VALUE_NODEID` | target must be `mut` |
| `if` | `COND_NODEID\|THEN_SCOPEID\|ELSE_KIND\|ELSE_REF` | `ELSE_KIND` is `none`, `block`, or `if`; chained `else if` nests an `if` node |
| `while` | `COND_NODEID\|BODY_SCOPEID` | condition `Bool` |
| `for-range` | `BINDINGID\|RANGE_NODEID\|BODY_SCOPEID` | loop variable is an immutable `Int` binding |
| `return` | `VALUE_NODEID` or `none` | matches declared result type; `none` only in `Void` functions |
| `expr-stmt` | `VALUE_NODEID` | discarded value |

Binary operators: `+ - * / // %` on `Int -> Int`; `+` on `Text -> Text`
(concatenation); `== != < <= > >=` on operands of one equal type from
`Int`/`Bool`/`Text` producing `Bool`; `&& ||` on `Bool -> Bool`. The node's
recorded operand and result types disambiguate `+`; the backend must not
inspect spelling.

## Diagnostics and unsupported constructs

```text
diagnostic|CODE|START|END|ESCAPED_TEXT
unsupported|START|END|CONSTRUCT
```

Diagnostic codes are stable identifiers in the existing `E2Sxx` frontend
family; their text is byte-stable across runs. A syntactic construct family
with no v1 node representation produces an `unsupported` record naming that
family plus at least one diagnostic. Type and profile refusals use diagnostic
records alone; this includes E2S15 for a globally known builtin outside the
frozen 16-builtin vocabulary. In both cases the document status is `rejected`.
Silent fallback to Stage 1 or acceptance without typing is forbidden.

## Worked example

For the source (32 bytes of body shown with its spans elided):

```kofun
fn double(value: Int) -> Int {
    return value + value
}
```

a conforming document contains, among its records:

```text
schema|kofun.selfhost-hir/v1
source|example.kofun|SHA256
status|complete
type|0|int
type|1|fn|0|0
scope|0|0|module|...
scope|1|0|function|...
symbol|0|function|double|1|3|9
symbol|1|parameter|value|0|10|15
binding|0|0|0|double|imm|3|9
binding|1|1|1|value|imm|10|15
function|0|0|1|0|55
node|1|return|35|55|0|copy|2
node|2|binary|42|55|0|copy|+|3|4
node|3|name|42|47|0|copy|1
node|4|name|50|55|0|copy|1
```

## Validation

`bootstrap/selfhost/check-profile.sh --phase frontend` is the completion gate
for #619: it fails while any profile row's frontend cell is still `planned:`
evidence, and passes only when all 46 rows carry checked-in frontend evidence
conforming to this schema.

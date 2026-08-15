# Call arguments

This gate owns the accepted declaration/call surface, the checked-HIR fixed
slot binding, and the first executable backend slice.

`source_order_int.kofun` deliberately writes `as_second` before `as_first`.
Each value calls `observe`, so its golden distinguishes source evaluation
order (`2`, then `1`) from declaration/ABI order; the final `12` proves the
ordinary ABI vector is still `(left, right)`. The Stage 2 C11 emitter stores
each expression once in a function-local `int64_t` temporary through the C11
comma operator before making the declaration-order call.

The executable slice is intentionally limited to direct top-level functions
whose fixed parameter and result slots use `Int`, `Text`, `List[Int]`, `Int?`,
a concrete enum, or a nominal record carrier. `source_order_carriers.kofun`
mixes the first three in one call written out of declaration order:
the markers `1` and `3` print before the callee body's `42`, proving
source-order exactly-once evaluation. `source_order_wide.kofun` does the same
for `Int?`, enum, record, and `Int` slots in written order 3, 2, 0, 1 before
the declaration-order ABI vector 0, 1, 2, 3. `reordered_optional.kofun` pins
the Optional narrowing path independently.

Each slot is also asserted to be reserved with its own C carrier. A carrier
regression would already fail the strict `-Werror` build of the generated C,
but as an opaque diagnostic inside emitted code; these assertions name the
defect instead. They share one call-site key read out of slot 0, so they
describe a single call rather than three unrelated sites.

`owned_carrier.kofun` proves that a bare nominal-record binding passed to a
parameter declared `take` becomes one semantic move even though the C carrier
assignment is mechanically a copy. `double_move_carrier.kofun` pins the later
transfer to the existing exact E2S123 diagnostic. This is a source-order,
whole-binding increment, not general ownership inference or control-flow
analysis.

`trailing_lambda.kofun` is the accepted trailing form from #1191:
`combine(...) fn(total: Int) => total + 100`. The lambda binds the final
functional parameter without being written between the parentheses, which is
what makes it a separate proof from the cases above — an argument sits outside
the parentheses while the two orders inside them stay separate. Its golden
keeps all three facts visible at once: the labelled `2`, `1` still evaluate in
source order, the ABI vector is still declaration order (`12`), and the
trailing lambda runs last over that result (`112`).

The trailing lambda reserves no carrier. It is a lifted function's address, so
there is nothing to sequence ahead of the call, and an `int64_t` carrier would
both mistype the slot and be passed unassigned; the gate asserts two carriers
for a three-parameter call for exactly that reason. The lifted name is keyed by
the `(` of the lambda's parameter list, which is the identity the definition
walk and the reference walk already share.

`pipeline_subject.kofun` is the production #1190 recognizes:
`start |> add(delta: 2)` is **one** expression, not a subject and a call that
happen to sit either side of an operator. `|>` is the lowest-precedence
boundary in the grammar, which `pipeline_coalescing_subject.kofun` pins from
the other direction: `left ?? 4 |> add(delta: 2)` has `left ?? 4` as its
subject, so `??` binds first.

What recognition buys is the diagnostic. Before it, each of these reported an
argument list the author had not got wrong (`missing argument \`base\``, or
`expects 2 arguments, got 1`) and never mentioned the pipeline that was
actually unsupported.

#1226 then binds the subject to **slot 0**, before any explicit argument is
read, which is what keeps the rest of the binder free of special cases:
positional arguments start at slot 1 because slot 0 is taken, and a label
naming slot 0 lands on the ordinary duplicate path.
`pipeline_positional_rest.kofun` is the case where a missing binding would
otherwise be invisible — without it the written `2` binds slot 0 and the call
looks well formed. `pipeline_duplicate_slot_zero.kofun` writes `into:`, slot
0's declared label, and gets E2S163 against the declaration it collides with.
The externally labelled case proves the rule rather than a coincidence: the
subject satisfies `into` without that label appearing anywhere in the call.

#1227 then checks the bound call. Effective arity is one subject plus the
written arguments, so `pipeline_effective_arity.kofun` reports 3 for a
two-parameter callee. That case is worth its own assertion for a subtle reason:
the four canonical shapes stopped reaching `E2S17` the moment #1190 refused
them, whether or not anything counted — so only an *overflow* distinguishes a
correct count from an earlier refusal.

`pipeline_subject_type_mismatch.kofun` checks the subject against slot 0 and
reports at the subject's own span, because pointing at the callee would name
the one token that is not wrong.

The RFC-0010 transfer arrives without a label:
`pipeline_take_subject.kofun` pipes a bare binding into a `take` slot 0, so it
moves exactly once and the later use is the existing E2S123 with both spans.
`move_call_binding` admits it on the declared mode of slot 0 rather than on how
it was written — a subject is never written with a label — which is what leaves
the ordinary positional call outside that path.
`pipeline_compound_subject.kofun` is the other half: `left + right` transfers
nothing, because there is no binding for a move to invalidate. That case caught
a real defect. The bare-binding test measured the subject with `expression_end`,
which since #1190 swallows the whole `subject |> callee(...)`, so every subject
looked compound and no move was ever recorded. The subject's own extent has to
be measured with `coalescing_expression_end`.

#1228 lowers it. A checked pipeline now builds and runs through the **shared**
`emit_fixed_slot_call` and its existing temporary family — there is no
pipeline-only emitter, walker, or namespace. The subject is assigned to slot 0
before anything inside the parentheses, because that is where it is written, so
the loop over explicit arguments is unchanged and a positional rest simply
continues at slot 1.

`pipeline_source_order.kofun` is where the whole sequence is visible at once:
`1` is the subject and prints first, `2` is the explicit argument, and `12` is
the callee reading its slots in declaration order — subject first, each value
exactly once, ABI vector only after every assignment. The gate also asserts the
emitted C contains no labels, no runtime map or dispatch, no allocation, and no
`|>`; a second temporary family would surface there first.

A pipeline always takes fixed slots whatever it carries, unlike an ordinary
unlabelled call which needs a `List[Int]` to justify them. Its subject sits
outside the parentheses and must be assigned first, which the unsequenced call
cannot express.

The binder runs from inside the pipeline pass rather than from
`validate_core_calls`, because that pass returns first and the call validators
would never see the call — and it cannot simply run after them, since the arity
check counts only the parenthesised arguments and would report the subject as a
missing one. `validate_core_calls` therefore adds the subject to its own count
for a pipeline target, which is #1227's effective arity reaching the ordinary
path.

Because a recognizer that refuses everything is indistinguishable from one that
recognizes nothing, the gate asserts the **spans** the production publishes:
subject, its own end, the pipe, callee, parenthesis pair, and the whole
expression. Those are what #1226 inherits. The subject's end is its own, not
the pipe's offset; the two differ by the trivia between them.

The shapes outside the production each carry their own wording —
`pipeline_bare_target.kofun`, `pipeline_chain.kofun`, and
`pipeline_trailing_lambda.kofun` — so a later slice admitting one leaves the
others' evidence standing. The bare-target case is refused before scope
construction on purpose: a callee without parentheses is a name the scope
builder cannot resolve, so without an earlier refusal it reports
`E2S35 unknown lexical binding` about a binding the author never meant to
reference.

Bare pipeline targets, member pipeline targets, pipelines with trailing
lambdas, block-bodied trailing lambdas, labelled calls inside lifted lambdas,
and lexical/indirect targets remain unsupported at their existing E2S158 or
earlier named refusal boundaries and remain owned by #882. The one-stage direct
top-level Stage 2/C11 pipeline no longer belongs to that unsupported set: #1226
binds its subject to slot zero, #1227 checks it, and #1228 lowers it. Neither
does the chain. A pipeline chain is that production iterated: it associates
left, every stage binds, counts, checks and moves its own subject into slot 0,
and the C11 lowering nests each stage inside the next subject rather than
adding a second temporary family. A stage carrying a shape from the list above
still stops at that shape's own boundary rather than at a chain one.

Direct-native and Wasm behavior is measured by the same corpus: the labelled
Int call executes on both and is compared against the C11 golden, and every
other shape stops at one named source-located boundary per backend. #1192
landed the direct-native and Wasm differential.

One shape executes on all three: the all-Int labelled call. It is
asserted against `source_order_int.stdout` itself rather than a per-backend
copy, so no one has to restate what the right answer is — and because that
golden carries the source order (`2`, then `1`) as well as the result (`12`),
a backend that evaluated in declaration order fails it while still producing
the same number. Both artifacts are also searched for the labels themselves:
the C11 assertions read generated source, and these read the bytes that
shipped.

Every other shape stops at one named, source-located boundary per backend, and
the gate asserts the wording rather than merely that something failed. Each of
those messages used to describe the punctuation the parser wanted next —
`print(start |> add(delta: 2))` reported that print requires one Int or Text,
an `Int?` parameter reported a missing `,`, and a function-typed parameter
reported a missing `)`. All three named a token the author had written
correctly and none named the pipeline, the Optional, or the function type. The
boundaries themselves did not move: naming one is not admitting it.

The Text refusal wording is deliberately left alone. `spec/wasm-host-profile-v1`
owns it and pins it, which is why `pipeline_subject_type_mismatch` still stops
at its `"text"` subject on wasm32 rather than at its pipe.

The block-bodied trailing lambda and labelled call inside a lifted lambda are
different boundaries under one code, so `trailing_lambda_block.kofun` and
`lifted_lambda_call.kofun` are asserted separately rather than through one
pattern: the first is about what a trailing lambda's body may be, the second
about where a labelled call may appear. A slice that admits one must leave the
other's wording intact.

Supplying the final parameter twice — once by label and again by the trailing
lambda — is E2S167, not E2S158. It is a binding failure rather than a lowering
boundary: the shape is understood, and no later slice makes it legal.

`shadowed_callable.kofun` keeps lexical resolution load-bearing: a callable
parameter named like a supported top-level function must not be redirected to
that top-level ABI. The bounded slice refuses it before C emission.

`lifted_lambda_call.kofun` pins a second function-scope boundary. Lifted
lambdas become separate generated C functions, so this slice refuses a
labelled call in their body rather than declaring its temporaries in the
enclosing source function.

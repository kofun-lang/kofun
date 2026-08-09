# Closed `Equal[Int]` and `Ordered[Int]` C11 dictionary profiles

This corpus is the executable boundary below the existing
`kofun-traits-ir/v2` producer. The frontend emits the exact `TraitId`,
`MethodId`, descriptor, `ImplementationId`, derived `DictionaryId`, bound,
dictionary parameter, method slot, and dictionary argument. The standalone
C11 consumer validates one of two closed profiles. The original
`EqualIntDictionary` calls slot 0, while `OrderedIntDictionary` carries slot 0
and slot 1 and calls both through explicit function pointers.

Both fixture implementations return `true`; the consumer's fixed profile
callbacks therefore return `true` too. That is deliberately not general
method-body lowering. The profiles admit exactly the committed one-method
`Equal[Int] for Int` shape or the two-method `Ordered[Int] for Int` shape.
Generic nominal representations, arbitrary member counts or bounds, runtime
instance search, general vtables, monomorphisation, and KIF transport stay
outside this slice.

`run.sh` recompiles the unchanged typed producer and the standalone consumer,
pins both emitted IR files byte-for-byte, checks deterministic one-slot and
two-slot execution, and refuses identity, slot, entry, argument, duplicate,
truncation, and size-limit mutations. The two-slot lane separately refuses a
missing slot 1 entry, a duplicate slot index, and a descriptor whose
`slot-methods` order differs from its entries. Every accepted record kind has
an exact closed field set and exact values, including its span policy, so no
profile becomes a general IR reader. Both C11 programs use strict warnings;
the consumer passes GCC `-fanalyzer` and ASan/UBSan executions for both
profiles.

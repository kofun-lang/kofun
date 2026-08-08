# One-method `Equal[Int]` C11 dictionary profile

This corpus is the executable boundary below the existing
`kofun-traits-ir/v2` producer. The frontend emits the exact `TraitId`,
`MethodId`, descriptor, `ImplementationId`, derived `DictionaryId`, bound,
dictionary parameter, method slot, and dictionary argument. The standalone
C11 consumer validates that closed profile and calls slot 0 through an
explicit `EqualIntDictionary` function pointer.

The fixture implementation returns `true`; the consumer's fixed profile
callback therefore returns `true` too. That is deliberately not general
method-body lowering. The profile admits one method, one bound, one
`Equal[Int] for Int` implementation, and one `same[Int]` call only. Generic
nominal representations, multiple members or bounds, runtime instance search,
general vtables, monomorphisation, KIF transport, and the unresolved #995/#942
member model stay outside this slice.

`run.sh` recompiles the unchanged typed producer and the standalone consumer,
pins the emitted IR byte-for-byte, checks deterministic slot-0 execution, and
refuses identity, slot, entry, argument, duplicate, truncation, and size-limit
mutations. Every accepted record kind has an exact closed field set, including
its `span`/`use-span` policy; an unknown field on any of the 14 rows refuses
before dispatch. Every source range must also equal the committed fixed
fixture's exact producer output, so malformed, descending, leading-zero, and
extra-`=` variants refuse. Empty/trailing field segments also refuse. Both C11
programs use strict warnings; the consumer passes GCC
`-fanalyzer` and an ASan/UBSan execution lane.

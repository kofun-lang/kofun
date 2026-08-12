/*
 * The golden corpus: one document carrying all eleven v3 record kinds.
 *
 * It lives beside the gate rather than inside it so the bytes it produces can
 * be frozen as a sentinel and recomputed by anything else that wants to read
 * them. A fixture defined inside its own assertions cannot be compared with a
 * second implementation without exporting it anyway.
 */

import {
  AVAILABILITY,
  BINDER_KIND,
  COHERENCE,
  RECORD_KINDS,
  VISIBILITY,
  framedHash,
} from "./model.mjs";

export function id(seed) {
  return framedHash("kofun.test.fixture/v1", Buffer.from(seed, "utf8")).toString("hex");
}

export const TRAIT = id("trait:Comparable");
export const TRAIT_METHOD = id("method:compare");
export const TRAIT_BINDER = id("binder:trait:Self");
export const FUNCTION = id("function:sort");
export const FUNCTION_BINDER = id("binder:function:T");
export const TYPE = id("type:Pair");
export const TYPE_BINDER_A = id("binder:type:A");
export const TYPE_BINDER_B = id("binder:type:B");
export const CONSTRUCTED = id("constructed:Pair[Int,Text]");
export const DICTIONARY = id("dictionary:Comparable");
export const BODY = id("body:sort");
export const INSTANTIATION = id("instantiation:sort[Int]");
export const LAW = id("law:total-order");
export const INTERNAL_FUNCTION = id("function:internal-helper");
export const INTERNAL_BINDER = id("binder:internal:U");
export const PACKAGE = id("package:kofun.collections");
export const MODULE = id("module:kofun.collections.sort");
export const PRIMITIVE_INT = id("primitive:Int");
export const PROPOSITION = id("proposition:antisymmetry");
export const DIGEST_A = id("digest:body");
export const DIGEST_B = id("digest:interface");
export const DIGEST_C = id("digest:artifact");
export const DIGEST_D = id("digest:abi");
export const DIGEST_E = id("digest:signature");

/*
 * One fixture carrying all eleven record kinds. A per-kind fixture would let a
 * cross-record rule -- slot agreement, binder ownership, visibility closure --
 * pass because nothing else was present to disagree with.
 */
export function canonicalDocument() {
  return {
    edition: "kofun-2026",
    packageId: PACKAGE,
    moduleId: MODULE,
    publicRecords: [
      {
        kind: RECORD_KINDS.TypeBinder,
        id: TYPE_BINDER_A,
        owner: TYPE,
        binderKind: BINDER_KIND.type,
        ordinal: 0,
      },
      {
        kind: RECORD_KINDS.TypeBinder,
        id: TYPE_BINDER_B,
        owner: TYPE,
        binderKind: BINDER_KIND.type,
        ordinal: 1,
      },
      {
        kind: RECORD_KINDS.TypeBinder,
        id: FUNCTION_BINDER,
        owner: FUNCTION,
        binderKind: BINDER_KIND.type,
        ordinal: 0,
      },
      {
        kind: RECORD_KINDS.TypeBinder,
        id: TRAIT_BINDER,
        owner: TRAIT,
        binderKind: BINDER_KIND.type,
        ordinal: 0,
      },
      {
        kind: RECORD_KINDS.GenericTypeDeclaration,
        id: TYPE,
        visibility: VISIBILITY.public,
        binders: [TYPE_BINDER_A, TYPE_BINDER_B],
        shape: {
          tag: "record",
          fields: [
            { name: "left", byValue: true, type: { tag: "parameter", id: TYPE_BINDER_A } },
            { name: "right", byValue: true, type: { tag: "parameter", id: TYPE_BINDER_B } },
          ],
        },
        bodyAvailability: AVAILABILITY.sourceFree,
      },
      {
        kind: RECORD_KINDS.ConstructedTypeRef,
        id: CONSTRUCTED,
        declaration: TYPE,
        arguments: [
          { tag: "primitive", id: PRIMITIVE_INT },
          { tag: "parameter", id: FUNCTION_BINDER },
        ],
      },
      {
        kind: RECORD_KINDS.GenericFunctionDeclaration,
        id: FUNCTION,
        visibility: VISIBILITY.public,
        binders: [FUNCTION_BINDER],
        parameters: [{ tag: "constructed", id: CONSTRUCTED }],
        result: { tag: "parameter", id: FUNCTION_BINDER },
        modes: [1],
        effects: 0,
        bounds: [{ trait: TRAIT, subject: { tag: "parameter", id: FUNCTION_BINDER } }],
        bodyAvailability: AVAILABILITY.sourceFree,
      },
      {
        kind: RECORD_KINDS.TraitDeclaration,
        id: TRAIT,
        owner: PACKAGE,
        visibility: VISIBILITY.public,
        binders: [TRAIT_BINDER],
        methods: [TRAIT_METHOD],
        laws: [LAW],
      },
      {
        kind: RECORD_KINDS.TraitMethod,
        id: TRAIT_METHOD,
        trait: TRAIT,
        slot: 0,
        parameters: [
          { tag: "parameter", id: TRAIT_BINDER },
          { tag: "parameter", id: TRAIT_BINDER },
        ],
        result: { tag: "primitive", id: PRIMITIVE_INT },
        modes: [1, 1],
        effects: 0,
      },
      {
        kind: RECORD_KINDS.Implementation,
        id: id("implementation:Comparable[Int]"),
        owner: PACKAGE,
        trait: TRAIT,
        self: { tag: "primitive", id: PRIMITIVE_INT },
        binders: [],
        bounds: [],
        coherence: COHERENCE.orphanFree,
        visibility: VISIBILITY.public,
        methodBodies: [{ method: TRAIT_METHOD, bodyDigest: DIGEST_A }],
      },
      {
        kind: RECORD_KINDS.DictionaryAbi,
        id: DICTIONARY,
        trait: TRAIT,
        abiVersion: 1,
        slots: [{ slot: 0, method: TRAIT_METHOD, signatureDigest: DIGEST_E }],
      },
      {
        kind: RECORD_KINDS.GenericBodyTemplate,
        id: BODY,
        declaration: FUNCTION,
        typedCore: Buffer.from("core:sort", "utf8"),
        binderMap: [{ binder: FUNCTION_BINDER, slot: 0 }],
        layoutInputs: 1,
        effectInputs: 0,
        cleanupInputs: 2,
        bodyDigest: DIGEST_A,
      },
      {
        kind: RECORD_KINDS.PublishedInstantiation,
        id: INSTANTIATION,
        declaration: FUNCTION,
        arguments: [{ tag: "primitive", id: PRIMITIVE_INT }],
        availability: AVAILABILITY.sourceFree,
        artifactDigest: DIGEST_C,
        bodyDigest: DIGEST_A,
        abiDigest: DIGEST_D,
      },
      {
        kind: RECORD_KINDS.GenericLawReference,
        id: LAW,
        proposition: PROPOSITION,
        requiredImplementations: [id("implementation:Comparable[Int]")],
        bodyDigest: DIGEST_A,
        interfaceDigest: DIGEST_B,
        evidenceAvailability: AVAILABILITY.sourceFree,
      },
    ],
    internalRecords: [
      {
        kind: RECORD_KINDS.TypeBinder,
        id: INTERNAL_BINDER,
        owner: INTERNAL_FUNCTION,
        binderKind: BINDER_KIND.type,
        ordinal: 0,
      },
      {
        kind: RECORD_KINDS.GenericFunctionDeclaration,
        id: INTERNAL_FUNCTION,
        visibility: VISIBILITY.internal,
        binders: [INTERNAL_BINDER],
        parameters: [{ tag: "parameter", id: INTERNAL_BINDER }],
        result: { tag: "primitive", id: PRIMITIVE_INT },
        modes: [1],
        effects: 0,
        bounds: [],
        bodyAvailability: AVAILABILITY.packageOnly,
      },
    ],
  };
}

export const externalIds = new Set([PRIMITIVE_INT, PROPOSITION]);
export const decodeOptions = { externalIds };

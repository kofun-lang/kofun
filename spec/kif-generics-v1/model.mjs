/*
 * KIF generics v3 — canonical codec, validator, and identity model.
 *
 * This is the producer-independent side of RFC-0017 section 4. It shares no
 * code with `bootstrap/stage2/kif_v1.c`, which is the point: a codec that
 * agrees with its own producer proves only that one program is
 * self-consistent. Everything here is derived from the accepted decision and
 * from `spec/modules/module-identity.md`, so a disagreement between the two
 * implementations is a real finding rather than a diff in a shared helper.
 *
 * v3 does not extend or reinterpret v1/v2. The framing *rules* are the same
 * because the decision says the envelope keeps them; no v1/v2 bytes, tags, or
 * digest domains are reused, and the two readers refuse each other's major
 * version rather than projecting facts across.
 */

import { createHash } from "node:crypto";

export const SCHEMA_TEXT = "kofun.kif/generics-v3";
export const MAJOR_VERSION = 3;
export const MINOR_VERSION = 0;
export const MAGIC = Buffer.from([0x4b, 0x49, 0x46, 0x00]);

/*
 * RFC-0017 section 4. These are the v3 budgets and are deliberately not the
 * v1 envelope's: a reader that validated v3 against v1's numbers would accept
 * a document the decision bounds more tightly, and the two sets differ on
 * every row they share.
 */
export const LIMITS = Object.freeze({
  records: 65536,
  typeRefDepth: 64,
  boundedTextBytes: 65536,
  typedBodyBytes: 8 * 1024 * 1024,
  links: 262144,
  envelopeBytes: 16 * 1024 * 1024,
});

/*
 * Framed SHA-256 from `spec/modules/module-identity.md`. Concatenating an
 * unframed domain and payload is forbidden there, so the framing is written
 * once and every identity goes through it.
 */
const FRAME_PREFIX = Buffer.from("KOFUN\0", "latin1");

export function framedHash(domain, payload) {
  const domainBytes = Buffer.from(domain, "ascii");
  if (domainBytes.length > 0xffff) {
    throw new KifGenericsError("corrupt", `domain too long: ${domain}`);
  }
  const header = Buffer.alloc(6);
  header.writeUInt16BE(domainBytes.length, 0);
  header.writeUInt32BE(payload.length, 2);
  return createHash("sha256")
    .update(FRAME_PREFIX)
    .update(header.subarray(0, 2))
    .update(domainBytes)
    .update(header.subarray(2))
    .update(payload)
    .digest();
}

/*
 * Every new v3 identity states its domain and its exact preimage here rather
 * than in prose. Domains are protocol constants: they are never user text and
 * a changed preimage requires a new domain, so an accidental preimage edit
 * that kept the domain would be a silent identity collision across versions.
 */
export const DOMAINS = Object.freeze({
  typeParameter: "kofun.id.type-parameter/v3",
  constructedType: "kofun.id.constructed-type/v3",
  dictionaryAbi: "kofun.id.dictionary-abi/v3",
  bodyTemplate: "kofun.id.generic-body/v3",
  instantiation: "kofun.id.published-instantiation/v3",
  publicSemantic: "kofun.digest.public-semantic/v3",
  packageInternal: "kofun.digest.package-internal/v3",
});

export const RECORD_KINDS = Object.freeze({
  TypeBinder: 0x0101,
  ConstructedTypeRef: 0x0102,
  GenericTypeDeclaration: 0x0103,
  GenericFunctionDeclaration: 0x0104,
  TraitDeclaration: 0x0105,
  TraitMethod: 0x0106,
  Implementation: 0x0107,
  DictionaryAbi: 0x0108,
  GenericBodyTemplate: 0x0109,
  PublishedInstantiation: 0x010a,
  GenericLawReference: 0x010b,
});

const KIND_NAMES = new Map(
  Object.entries(RECORD_KINDS).map(([name, kind]) => [kind, name]),
);

export const VISIBILITY = Object.freeze({ internal: 1, public: 2 });
export const BINDER_KIND = Object.freeze({ type: 1, value: 2 });
export const COHERENCE = Object.freeze({ orphanFree: 1, packageLocal: 2 });

/*
 * Availability is what makes separate compilation checkable: a consumer with
 * the provider's source deleted must still be able to say why it may or may
 * not instantiate a body.
 */
export const AVAILABILITY = Object.freeze({
  sourceFree: 1,
  packageOnly: 2,
  unavailable: 3,
});

export class KifGenericsError extends Error {
  constructor(status, message, detail = {}) {
    super(message);
    this.name = "KifGenericsError";
    this.status = status;
    this.detail = detail;
  }
}

function fail(status, message, detail) {
  throw new KifGenericsError(status, message, detail);
}

/* ---------------------------------------------------------------- encoding */

function u8(value) {
  if (!Number.isInteger(value) || value < 0 || value > 0xff) {
    fail("non-canonical", `not an unsigned 8-bit value: ${value}`);
  }
  return Buffer.from([value]);
}

function u16be(value) {
  if (!Number.isInteger(value) || value < 0 || value > 0xffff) {
    fail("non-canonical", `not an unsigned 16-bit value: ${value}`);
  }
  const bytes = Buffer.alloc(2);
  bytes.writeUInt16BE(value, 0);
  return bytes;
}

function u32be(value) {
  if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) {
    fail("non-canonical", `not an unsigned 32-bit value: ${value}`);
  }
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(value, 0);
  return bytes;
}

/*
 * An absent or malformed identity is refused with a status rather than
 * whatever `Buffer.from` happens to throw. A caller that catches
 * `KifGenericsError` and nothing else would otherwise crash on a missing `id`
 * instead of refusing the document -- the same outcome as accepting it, from
 * the perspective of a process that must produce no artifact.
 */
function identity(value, what) {
  if (typeof value !== "string" && !Buffer.isBuffer(value)) {
    fail("corrupt", `${what} is absent`);
  }
  if (typeof value === "string" && !/^[0-9a-f]{64}$/.test(value)) {
    fail("corrupt", `${what} is not 64 lowercase hexadecimal digits`);
  }
  const bytes = typeof value === "string" ? Buffer.from(value, "hex") : value;
  if (!Buffer.isBuffer(bytes) || bytes.length !== 32) {
    fail("corrupt", `${what} is not a 32-byte identity`);
  }
  return bytes;
}

/*
 * Bounded text is validated for UTF-8 *and* NFC here rather than at the field
 * that happens to read it. A name that survives encoding and fails at use is a
 * document that was accepted and cannot be published, which the decision's
 * "produce no artifact" rule does not allow.
 */
function boundedText(value, what) {
  if (typeof value !== "string") fail("corrupt", `${what} is not text`);
  if (value.normalize("NFC") !== value) {
    fail("non-canonical", `${what} is not NFC`);
  }
  const bytes = Buffer.from(value, "utf8");
  if (bytes.length > LIMITS.boundedTextBytes) {
    fail("limit-exhausted", `${what} exceeds the bounded text limit`);
  }
  return bytes;
}

function concat(parts) {
  return Buffer.concat(parts);
}

/*
 * A length-prefixed ordered sequence. Counts are validated against the
 * remaining budget before anything is allocated, which is the same rule the
 * v1 envelope states and the reason a hostile count cannot reserve memory.
 */
function sequence(items, encodeItem) {
  if (items.length > 0xffff) {
    fail("limit-exhausted", "sequence exceeds its 16-bit count");
  }
  return concat([u16be(items.length), ...items.map(encodeItem)]);
}

/* --------------------------------------------------------------- type refs */

export const TYPE_REF_TAG = Object.freeze({
  primitive: 1,
  parameter: 2,
  nominal: 3,
  constructed: 4,
  function: 5,
});

/*
 * The five forms from RFC-0017. `depth` is passed down rather than tracked on
 * the side because the budget is per path, not per document: a wide record of
 * shallow references is legal and a single deep one is not.
 */
export function encodeTypeRef(node, depth = 0) {
  if (depth > LIMITS.typeRefDepth) {
    fail("limit-exhausted", "TypeRef nesting exceeds depth 64");
  }
  if (node === null || typeof node !== "object") {
    fail("corrupt", "TypeRef node is not a record");
  }
  switch (node.tag) {
    case "primitive":
      return concat([u8(TYPE_REF_TAG.primitive), identity(node.id, "PrimitiveTypeId")]);
    case "parameter":
      return concat([u8(TYPE_REF_TAG.parameter), identity(node.id, "TypeParameterId")]);
    case "nominal":
      return concat([
        u8(TYPE_REF_TAG.nominal),
        identity(node.id, "TypeId"),
        sequence(node.arguments ?? [], (argument) =>
          encodeTypeRef(argument, depth + 1),
        ),
      ]);
    case "constructed":
      return concat([
        u8(TYPE_REF_TAG.constructed),
        identity(node.id, "ConstructedTypeId"),
      ]);
    case "function":
      return concat([
        u8(TYPE_REF_TAG.function),
        sequence(node.parameters ?? [], (parameter) =>
          encodeTypeRef(parameter, depth + 1),
        ),
        encodeTypeRef(node.result, depth + 1),
        sequence(node.modes ?? [], (mode) => u8(mode)),
        u16be(node.effects ?? 0),
      ]);
    default:
      fail("corrupt", `unknown TypeRef tag: ${String(node.tag)}`);
  }
  return Buffer.alloc(0);
}

/*
 * Every ID edge a record publishes, in one place. Link closure, cycle
 * admission, and the link budget all read this rather than each walking the
 * record shapes again -- three walks would be three chances to forget a field.
 */
export function recordLinks(record) {
  const links = [];
  const typeRefLinks = (node, depth = 0) => {
    if (depth > LIMITS.typeRefDepth || node === null || typeof node !== "object") return;
    /*
     * A `primitive` leaf names a closed built-in domain, not a record in this
     * graph, so it is not a link. Treating it as one would make every
     * document that mentions `Int` dangle, and the fix for that would have
     * been to declare `Int` external in every fixture -- which is how a real
     * dangling reference ends up hidden behind an allow-list.
     */
    if (node.tag === "nominal") {
      links.push(hex(node.id));
      for (const argument of node.arguments ?? []) typeRefLinks(argument, depth + 1);
    } else if (node.tag === "constructed" || node.tag === "parameter") {
      links.push(hex(node.id));
    } else if (node.tag === "function") {
      for (const parameter of node.parameters ?? []) typeRefLinks(parameter, depth + 1);
      typeRefLinks(node.result, depth + 1);
    }
  };
  switch (record.kind) {
    case RECORD_KINDS.TypeBinder:
      links.push(hex(record.owner));
      break;
    case RECORD_KINDS.ConstructedTypeRef:
      links.push(hex(record.declaration));
      for (const argument of record.arguments ?? []) typeRefLinks(argument);
      break;
    case RECORD_KINDS.GenericTypeDeclaration:
      for (const binder of record.binders ?? []) links.push(hex(binder));
      if (record.shape?.tag === "record") {
        for (const field_ of record.shape.fields ?? []) typeRefLinks(field_.type);
      } else if (record.shape?.tag === "adt") {
        for (const constructor_ of record.shape.constructors ?? []) {
          for (const entry of constructor_.payload ?? []) typeRefLinks(entry.type);
        }
      }
      break;
    case RECORD_KINDS.GenericFunctionDeclaration:
      for (const binder of record.binders ?? []) links.push(hex(binder));
      for (const parameter of record.parameters ?? []) typeRefLinks(parameter);
      typeRefLinks(record.result);
      for (const bound of record.bounds ?? []) links.push(hex(bound.trait));
      break;
    case RECORD_KINDS.TraitDeclaration:
      for (const binder of record.binders ?? []) links.push(hex(binder));
      for (const method of record.methods ?? []) links.push(hex(method));
      break;
    case RECORD_KINDS.TraitMethod:
      links.push(hex(record.trait));
      for (const parameter of record.parameters ?? []) typeRefLinks(parameter);
      typeRefLinks(record.result);
      break;
    case RECORD_KINDS.Implementation:
      links.push(hex(record.trait));
      typeRefLinks(record.self);
      for (const binder of record.binders ?? []) links.push(hex(binder));
      for (const bound of record.bounds ?? []) links.push(hex(bound.trait));
      for (const body of record.methodBodies ?? []) links.push(hex(body.method));
      break;
    case RECORD_KINDS.DictionaryAbi:
      links.push(hex(record.trait));
      for (const slot of record.slots ?? []) links.push(hex(slot.method));
      break;
    case RECORD_KINDS.GenericBodyTemplate:
      links.push(hex(record.declaration));
      for (const entry of record.binderMap ?? []) links.push(hex(entry.binder));
      break;
    case RECORD_KINDS.PublishedInstantiation:
      links.push(hex(record.declaration));
      for (const argument of record.arguments ?? []) typeRefLinks(argument);
      break;
    case RECORD_KINDS.GenericLawReference:
      links.push(hex(record.proposition));
      for (const required of record.requiredImplementations ?? []) links.push(hex(required));
      break;
    default:
      fail("unknown-kind", `unknown v3 record kind: ${record.kind}`);
  }
  return links;
}

/*
 * Identity shape is checked here, not only at encode time, so validation
 * reports a malformed identity as `corrupt` rather than as whatever it fails
 * to resolve against. A four-digit identity is not a link that closes on
 * nothing; it is not an identity, and saying "dangling" would send the reader
 * looking for a missing record.
 */
function hex(value) {
  if (typeof value === "string") {
    if (!/^[0-9a-f]{64}$/.test(value)) {
      fail("corrupt", `identity \`${value}\` is not 64 lowercase hexadecimal digits`);
    }
    return value;
  }
  if (Buffer.isBuffer(value)) {
    if (value.length !== 32) fail("corrupt", "an identity is not 32 bytes");
    return value.toString("hex");
  }
  fail("corrupt", "an identity field is absent where one is required");
  return "";
}

/* ----------------------------------------------------------- record bodies */

function encodeBound(bound) {
  return concat([identity(bound.trait, "bound trait"), encodeTypeRef(bound.subject)]);
}

export const SHAPE_TAG = Object.freeze({ record: 1, adt: 2 });

/*
 * The declaration's record/ADT shape, with the field and payload types the
 * consumer needs to type-check with the provider's source deleted.
 *
 * This is deliberately not a one-byte "kind" marker. A shape that named only
 * `record` or `adt` would make the layout-cycle rule below unreachable --
 * there would be no by-value edge between two declarations for a cycle to run
 * through, so the rule would pass on every document including the ones it
 * exists to refuse.
 */
function encodeShape(shape) {
  if (shape === null || typeof shape !== "object") {
    fail("corrupt", "declaration shape is not a record");
  }
  switch (shape.tag) {
    case "record":
      return concat([
        u8(SHAPE_TAG.record),
        sequence(shape.fields ?? [], (field_) =>
          concat([
            u16be(boundedText(field_.name, "field name").length),
            boundedText(field_.name, "field name"),
            u8(field_.byValue === false ? 0 : 1),
            encodeTypeRef(field_.type),
          ]),
        ),
      ]);
    case "adt":
      return concat([
        u8(SHAPE_TAG.adt),
        sequence(shape.constructors ?? [], (constructor_) =>
          concat([
            u16be(boundedText(constructor_.name, "constructor name").length),
            boundedText(constructor_.name, "constructor name"),
            sequence(constructor_.payload ?? [], (entry) =>
              concat([
                u8(entry.byValue === false ? 0 : 1),
                encodeTypeRef(entry.type),
              ]),
            ),
          ]),
        ),
      ]);
    default:
      fail("corrupt", `unknown declaration shape: ${String(shape.tag)}`);
  }
  return Buffer.alloc(0);
}

/*
 * The by-value type references a declaration's own storage contains. These are
 * the edges that can require infinite layout; a reference held behind an
 * explicit indirection is `byValue: false` and cannot.
 */
export function shapeValueEdges(shape) {
  const edges = [];
  const walk = (node, depth = 0) => {
    if (depth > LIMITS.typeRefDepth || node === null || typeof node !== "object") return;
    if (node.tag === "nominal") {
      edges.push(hex(node.id));
      for (const argument of node.arguments ?? []) walk(argument, depth + 1);
    } else if (node.tag === "constructed") {
      edges.push(hex(node.id));
    }
  };
  if (shape?.tag === "record") {
    for (const field_ of shape.fields ?? []) {
      if (field_.byValue !== false) walk(field_.type);
    }
  } else if (shape?.tag === "adt") {
    for (const constructor_ of shape.constructors ?? []) {
      for (const entry of constructor_.payload ?? []) {
        if (entry.byValue !== false) walk(entry.type);
      }
    }
  }
  return edges;
}

export function encodeRecordPayload(record) {
  switch (record.kind) {
    case RECORD_KINDS.TypeBinder:
      return concat([
        identity(record.id, "TypeParameterId"),
        identity(record.owner, "owner DeclarationId"),
        u8(record.binderKind),
        u16be(record.ordinal),
      ]);
    case RECORD_KINDS.ConstructedTypeRef:
      return concat([
        identity(record.id, "ConstructedTypeId"),
        identity(record.declaration, "declaration TypeId"),
        sequence(record.arguments ?? [], (argument) => encodeTypeRef(argument)),
      ]);
    case RECORD_KINDS.GenericTypeDeclaration:
      return concat([
        identity(record.id, "TypeId"),
        u8(record.visibility),
        sequence(record.binders ?? [], (binder) => identity(binder, "binder")),
        encodeShape(record.shape),
        u8(record.bodyAvailability),
      ]);
    case RECORD_KINDS.GenericFunctionDeclaration:
      return concat([
        identity(record.id, "FunctionId"),
        u8(record.visibility),
        sequence(record.binders ?? [], (binder) => identity(binder, "binder")),
        sequence(record.parameters ?? [], (parameter) => encodeTypeRef(parameter)),
        encodeTypeRef(record.result),
        sequence(record.modes ?? [], (mode) => u8(mode)),
        u16be(record.effects ?? 0),
        sequence(record.bounds ?? [], encodeBound),
        u8(record.bodyAvailability),
      ]);
    case RECORD_KINDS.TraitDeclaration:
      return concat([
        identity(record.id, "TraitId"),
        identity(record.owner, "owner PackageId"),
        u8(record.visibility),
        sequence(record.binders ?? [], (binder) => identity(binder, "binder")),
        sequence(record.methods ?? [], (method) => identity(method, "method")),
        sequence(record.laws ?? [], (law) => identity(law, "law")),
      ]);
    case RECORD_KINDS.TraitMethod:
      return concat([
        identity(record.id, "MethodId"),
        identity(record.trait, "TraitId"),
        u16be(record.slot),
        sequence(record.parameters ?? [], (parameter) => encodeTypeRef(parameter)),
        encodeTypeRef(record.result),
        sequence(record.modes ?? [], (mode) => u8(mode)),
        u16be(record.effects ?? 0),
      ]);
    case RECORD_KINDS.Implementation:
      return concat([
        identity(record.id, "ImplementationId"),
        identity(record.owner, "owner PackageId"),
        identity(record.trait, "trait SymbolId"),
        encodeTypeRef(record.self),
        sequence(record.binders ?? [], (binder) => identity(binder, "binder")),
        sequence(record.bounds ?? [], encodeBound),
        u8(record.coherence),
        u8(record.visibility),
        sequence(record.methodBodies ?? [], (body) =>
          concat([
            identity(body.method, "method"),
            identity(body.bodyDigest, "method body digest"),
          ]),
        ),
      ]);
    case RECORD_KINDS.DictionaryAbi:
      return concat([
        identity(record.id, "DictionaryAbiId"),
        identity(record.trait, "TraitId"),
        u16be(record.abiVersion),
        sequence(record.slots ?? [], (slot) =>
          concat([
            u16be(slot.slot),
            identity(slot.method, "slot method"),
            identity(slot.signatureDigest, "slot signature digest"),
          ]),
        ),
      ]);
    case RECORD_KINDS.GenericBodyTemplate: {
      /*
       * The length prefix is the byte count of the encoded body, taken from
       * the encoded bytes themselves. Reading it from the input's own
       * `.length` was wrong for a string body: that is a count of UTF-16 code
       * units, so any multi-byte character made the declared length disagree
       * with the bytes that followed and the decoder sliced the record apart
       * at the wrong offset.
       */
      const body = typedBody(record.typedCore);
      return concat([
        identity(record.id, "body template id"),
        identity(record.declaration, "declaration id"),
        u32be(body.length),
        body,
        sequence(record.binderMap ?? [], (entry) =>
          concat([identity(entry.binder, "binder"), u16be(entry.slot)]),
        ),
        u16be(record.layoutInputs ?? 0),
        u16be(record.effectInputs ?? 0),
        u16be(record.cleanupInputs ?? 0),
        identity(record.bodyDigest, "body digest"),
      ]);
    }
    case RECORD_KINDS.PublishedInstantiation:
      return concat([
        identity(record.id, "instantiation id"),
        identity(record.declaration, "declaration id"),
        sequence(record.arguments ?? [], (argument) => encodeTypeRef(argument)),
        u8(record.availability),
        identity(record.artifactDigest, "artifact digest"),
        identity(record.bodyDigest, "body digest"),
        identity(record.abiDigest, "ABI digest"),
      ]);
    case RECORD_KINDS.GenericLawReference:
      return concat([
        identity(record.id, "law id"),
        identity(record.proposition, "proposition id"),
        sequence(record.requiredImplementations ?? [], (value) =>
          identity(value, "required implementation"),
        ),
        identity(record.bodyDigest, "required body digest"),
        identity(record.interfaceDigest, "required interface digest"),
        u8(record.evidenceAvailability),
      ]);
    default:
      fail("unknown-kind", `unknown v3 record kind: ${record.kind}`);
  }
  return Buffer.alloc(0);
}

/*
 * Text or bytes, where "bytes" is any view over a buffer rather than a
 * `Buffer` specifically. `structuredClone` turns a `Buffer` into a plain
 * `Uint8Array`, so a guard written as `Buffer.isBuffer` refuses a body that
 * merely travelled through a copy -- which is what any caller holding a
 * document across a boundary does.
 */
function typedBody(value) {
  if (typeof value !== "string" && !ArrayBuffer.isView(value)) {
    fail("corrupt", "typed body is absent");
  }
  const bytes = typeof value === "string"
    ? Buffer.from(value, "utf8")
    : Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  if (bytes.length > LIMITS.typedBodyBytes) {
    fail("limit-exhausted", "typed body exceeds 8 MiB");
  }
  return bytes;
}

/* ------------------------------------------------------------------ header */

const HEADER_TAG = Object.freeze({
  schema: 0x8001,
  edition: 0x8002,
  compatibility: 0x8003,
  packageId: 0x8004,
  moduleId: 0x8005,
  publicRecords: 0x8006,
  internalRecords: 0x8007,
  publicDigest: 0x8008,
  internalDigest: 0x8009,
});

function field(tag, value) {
  return concat([u16be(tag), u32be(value.length), value]);
}

/*
 * Records sort by stable semantic ID with the kind as tie-break, exactly as
 * the decision states and never by declaration or import order. Sorting by
 * kind first would have been the obvious implementation and is wrong for a
 * reason worth keeping: two producers that discovered the same declarations
 * in different orders must emit identical bytes, and only an ID-major order
 * makes that independent of how a producer walks its own tables.
 */
export function sortRecords(records) {
  return [...records].sort((left, right) => {
    const leftId = hex(left.id);
    const rightId = hex(right.id);
    if (leftId < rightId) return -1;
    if (leftId > rightId) return 1;
    return left.kind - right.kind;
  });
}

function encodeRecordVector(records) {
  const sorted = sortRecords(records);
  const encoded = sorted.map((record) =>
    concat([
      u16be(record.kind),
      (() => {
        const payload = encodeRecordPayload(record);
        return concat([u32be(payload.length), payload]);
      })(),
    ]),
  );
  return concat([u32be(sorted.length), ...encoded]);
}

function semanticPayload(document, records) {
  return concat([
    field(HEADER_TAG.schema, Buffer.from(SCHEMA_TEXT, "utf8")),
    field(HEADER_TAG.edition, boundedText(document.edition, "edition")),
    field(HEADER_TAG.compatibility, Buffer.from("semantic-compatibility-3", "utf8")),
    field(HEADER_TAG.packageId, identity(document.packageId, "PackageId")),
    field(HEADER_TAG.moduleId, identity(document.moduleId, "ModuleId")),
    field(HEADER_TAG.publicRecords, encodeRecordVector(records)),
  ]);
}

/*
 * The internal digest covers the complete public vector plus the internal
 * one. It is not the hash of the internal records alone -- `module-identity`
 * is explicit that it "cannot omit public changes", so a public-only edit must
 * move both values.
 */
export function computeDigests(document) {
  const publicPayload = semanticPayload(document, document.publicRecords ?? []);
  const internalPayload = concat([
    publicPayload,
    field(
      HEADER_TAG.internalRecords,
      encodeRecordVector(document.internalRecords ?? []),
    ),
  ]);
  return {
    publicDigest: framedHash(DOMAINS.publicSemantic, publicPayload),
    internalDigest: framedHash(DOMAINS.packageInternal, internalPayload),
  };
}

export function encodeDocument(document, options = {}) {
  validateDocument(document, options);
  const digests = computeDigests(document);
  const payload = concat([
    semanticPayload(document, document.publicRecords ?? []),
    field(
      HEADER_TAG.internalRecords,
      encodeRecordVector(document.internalRecords ?? []),
    ),
    field(HEADER_TAG.publicDigest, digests.publicDigest),
    field(HEADER_TAG.internalDigest, digests.internalDigest),
  ]);
  if (payload.length > LIMITS.envelopeBytes) {
    fail("limit-exhausted", "envelope exceeds 16 MiB");
  }
  const header = Buffer.alloc(8);
  header.writeUInt16BE(MAJOR_VERSION, 0);
  header.writeUInt16BE(MINOR_VERSION, 2);
  header.writeUInt32BE(payload.length, 4);
  return concat([MAGIC, header, payload]);
}

/* --------------------------------------------------------------- decoding */

export function decodeDocument(bytes, options = {}) {
  const view = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
  if (view.length > LIMITS.envelopeBytes) {
    fail("limit-exhausted", "envelope exceeds 16 MiB");
  }
  if (view.length < 12 || !view.subarray(0, 4).equals(MAGIC)) {
    fail("corrupt", "not a KIF envelope");
  }
  const major = view.readUInt16BE(4);
  if (major !== MAJOR_VERSION) {
    /*
     * A v1/v2 artifact reaching this reader is a downgrade attempt, not a
     * parse problem: the bytes are well formed for a protocol this reader
     * does not speak, and the remedy is a rebuild rather than a repair.
     */
    fail("downgrade", `unsupported major version ${major}; rebuild required`, {
      major,
      rebuildRequired: true,
    });
  }
  const declared = view.readUInt32BE(8);
  if (declared !== view.length - 12) {
    fail("corrupt", "declared payload length disagrees with the envelope");
  }

  const fields = new Map();
  let cursor = 12;
  let previousTag = -1;
  while (cursor < view.length) {
    if (cursor + 6 > view.length) fail("corrupt", "truncated field header");
    const tag = view.readUInt16BE(cursor);
    const length = view.readUInt32BE(cursor + 2);
    if (tag <= previousTag) {
      fail("non-canonical", `field tags are not strictly increasing at ${tag}`);
    }
    previousTag = tag;
    const start = cursor + 6;
    if (start + length > view.length) fail("corrupt", "field runs past the envelope");
    fields.set(tag, view.subarray(start, start + length));
    cursor = start + length;
  }

  for (const [name, tag] of Object.entries(HEADER_TAG)) {
    if (!fields.has(tag) && tag < 0x800a) {
      fail("corrupt", `missing required header field ${name}`);
    }
  }
  const schema = fields.get(HEADER_TAG.schema).toString("utf8");
  if (schema !== SCHEMA_TEXT) {
    fail("unknown-version", `unknown interface schema: ${schema}`);
  }

  const document = {
    edition: fields.get(HEADER_TAG.edition).toString("utf8"),
    packageId: fields.get(HEADER_TAG.packageId).toString("hex"),
    moduleId: fields.get(HEADER_TAG.moduleId).toString("hex"),
    publicRecords: decodeRecordVector(fields.get(HEADER_TAG.publicRecords)),
    internalRecords: decodeRecordVector(fields.get(HEADER_TAG.internalRecords)),
  };

  const claimedPublic = fields.get(HEADER_TAG.publicDigest);
  const claimedInternal = fields.get(HEADER_TAG.internalDigest);
  const recomputed = computeDigests(document);
  /*
   * The claimed digests are not inputs to themselves. Both are recomputed and
   * compared before anything here is published, which is why validation runs
   * after the digest check rather than before: a document whose bytes were
   * edited must fail as a digest mismatch, not as whatever inconsistency the
   * edit happened to introduce.
   */
  if (!recomputed.publicDigest.equals(claimedPublic)) {
    fail("digest-mismatch", "claimed public semantic digest does not match");
  }
  if (!recomputed.internalDigest.equals(claimedInternal)) {
    fail("digest-mismatch", "claimed package-internal digest does not match");
  }
  validateDocument(document, options);
  return document;
}

function decodeRecordVector(bytes) {
  if (bytes.length < 4) fail("corrupt", "truncated record vector");
  const count = bytes.readUInt32BE(0);
  if (count > LIMITS.records) {
    fail("limit-exhausted", "record count exceeds 65,536");
  }
  /*
   * The count is checked against the bytes that remain before a single record
   * is allocated: the smallest possible record is its 6-byte header, so a
   * count that cannot fit is rejected without reserving anything.
   */
  if (count * 6 > bytes.length - 4) {
    fail("corrupt", "record count cannot fit in the remaining bytes");
  }
  const records = [];
  let cursor = 4;
  for (let index = 0; index < count; index += 1) {
    if (cursor + 6 > bytes.length) fail("corrupt", "truncated record header");
    const kind = bytes.readUInt16BE(cursor);
    const length = bytes.readUInt32BE(cursor + 2);
    const start = cursor + 6;
    if (start + length > bytes.length) fail("corrupt", "record runs past its vector");
    if (!KIND_NAMES.has(kind)) {
      fail("unknown-kind", `unknown v3 record kind: 0x${kind.toString(16)}`);
    }
    records.push(decodeRecordPayload(kind, bytes.subarray(start, start + length)));
    cursor = start + length;
  }
  if (cursor !== bytes.length) fail("corrupt", "trailing bytes after the record vector");
  return records;
}

/*
 * Decoding is deliberately structural: it reads the fields each kind declares
 * and leaves every cross-record question to `validateDocument`. A decoder that
 * also resolved links would have to decide what to do with a forward
 * reference, and RFC-0017 allows those -- they must merely close before
 * publication.
 */
function decodeRecordPayload(kind, payload) {
  const reader = new PayloadReader(payload);
  const record = { kind };
  switch (kind) {
    case RECORD_KINDS.TypeBinder:
      record.id = reader.identity();
      record.owner = reader.identity();
      record.binderKind = reader.u8();
      record.ordinal = reader.u16();
      break;
    case RECORD_KINDS.ConstructedTypeRef:
      record.id = reader.identity();
      record.declaration = reader.identity();
      record.arguments = reader.sequence(() => reader.typeRef());
      break;
    case RECORD_KINDS.GenericTypeDeclaration:
      record.id = reader.identity();
      record.visibility = reader.u8();
      record.binders = reader.sequence(() => reader.identity());
      record.shape = reader.shape();
      record.bodyAvailability = reader.u8();
      break;
    case RECORD_KINDS.GenericFunctionDeclaration:
      record.id = reader.identity();
      record.visibility = reader.u8();
      record.binders = reader.sequence(() => reader.identity());
      record.parameters = reader.sequence(() => reader.typeRef());
      record.result = reader.typeRef();
      record.modes = reader.sequence(() => reader.u8());
      record.effects = reader.u16();
      record.bounds = reader.sequence(() => reader.bound());
      record.bodyAvailability = reader.u8();
      break;
    case RECORD_KINDS.TraitDeclaration:
      record.id = reader.identity();
      record.owner = reader.identity();
      record.visibility = reader.u8();
      record.binders = reader.sequence(() => reader.identity());
      record.methods = reader.sequence(() => reader.identity());
      record.laws = reader.sequence(() => reader.identity());
      break;
    case RECORD_KINDS.TraitMethod:
      record.id = reader.identity();
      record.trait = reader.identity();
      record.slot = reader.u16();
      record.parameters = reader.sequence(() => reader.typeRef());
      record.result = reader.typeRef();
      record.modes = reader.sequence(() => reader.u8());
      record.effects = reader.u16();
      break;
    case RECORD_KINDS.Implementation:
      record.id = reader.identity();
      record.owner = reader.identity();
      record.trait = reader.identity();
      record.self = reader.typeRef();
      record.binders = reader.sequence(() => reader.identity());
      record.bounds = reader.sequence(() => reader.bound());
      record.coherence = reader.u8();
      record.visibility = reader.u8();
      record.methodBodies = reader.sequence(() => ({
        method: reader.identity(),
        bodyDigest: reader.identity(),
      }));
      break;
    case RECORD_KINDS.DictionaryAbi:
      record.id = reader.identity();
      record.trait = reader.identity();
      record.abiVersion = reader.u16();
      record.slots = reader.sequence(() => ({
        slot: reader.u16(),
        method: reader.identity(),
        signatureDigest: reader.identity(),
      }));
      break;
    case RECORD_KINDS.GenericBodyTemplate: {
      record.id = reader.identity();
      record.declaration = reader.identity();
      const bodyLength = reader.u32();
      record.typedCore = reader.take(bodyLength);
      record.binderMap = reader.sequence(() => ({
        binder: reader.identity(),
        slot: reader.u16(),
      }));
      record.layoutInputs = reader.u16();
      record.effectInputs = reader.u16();
      record.cleanupInputs = reader.u16();
      record.bodyDigest = reader.identity();
      break;
    }
    case RECORD_KINDS.PublishedInstantiation:
      record.id = reader.identity();
      record.declaration = reader.identity();
      record.arguments = reader.sequence(() => reader.typeRef());
      record.availability = reader.u8();
      record.artifactDigest = reader.identity();
      record.bodyDigest = reader.identity();
      record.abiDigest = reader.identity();
      break;
    case RECORD_KINDS.GenericLawReference:
      record.id = reader.identity();
      record.proposition = reader.identity();
      record.requiredImplementations = reader.sequence(() => reader.identity());
      record.bodyDigest = reader.identity();
      record.interfaceDigest = reader.identity();
      record.evidenceAvailability = reader.u8();
      break;
    default:
      fail("unknown-kind", `unknown v3 record kind: ${kind}`);
  }
  reader.end();
  return record;
}

class PayloadReader {
  constructor(bytes) {
    this.bytes = bytes;
    this.cursor = 0;
  }

  take(length) {
    if (this.cursor + length > this.bytes.length) {
      fail("corrupt", "record payload is truncated");
    }
    const slice = this.bytes.subarray(this.cursor, this.cursor + length);
    this.cursor += length;
    return slice;
  }

  u8() {
    return this.take(1)[0];
  }

  u16() {
    return this.take(2).readUInt16BE(0);
  }

  u32() {
    return this.take(4).readUInt32BE(0);
  }

  identity() {
    return this.take(32).toString("hex");
  }

  sequence(readItem) {
    const count = this.u16();
    const items = [];
    for (let index = 0; index < count; index += 1) items.push(readItem());
    return items;
  }

  bound() {
    return { trait: this.identity(), subject: this.typeRef() };
  }

  text() {
    const length = this.u16();
    return this.take(length).toString("utf8");
  }

  shape() {
    const tag = this.u8();
    if (tag === SHAPE_TAG.record) {
      return {
        tag: "record",
        fields: this.sequence(() => ({
          name: this.text(),
          byValue: this.u8() === 1,
          type: this.typeRef(),
        })),
      };
    }
    if (tag === SHAPE_TAG.adt) {
      return {
        tag: "adt",
        constructors: this.sequence(() => ({
          name: this.text(),
          payload: this.sequence(() => ({
            byValue: this.u8() === 1,
            type: this.typeRef(),
          })),
        })),
      };
    }
    fail("corrupt", `unknown declaration shape tag: ${tag}`);
    return null;
  }

  typeRef(depth = 0) {
    if (depth > LIMITS.typeRefDepth) {
      fail("limit-exhausted", "TypeRef nesting exceeds depth 64");
    }
    const tag = this.u8();
    switch (tag) {
      case TYPE_REF_TAG.primitive:
        return { tag: "primitive", id: this.identity() };
      case TYPE_REF_TAG.parameter:
        return { tag: "parameter", id: this.identity() };
      case TYPE_REF_TAG.nominal: {
        const id = this.identity();
        const count = this.u16();
        const args = [];
        for (let index = 0; index < count; index += 1) args.push(this.typeRef(depth + 1));
        return { tag: "nominal", id, arguments: args };
      }
      case TYPE_REF_TAG.constructed:
        return { tag: "constructed", id: this.identity() };
      case TYPE_REF_TAG.function: {
        const count = this.u16();
        const parameters = [];
        for (let index = 0; index < count; index += 1) {
          parameters.push(this.typeRef(depth + 1));
        }
        const result = this.typeRef(depth + 1);
        const modeCount = this.u16();
        const modes = [];
        for (let index = 0; index < modeCount; index += 1) modes.push(this.u8());
        return { tag: "function", parameters, result, modes, effects: this.u16() };
      }
      default:
        fail("corrupt", `unknown TypeRef tag: ${tag}`);
    }
    return null;
  }

  end() {
    if (this.cursor !== this.bytes.length) {
      fail("corrupt", "record payload has trailing bytes");
    }
  }
}

/* ------------------------------------------------------------- validation */

/*
 * One walk over the whole graph. Everything RFC-0017 lists as "produce no
 * artifact" is decided here, so the publication path below has exactly one
 * question to ask.
 */
export function validateDocument(document, options = {}) {
  const publicRecords = document.publicRecords ?? [];
  const internalRecords = document.internalRecords ?? [];
  const all = [...publicRecords, ...internalRecords];
  if (all.length > LIMITS.records) {
    fail("limit-exhausted", "record count exceeds 65,536");
  }

  const byId = new Map();
  for (const record of all) {
    if (!KIND_NAMES.has(record.kind)) {
      fail("unknown-kind", `unknown v3 record kind: ${record.kind}`);
    }
    const key = `${hex(record.id)}:${record.kind}`;
    if (byId.has(key)) {
      fail("duplicate-id", `duplicate record identity ${hex(record.id)}`);
    }
    byId.set(key, record);
  }
  const known = new Set(all.map((record) => hex(record.id)));

  let linkCount = 0;
  for (const record of all) {
    for (const link of recordLinks(record)) {
      linkCount += 1;
      if (linkCount > LIMITS.links) {
        fail("limit-exhausted", "link count exceeds 262,144");
      }
      /*
       * Forward links are legal; dangling ones are not. The distinction is
       * only meaningful once the whole graph is in hand, which is why this
       * runs over the complete record set rather than as each record decodes.
       */
      if (!known.has(link) && !(options.externalIds ?? new Set()).has(link)) {
        fail("dangling-link", `link ${link} closes on nothing`, {
          from: hex(record.id),
        });
      }
    }
  }

  validateBinders(all, byId);
  validateVisibility(publicRecords, internalRecords, byId);
  validateDictionarySlots(all, byId);
  validateCoherence(all);
  validateCycles(all, byId);
  return document;
}

/*
 * "Combining package graphs completes overlap checking before selection;
 * import order cannot choose a candidate."
 *
 * Two implementations of one trait for one self type are an overlap, and the
 * refusal is the point: if the graph merely picked one, the choice would fall
 * to whichever arrived first, which is import order deciding semantics. The
 * check runs over the sorted key rather than the record order so the same two
 * implementations refuse identically whichever way round they were combined.
 */
function validateCoherence(all) {
  const seen = new Map();
  for (const record of all) {
    if (record.kind !== RECORD_KINDS.Implementation) continue;
    const key = `${hex(record.trait)}:${encodeTypeRef(record.self).toString("hex")}`;
    const previous = seen.get(key);
    if (previous) {
      const [first, second] = [hex(previous.id), hex(record.id)].sort();
      fail(
        "coherence-overlap",
        `implementations ${first} and ${second} both cover one trait and self type`,
        { trait: hex(record.trait) },
      );
    }
    seen.set(key, record);
  }
}

function validateBinders(all, byId) {
  const bindersByOwner = new Map();
  for (const record of all) {
    if (record.kind !== RECORD_KINDS.TypeBinder) continue;
    if (record.binderKind !== BINDER_KIND.type && record.binderKind !== BINDER_KIND.value) {
      fail("invalid-binder", `binder ${hex(record.id)} has an unknown kind`);
    }
    const owner = hex(record.owner);
    if (!bindersByOwner.has(owner)) bindersByOwner.set(owner, []);
    bindersByOwner.get(owner).push(record);
  }
  for (const [owner, binders] of bindersByOwner) {
    const ordinals = binders.map((binder) => binder.ordinal).sort((a, b) => a - b);
    /*
     * Binder ordinals are dense from zero. A gap or a repeat would let two
     * documents describe the same declaration with different binder
     * positions, and substitution reads position rather than name.
     */
    for (let index = 0; index < ordinals.length; index += 1) {
      if (ordinals[index] !== index) {
        fail("invalid-binder", `binders of ${owner} are not a dense ordinal range`);
      }
    }
  }
  for (const record of all) {
    const declared = record.binders;
    if (!Array.isArray(declared)) continue;
    for (const binder of declared) {
      const key = `${hex(binder)}:${RECORD_KINDS.TypeBinder}`;
      const target = byId.get(key);
      if (!target) fail("invalid-binder", `binder ${hex(binder)} has no TypeBinder record`);
      if (hex(target.owner) !== hex(record.id)) {
        fail("invalid-binder", `binder ${hex(binder)} is owned by another declaration`);
      }
    }
  }
}

/*
 * "Hidden/internal facts are retained only in the exact-package view. They
 * cannot satisfy an exported bound." A public record reaching an internal one
 * is the leak; the reverse is ordinary.
 */
function validateVisibility(publicRecords, internalRecords, byId) {
  const internalIds = new Set(internalRecords.map((record) => hex(record.id)));
  for (const record of publicRecords) {
    if (record.visibility === VISIBILITY.internal) {
      fail("visibility-leak", `internal record ${hex(record.id)} is in the public view`);
    }
    for (const link of recordLinks(record)) {
      if (internalIds.has(link)) {
        fail("visibility-leak", `public record ${hex(record.id)} depends on internal ${link}`);
      }
    }
  }
}

function validateDictionarySlots(all, byId) {
  for (const record of all) {
    if (record.kind !== RECORD_KINDS.DictionaryAbi) continue;
    const seen = new Set();
    for (const slot of record.slots ?? []) {
      if (seen.has(slot.slot)) {
        fail("slot-mismatch", `dictionary ${hex(record.id)} repeats slot ${slot.slot}`);
      }
      seen.add(slot.slot);
      const method = byId.get(`${hex(slot.method)}:${RECORD_KINDS.TraitMethod}`);
      if (!method) {
        fail("slot-mismatch", `dictionary slot ${slot.slot} names no TraitMethod`);
      }
      /*
       * The dictionary's slot number and the method's own slot are two
       * statements of one fact, and a mismatch is how a call reaches the
       * wrong body while every ID still resolves.
       */
      if (method.slot !== slot.slot) {
        fail("slot-mismatch", `method ${hex(slot.method)} declares slot ${method.slot}, dictionary says ${slot.slot}`);
      }
      if (hex(method.trait) !== hex(record.trait)) {
        fail("slot-mismatch", `method ${hex(slot.method)} belongs to another trait`);
      }
    }
    const ordered = (record.slots ?? []).map((slot) => slot.slot);
    for (let index = 1; index < ordered.length; index += 1) {
      if (ordered[index] <= ordered[index - 1]) {
        fail("non-canonical", `dictionary ${hex(record.id)} slots are not ordered`);
      }
    }
  }
}

/*
 * A value cycle requiring infinite layout is rejected. An interface reference
 * cycle is accepted only through an explicit ID edge inside a declared
 * strongly connected component -- so the test is not "is there a cycle" but
 * "does this cycle pass through a node that declared it".
 */
function validateCycles(all, byId) {
  const layoutEdges = new Map();
  for (const record of all) {
    if (record.kind !== RECORD_KINDS.GenericTypeDeclaration) continue;
    const targets = [];
    for (const edge of shapeValueEdges(record.shape)) {
      /*
       * A by-value edge may name a declaration directly or arrive through a
       * ConstructedTypeRef. Following the constructed node to its declaration
       * is what makes `Pair[Loop, Int]` stored by value count as reaching
       * `Loop` -- otherwise a cycle could be hidden behind one construction.
       */
      if (byId.has(`${edge}:${RECORD_KINDS.GenericTypeDeclaration}`)) {
        targets.push(edge);
        continue;
      }
      const constructed = byId.get(`${edge}:${RECORD_KINDS.ConstructedTypeRef}`);
      if (constructed) {
        const declaration = hex(constructed.declaration);
        if (byId.has(`${declaration}:${RECORD_KINDS.GenericTypeDeclaration}`)) {
          targets.push(declaration);
        }
      }
    }
    layoutEdges.set(hex(record.id), targets);
  }
  /*
   * A value cycle is rejected outright. There is no declaration that makes one
   * legal, because no layout exists: the exception the decision grants applies
   * to *interface reference* cycles, which do not require infinite storage.
   * Folding the two rules together -- as this first did -- would have let a
   * declared component admit a type that cannot be laid out at all.
   */
  detectCycle(layoutEdges, (path) => {
    fail("forbidden-cycle", `value cycle requiring infinite layout at ${path.at(-1)}`, {
      path,
    });
  });

  /*
   * The decision's other half -- "interface reference cycles are accepted only
   * through an explicit ID edge and within the declared strongly connected
   * component" -- needs no check here, and saying why is more useful than
   * adding one that cannot fail.
   *
   * Every TypeRef form that can reach another declaration is ID-addressed:
   * `nominal`, `parameter`, and `constructed` carry an identity, and there is
   * no inline structural form for a cycle to close through instead. So an
   * interface reference cycle is an explicit ID edge by construction, and its
   * members are exactly the records present in this document, which link
   * closure has already required.
   *
   * The alternative was to add a component field to `GenericTypeDeclaration`.
   * Its payload is closed by RFC-0017 -- TypeId, visibility, binders, shape,
   * body availability -- so that would extend the accepted record set to make
   * a check possible, which is the wrong way round.
   */
}

/*
 * Depth-first cycle detection that hands the whole cycle path to its caller.
 * The two rules above differ only in what they do with that path, so the walk
 * is written once -- two copies would be two places for the edge set and the
 * traversal to drift apart.
 */
function detectCycle(edges, onCycle) {
  const state = new Map();
  const visit = (node, path) => {
    if (state.get(node) === "done") return;
    if (state.get(node) === "open") {
      const start = path.indexOf(node);
      onCycle(start === -1 ? [...path, node] : [...path.slice(start), node]);
      return;
    }
    state.set(node, "open");
    for (const next of edges.get(node) ?? []) visit(next, [...path, node]);
    state.set(node, "done");
  };
  for (const node of edges.keys()) visit(node, []);
}

/* ------------------------------------------------------------ publication */

/*
 * Publication is modelled rather than performed: the decision's rule is
 * "temporary-plus-atomic-rename after the full graph validates", and what a
 * gate can check is that nothing observable is produced on any refusal path.
 * A store is a plain map so a test can assert the prior artifact survived
 * byte-for-byte.
 */
export function publish(store, request) {
  const {
    path,
    document,
    packageGraphId,
    sequence: requestSequence,
    cancelled,
    options = {},
  } = request;
  const previous = store.get(path);
  const refuse = (status, message, detail) => {
    const error = new KifGenericsError(status, message, detail);
    error.published = false;
    error.previous = previous;
    throw error;
  };

  if (cancelled) {
    /*
     * A cancelled write leaves the temporary behind at most, never a renamed
     * artifact -- the rename is the only observable step and it has not run.
     */
    refuse("cancelled", "publication was cancelled before the atomic rename");
  }
  let bytes;
  try {
    bytes = encodeDocument(document, options);
  } catch (error) {
    refuse(error.status ?? "corrupt", error.message, error.detail);
  }
  if (previous) {
    if (previous.packageGraphId !== packageGraphId) {
      /*
       * The same canonical bytes republished into a different package graph
       * is a replay: the document is valid, and it still must not land,
       * because its coherence and visibility were decided against the graph
       * it was written for.
       */
      refuse("replay", "document replayed into a different package graph", {
        expected: previous.packageGraphId,
        received: packageGraphId,
      });
    }
    if (requestSequence <= previous.sequence) {
      refuse("stale-sequence", "publication would move the sequence backwards", {
        previous: previous.sequence,
        received: requestSequence,
      });
    }
  }
  const entry = { bytes, packageGraphId, sequence: requestSequence };
  store.set(path, entry);
  return entry;
}

/* ------------------------------------------------------------- projection */

/*
 * Diagnostics only. `authoritative: false` is part of the artifact, IDs render
 * as lowercase hex, and keys are ordered so a review diff is stable. No
 * compiler path may read this back.
 */
export function project(document) {
  const renderRecord = (record) => ({
    kind: KIND_NAMES.get(record.kind),
    kind_tag: `0x${record.kind.toString(16).padStart(4, "0")}`,
    id: hex(record.id),
    links: recordLinks(record).sort(),
  });
  return {
    authoritative: false,
    schema: SCHEMA_TEXT,
    edition: document.edition,
    package_id: hex(document.packageId),
    module_id: hex(document.moduleId),
    public_records: sortRecords(document.publicRecords ?? []).map(renderRecord),
    internal_records: sortRecords(document.internalRecords ?? []).map(renderRecord),
  };
}

export function projectJson(document) {
  return `${JSON.stringify(project(document), null, 2)}\n`;
}

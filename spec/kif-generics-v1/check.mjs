/*
 * KIF generics v3 adversarial gate.
 *
 * Three properties, in the order they can fail:
 *
 *   1. the canonical fixture round-trips byte-for-byte and every link closes;
 *   2. no field is dead -- changing any one of them moves a semantic digest;
 *   3. every refusal RFC-0017 names produces no artifact.
 *
 * (2) is the one worth writing carefully. A codec that silently dropped a
 * field would pass a round-trip test, because what it wrote is what it reads
 * back. Only a mutation that must move the digest can tell an encoded field
 * from an ignored one, and each mutation asserts it actually changed the
 * document first -- a mutation that matched nothing proves nothing, however
 * confidently it is named.
 */

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  AVAILABILITY,
  BINDER_KIND,
  COHERENCE,
  DOMAINS,
  KifGenericsError,
  LIMITS,
  MAGIC,
  RECORD_KINDS,
  SCHEMA_TEXT,
  VISIBILITY,
  computeDigests,
  decodeDocument,
  encodeDocument,
  framedHash,
  project,
  publish,
  sortRecords,
} from "./model.mjs";

const root = path.resolve(import.meta.dirname, "../..");

import {
  BODY,
  CONSTRUCTED,
  DICTIONARY,
  DIGEST_A,
  DIGEST_B,
  DIGEST_C,
  DIGEST_D,
  FUNCTION,
  FUNCTION_BINDER,
  INSTANTIATION,
  INTERNAL_BINDER,
  INTERNAL_FUNCTION,
  LAW,
  MODULE,
  PACKAGE,
  PRIMITIVE_INT,
  TRAIT,
  TRAIT_BINDER,
  TRAIT_METHOD,
  TYPE,
  TYPE_BINDER_A,
  TYPE_BINDER_B,
  canonicalDocument,
  decodeOptions,
  id,
} from "./fixture.mjs";


function clone(value) {
  return structuredClone(value);
}

let checks = 0;
function pass(label) {
  checks += 1;
  process.stdout.write(`ok ${label}\n`);
}

/* ------------------------------------------- 1. canonical round trip */

const document = canonicalDocument();
const bytes = encodeDocument(document, decodeOptions);
assert.ok(bytes.subarray(0, 4).equals(MAGIC), "envelope magic");
assert.equal(bytes.readUInt16BE(4), 3, "major version 3");
const decoded = decodeDocument(bytes, decodeOptions);
assert.deepEqual(
  encodeDocument(decoded, decodeOptions).toString("hex"),
  bytes.toString("hex"),
  "decode/encode is not byte-stable",
);
pass("canonical fixture round-trips byte-for-byte");
/*
 * Byte-hash sentinel. Everything above compares this encoder against itself,
 * so it would hold just as well if the canonical order or a field width
 * changed -- both sides would move together. Freezing the bytes is what makes
 * the encoding itself reviewable: any edit to framing, field order, record
 * sort, or a digest domain moves these three constants and has to be an
 * argued change rather than a silent one.
 */
const SENTINEL = {
  envelopeSha256: "7895344693deff9fccc5aa7bd2f4798812268ece82280c647be954d086837d50",
  envelopeBytes: 2540,
  publicDigest: "3578d7ca0e0d1a44cd822300a7ef6857ba846a98650f41f7acf3ff3333d63038",
  internalDigest: "5288c6dbee5dc921b7e5ce193cef923ca8488000643f53708155375563b578f3",
};
assert.equal(createHash("sha256").update(bytes).digest("hex"), SENTINEL.envelopeSha256,
  "the canonical envelope bytes moved");
assert.equal(bytes.length, SENTINEL.envelopeBytes, "the canonical envelope length moved");
assert.equal(computeDigests(document).publicDigest.toString("hex"), SENTINEL.publicDigest,
  "the public semantic digest moved");
assert.equal(computeDigests(document).internalDigest.toString("hex"), SENTINEL.internalDigest,
  "the package-internal digest moved");
pass("the frozen envelope bytes and both semantic digests are unchanged");


/*
 * Records sort by ID with the kind as tie-break, so the order a producer
 * happens to walk its tables in is not observable. Reversing the input is the
 * cheapest way to state that: same document, same bytes.
 */
const shuffled = clone(document);
shuffled.publicRecords.reverse();
shuffled.internalRecords.reverse();
assert.equal(
  encodeDocument(shuffled, decodeOptions).toString("hex"),
  bytes.toString("hex"),
  "declaration order changed the semantic bytes",
);
pass("declaration order does not reach the bytes");

/* Every link closes against the document or a declared external identity. */
const closed = decodeDocument(bytes, decodeOptions);
assert.equal(closed.publicRecords.length, document.publicRecords.length);
assert.equal(closed.internalRecords.length, document.internalRecords.length);
pass("every linked identity closes");

/* --------------------------------------------- 2. no field is dead */

/*
 * Each entry names one field and edits it. The harness asserts the edit
 * actually changed the document before asserting the digest moved, because a
 * mutation that quietly matched nothing would report a passing gate for a
 * field nobody encodes.
 */
const fieldMutations = [
  ["TypeBinder.ordinal", (d) => { d.publicRecords[1].ordinal = 0; d.publicRecords[0].ordinal = 1; }],
  ["TypeBinder.binderKind", (d) => { d.publicRecords[0].binderKind = BINDER_KIND.value; }],
  ["TypeBinder.owner", (d) => { d.publicRecords[3].owner = FUNCTION; }],
  ["GenericTypeDeclaration.visibility", (d) => { record(d, TYPE).visibility = VISIBILITY.internal; }],
  ["GenericTypeDeclaration.shape tag", (d) => { record(d, TYPE).shape = { tag: "adt", constructors: [] }; }],
  ["GenericTypeDeclaration.field name", (d) => { record(d, TYPE).shape.fields[0].name = "first"; }],
  ["GenericTypeDeclaration.field type", (d) => { record(d, TYPE).shape.fields[0].type = { tag: "parameter", id: TYPE_BINDER_B }; }],
  ["GenericTypeDeclaration.field by-value", (d) => { record(d, TYPE).shape.fields[0].byValue = false; }],
  ["GenericTypeDeclaration.field order", (d) => { record(d, TYPE).shape.fields.reverse(); }],
  ["GenericTypeDeclaration.bodyAvailability", (d) => { record(d, TYPE).bodyAvailability = AVAILABILITY.packageOnly; }],
  ["GenericTypeDeclaration.binders order", (d) => { record(d, TYPE).binders.reverse(); }],
  ["ConstructedTypeRef.declaration", (d) => { record(d, CONSTRUCTED).declaration = FUNCTION; }],
  ["ConstructedTypeRef.arguments", (d) => { record(d, CONSTRUCTED).arguments.reverse(); }],
  ["GenericFunctionDeclaration.modes", (d) => { record(d, FUNCTION).modes = [2]; }],
  ["GenericFunctionDeclaration.effects", (d) => { record(d, FUNCTION).effects = 7; }],
  ["GenericFunctionDeclaration.bounds", (d) => { record(d, FUNCTION).bounds = []; }],
  ["GenericFunctionDeclaration.result", (d) => { record(d, FUNCTION).result = { tag: "primitive", id: PRIMITIVE_INT }; }],
  ["GenericFunctionDeclaration.bodyAvailability", (d) => { record(d, FUNCTION).bodyAvailability = AVAILABILITY.unavailable; }],
  ["TraitDeclaration.owner", (d) => { record(d, TRAIT).owner = MODULE; }],
  ["TraitDeclaration.laws", (d) => { record(d, TRAIT).laws = []; }],
  ["TraitMethod.slot", (d) => { record(d, TRAIT_METHOD).slot = 1; dictionarySlot(d, 1); }],
  ["TraitMethod.modes", (d) => { record(d, TRAIT_METHOD).modes = [2, 1]; }],
  ["Implementation.coherence", (d) => { record(d, IMPLEMENTATION).coherence = COHERENCE.packageLocal; }],
  ["Implementation.self", (d) => { record(d, IMPLEMENTATION).self = { tag: "constructed", id: CONSTRUCTED }; }],
  ["Implementation.methodBodies digest", (d) => { record(d, IMPLEMENTATION).methodBodies[0].bodyDigest = DIGEST_B; }],
  ["DictionaryAbi.abiVersion", (d) => { record(d, DICTIONARY).abiVersion = 2; }],
  ["DictionaryAbi.slot signature", (d) => { record(d, DICTIONARY).slots[0].signatureDigest = DIGEST_A; }],
  ["GenericBodyTemplate.typedCore", (d) => { record(d, BODY).typedCore = Buffer.from("core:sort2", "utf8"); }],
  ["GenericBodyTemplate.binderMap slot", (d) => { record(d, BODY).binderMap[0].slot = 3; }],
  ["GenericBodyTemplate.layoutInputs", (d) => { record(d, BODY).layoutInputs = 9; }],
  ["GenericBodyTemplate.effectInputs", (d) => { record(d, BODY).effectInputs = 9; }],
  ["GenericBodyTemplate.cleanupInputs", (d) => { record(d, BODY).cleanupInputs = 9; }],
  ["GenericBodyTemplate.bodyDigest", (d) => { record(d, BODY).bodyDigest = DIGEST_B; }],
  ["PublishedInstantiation.availability", (d) => { record(d, INSTANTIATION).availability = AVAILABILITY.packageOnly; }],
  ["PublishedInstantiation.artifactDigest", (d) => { record(d, INSTANTIATION).artifactDigest = DIGEST_A; }],
  ["PublishedInstantiation.abiDigest", (d) => { record(d, INSTANTIATION).abiDigest = DIGEST_A; }],
  ["GenericLawReference.interfaceDigest", (d) => { record(d, LAW).interfaceDigest = DIGEST_A; }],
  ["GenericLawReference.evidenceAvailability", (d) => { record(d, LAW).evidenceAvailability = AVAILABILITY.unavailable; }],
  ["header.edition", (d) => { d.edition = "kofun-2027"; }],
  ["header.packageId", (d) => { d.packageId = MODULE; }],
  ["header.moduleId", (d) => { d.moduleId = PACKAGE; }],
];

const IMPLEMENTATION = id("implementation:Comparable[Int]");

function record(target, wanted) {
  const found = [...target.publicRecords, ...target.internalRecords].find(
    (entry) => entry.id === wanted,
  );
  assert.ok(found, `fixture has no record ${wanted}`);
  return found;
}

function dictionarySlot(target, slot) {
  record(target, DICTIONARY).slots[0].slot = slot;
}

const baseline = computeDigests(document);
for (const [label, mutate] of fieldMutations) {
  const mutated = clone(document);
  mutate(mutated);
  assert.notEqual(
    JSON.stringify(mutated),
    JSON.stringify(document),
    `mutation "${label}" changed nothing; its field no longer exists`,
  );
  let moved;
  try {
    const digests = computeDigests(mutated);
    moved =
      !digests.publicDigest.equals(baseline.publicDigest) ||
      !digests.internalDigest.equals(baseline.internalDigest);
  } catch (error) {
    /* A mutation the encoder refuses outright is also a field that is read. */
    assert.ok(error instanceof KifGenericsError, `mutation "${label}" threw ${error}`);
    moved = true;
  }
  assert.ok(moved, `mutation "${label}" left both semantic digests unchanged`);
}
pass(`${fieldMutations.length} field mutations each move a semantic digest`);

/*
 * The internal digest covers the public vector too, so a public-only edit must
 * move both. This is the rule `module-identity.md` states as "cannot omit
 * public changes", and it is the one an implementation gets wrong by hashing
 * the internal vector alone.
 */
const publicOnly = clone(document);
record(publicOnly, DICTIONARY).abiVersion = 5;
const publicOnlyDigests = computeDigests(publicOnly);
assert.ok(
  !publicOnlyDigests.publicDigest.equals(baseline.publicDigest),
  "a public record changed and the public digest did not move",
);
assert.ok(
  !publicOnlyDigests.internalDigest.equals(baseline.internalDigest),
  "a public record changed and the internal digest did not move; the internal payload is hashing the internal vector alone",
);
pass("a public-only change moves the internal digest as well");

/* An internal-only edit moves the internal digest and leaves the public one. */
const internalOnly = clone(document);
record(internalOnly, INTERNAL_FUNCTION).bodyAvailability = AVAILABILITY.unavailable;
const internalOnlyDigests = computeDigests(internalOnly);
assert.ok(
  internalOnlyDigests.publicDigest.equals(baseline.publicDigest),
  "an internal-only change moved the public digest; internal facts are reaching the public payload",
);
assert.ok(
  !internalOnlyDigests.internalDigest.equals(baseline.internalDigest),
  "an internal-only change left the internal digest unchanged",
);
pass("an internal-only change leaves the public digest alone");

/* The two digest domains are distinct protocols over distinct payloads. */
assert.notEqual(DOMAINS.publicSemantic, DOMAINS.packageInternal);
assert.notEqual(
  framedHash(DOMAINS.publicSemantic, Buffer.from("x")).toString("hex"),
  framedHash(DOMAINS.packageInternal, Buffer.from("x")).toString("hex"),
);
pass("the two semantic digest domains are separate protocols");

/*
 * Excluded data cannot reach the bytes. Source paths, display names, and host
 * addresses are the three the decision names, and the encoder must ignore
 * them rather than merely omit them from its own fixtures -- a producer that
 * carries extra fields on its record structs is the ordinary case, not the
 * hostile one.
 */
const decorated = clone(document);
for (const entry of decorated.publicRecords) {
  entry.sourcePath = "/home/someone/kofun/src/sort.kofun";
  entry.displayName = "sort<T>";
  entry.hostAddress = 0x7ffd_0000;
  entry.declarationOrder = 41;
}
assert.equal(
  encodeDocument(decorated, decodeOptions).toString("hex"),
  bytes.toString("hex"),
  "an excluded field reached the semantic bytes",
);
pass("source paths, display names, and host addresses do not reach the bytes");

/*
 * The framed preimage itself. `module-identity.md` forbids concatenating an
 * unframed domain and payload, and the failure it prevents is a payload whose
 * leading bytes could be read as part of the domain -- so the test is that a
 * boundary shift between the two produces a different value.
 */
{
  const framed = framedHash("kofun.test.domain/v1", Buffer.from("payload"));
  const shifted = framedHash("kofun.test.domain/v", Buffer.from("1payload"));
  assert.notEqual(framed.toString("hex"), shifted.toString("hex"),
    "the domain/payload boundary is not framed; a shifted split collides");
  const unframed = createHash("sha256")
    .update("kofun.test.domain/v1")
    .update("payload")
    .digest("hex");
  assert.notEqual(framed.toString("hex"), unframed,
    "the framed preimage equals a bare concatenation");
  pass("the framed identity preimage is not a bare concatenation");
}

/* --------------------------------------------------- 3. refusals */

function refuses(status, label, act) {
  let raised;
  try {
    act();
  } catch (error) {
    raised = error;
  }
  assert.ok(raised, `${label} was accepted`);
  assert.ok(raised instanceof KifGenericsError, `${label} threw ${raised}`);
  assert.equal(raised.status, status, `${label} refused as ${raised.status}: ${raised.message}`);
  checks += 1;
}

refuses("unknown-kind", "an unknown record kind", () => {
  const bad = clone(document);
  bad.publicRecords[0].kind = 0x0200;
  encodeDocument(bad, decodeOptions);
});

refuses("duplicate-id", "a duplicate record identity", () => {
  const bad = clone(document);
  bad.publicRecords.push(clone(record(bad, DICTIONARY)));
  encodeDocument(bad, decodeOptions);
});

refuses("dangling-link", "a link that closes on nothing", () => {
  const bad = clone(document);
  record(bad, DICTIONARY).trait = id("trait:absent");
  encodeDocument(bad, decodeOptions);
});

refuses("invalid-binder", "a binder owned by another declaration", () => {
  const bad = clone(document);
  record(bad, TYPE).binders = [FUNCTION_BINDER, TYPE_BINDER_B];
  encodeDocument(bad, decodeOptions);
});

refuses("invalid-binder", "binder ordinals with a gap", () => {
  const bad = clone(document);
  record(bad, TYPE_BINDER_B).ordinal = 5;
  encodeDocument(bad, decodeOptions);
});

refuses("visibility-leak", "a public record depending on an internal one", () => {
  const bad = clone(document);
  record(bad, FUNCTION).bounds = [
    { trait: INTERNAL_FUNCTION, subject: { tag: "parameter", id: FUNCTION_BINDER } },
  ];
  encodeDocument(bad, decodeOptions);
});

refuses("visibility-leak", "an internal record placed in the public view", () => {
  const bad = clone(document);
  const moved = bad.internalRecords.pop();
  bad.publicRecords.push(moved);
  encodeDocument(bad, decodeOptions);
});

refuses("slot-mismatch", "a dictionary slot disagreeing with its method", () => {
  const bad = clone(document);
  record(bad, DICTIONARY).slots[0].slot = 4;
  encodeDocument(bad, decodeOptions);
});

refuses("slot-mismatch", "a dictionary slot naming no method", () => {
  const bad = clone(document);
  record(bad, DICTIONARY).slots[0].method = TRAIT;
  encodeDocument(bad, decodeOptions);
});

refuses("forbidden-cycle", "a value cycle requiring infinite layout", () => {
  const bad = clone(document);
  const loopA = id("type:LoopA");
  const loopB = id("type:LoopB");
  bad.publicRecords.push({
    kind: RECORD_KINDS.GenericTypeDeclaration,
    id: loopA,
    visibility: VISIBILITY.public,
    binders: [],
    shape: {
      tag: "record",
      fields: [{ name: "next", byValue: true, type: { tag: "nominal", id: loopB, arguments: [] } }],
    },
    bodyAvailability: AVAILABILITY.sourceFree,
  });
  bad.publicRecords.push({
    kind: RECORD_KINDS.GenericTypeDeclaration,
    id: loopB,
    visibility: VISIBILITY.public,
    binders: [],
    shape: {
      tag: "record",
      fields: [{ name: "back", byValue: true, type: { tag: "nominal", id: loopA, arguments: [] } }],
    },
    bodyAvailability: AVAILABILITY.sourceFree,
  });
  encodeDocument(bad, decodeOptions);
});

/*
 * The same two declarations with one field held behind an explicit
 * indirection are accepted. Without this case the rule above would pass just
 * as well if it refused every mutual reference, which is the shape a
 * linked list has.
 */
{
  const fine = clone(document);
  const loopA = id("type:IndirectA");
  const loopB = id("type:IndirectB");
  fine.publicRecords.push({
    kind: RECORD_KINDS.GenericTypeDeclaration,
    id: loopA,
    visibility: VISIBILITY.public,
    binders: [],
    shape: {
      tag: "record",
      fields: [{ name: "next", byValue: false, type: { tag: "nominal", id: loopB, arguments: [] } }],
    },
    bodyAvailability: AVAILABILITY.sourceFree,
  });
  fine.publicRecords.push({
    kind: RECORD_KINDS.GenericTypeDeclaration,
    id: loopB,
    visibility: VISIBILITY.public,
    binders: [],
    shape: {
      tag: "record",
      fields: [{ name: "back", byValue: true, type: { tag: "nominal", id: loopA, arguments: [] } }],
    },
    bodyAvailability: AVAILABILITY.sourceFree,
  });
  encodeDocument(fine, decodeOptions);
  pass("a mutual reference through an indirection is not a layout cycle");
}

refuses("limit-exhausted", "a TypeRef nested past depth 64", () => {
  const bad = clone(document);
  let deep = { tag: "primitive", id: PRIMITIVE_INT };
  for (let index = 0; index <= LIMITS.typeRefDepth + 1; index += 1) {
    deep = { tag: "nominal", id: TYPE, arguments: [deep] };
  }
  record(bad, FUNCTION).parameters = [deep];
  encodeDocument(bad, decodeOptions);
});

refuses("limit-exhausted", "bounded text past its byte limit", () => {
  const bad = clone(document);
  bad.edition = "e".repeat(LIMITS.boundedTextBytes + 1);
  encodeDocument(bad, decodeOptions);
});

refuses("non-canonical", "an edition that is not NFC", () => {
  const bad = clone(document);
  bad.edition = "café";
  encodeDocument(bad, decodeOptions);
});

refuses("corrupt", "a truncated envelope", () => {
  decodeDocument(bytes.subarray(0, bytes.length - 4), decodeOptions);
});

refuses("corrupt", "trailing bytes after the payload", () => {
  decodeDocument(Buffer.concat([bytes, Buffer.from([0])]), decodeOptions);
});

refuses("digest-mismatch", "an edited record with its claimed digest kept", () => {
  const tampered = Buffer.from(bytes);
  /* Flip one byte inside the record vector, leaving both claimed digests. */
  const target = tampered.length - 80;
  tampered[target] ^= 0xff;
  decodeDocument(tampered, decodeOptions);
});

refuses("downgrade", "a v2 envelope offered to the v3 reader", () => {
  const v2 = Buffer.from(bytes);
  v2.writeUInt16BE(2, 4);
  decodeDocument(v2, decodeOptions);
});

refuses("corrupt", "an envelope without the KIF magic", () => {
  const broken = Buffer.from(bytes);
  broken[0] = 0x4c;
  decodeDocument(broken, decodeOptions);
});

pass("every named refusal produces an error and no document");

refuses("corrupt", "a TypeRef with an unknown tag", () => {
  const bad = clone(document);
  record(bad, FUNCTION).result = { tag: "existential", id: PRIMITIVE_INT };
  encodeDocument(bad, decodeOptions);
});

refuses("corrupt", "a record whose identity is missing", () => {
  const bad = clone(document);
  delete record(bad, DICTIONARY).id;
  encodeDocument(bad, decodeOptions);
});

refuses("corrupt", "an identity that is not 32 bytes", () => {
  const bad = clone(document);
  record(bad, DICTIONARY).trait = "00ff";
  encodeDocument(bad, decodeOptions);
});

/*
 * Coherence overlap, asserted from both directions. The second half is the
 * one that matters: the same two implementations must refuse identically
 * whichever order they were combined in, because a graph that picked one
 * would be letting import order decide which body a call reaches.
 */
function overlappingDocument(reversed) {
  const bad = clone(document);
  const rival = clone(record(bad, IMPLEMENTATION));
  rival.id = id("implementation:Comparable[Int]:rival");
  rival.methodBodies = [{ method: TRAIT_METHOD, bodyDigest: DIGEST_B }];
  bad.publicRecords.push(rival);
  if (reversed) bad.publicRecords.reverse();
  return bad;
}

const overlapMessages = [];
for (const reversed of [false, true]) {
  let raised;
  try {
    encodeDocument(overlappingDocument(reversed), decodeOptions);
  } catch (error) {
    raised = error;
  }
  assert.ok(raised instanceof KifGenericsError, "an overlapping implementation was accepted");
  assert.equal(raised.status, "coherence-overlap", `overlap refused as ${raised.status}`);
  overlapMessages.push(raised.message);
  checks += 1;
}
assert.equal(
  overlapMessages[0],
  overlapMessages[1],
  "the overlap refusal depends on which implementation was combined first",
);
pass("two implementations of one trait and self type refuse identically in either order");

/* ------------------------------------------- publication transaction */

const store = new Map();
const published = publish(store, {
  path: "sort.kif3",
  document,
  packageGraphId: "graph-a",
  sequence: 1,
  options: decodeOptions,
});
assert.ok(published.bytes.equals(bytes));

refuses("replay", "a replay into a different package graph", () => {
  publish(store, { path: "sort.kif3", document, packageGraphId: "graph-b", sequence: 2, options: decodeOptions });
});
refuses("stale-sequence", "a publication moving the sequence backwards", () => {
  publish(store, { path: "sort.kif3", document, packageGraphId: "graph-a", sequence: 1, options: decodeOptions });
});
refuses("cancelled", "a cancelled publication", () => {
  publish(store, {
    path: "sort.kif3",
    document,
    packageGraphId: "graph-a",
    sequence: 3,
    cancelled: true,
    options: decodeOptions,
  });
});
refuses("dangling-link", "an invalid document offered for publication", () => {
  const bad = clone(document);
  record(bad, DICTIONARY).trait = id("trait:absent");
  publish(store, { path: "sort.kif3", document: bad, packageGraphId: "graph-a", sequence: 4, options: decodeOptions });
});
assert.ok(
  store.get("sort.kif3").bytes.equals(bytes),
  "a refused publication replaced the prior artifact",
);
assert.equal(store.get("sort.kif3").sequence, 1);
pass("every refused publication leaves the prior artifact byte-identical");

/* ------------------------------------------------------ projection */

const projection = project(document);
assert.equal(projection.authoritative, false);
assert.equal(projection.schema, SCHEMA_TEXT);
assert.equal(projection.public_records.length, document.publicRecords.length);
assert.ok(
  projection.public_records.every((entry) => /^[0-9a-f]{64}$/.test(entry.id)),
  "projected IDs are not lowercase hex",
);
const reordered = clone(document);
reordered.publicRecords.reverse();
assert.deepEqual(
  project(reordered),
  projection,
  "projection depends on declaration order",
);
pass("the projection is non-authoritative, hex, and order-stable");

/* ------------------------------- v1/v2 are untouched by this version */

/*
 * The decision says old artifacts are never reinterpreted as v3 and v1/v2 stay
 * byte-identical. The second half is checked against the *real* v1/v2 reader
 * rather than a restatement of it: `kif_v1_tool` is built from the production
 * codec, so if it accepted these bytes the claim would be false no matter what
 * this file asserted.
 */
const work = fs.mkdtempSync(path.join(os.tmpdir(), "kif-generics-"));
try {
  const tool = path.join(work, "kif-tool");
  execFileSync(
    process.env.CC ?? "cc",
    [
      "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-pedantic",
      "-DKOFUN_TEST_DIAGNOSTIC_FAULTS",
      `-I${path.join(root, "bootstrap/stage2")}`,
      path.join(root, "bootstrap/stage2/kif_v1_tool.c"),
      path.join(root, "bootstrap/stage2/kif_v1.c"),
      path.join(root, "unicode/kofun_unicode.c"),
      path.join(root, "bootstrap/stage2/sha256.c"),
      "-o", tool,
    ],
    { stdio: "pipe" },
  );
  const artifact = path.join(work, "generics.kif");
  fs.writeFileSync(artifact, bytes);
  let refused = false;
  let output = "";
  try {
    output = execFileSync(tool, ["read", artifact], { stdio: "pipe" }).toString();
  } catch (error) {
    refused = true;
    output = `${error.stdout ?? ""}${error.stderr ?? ""}`;
  }
  assert.ok(refused, "the production v1/v2 reader accepted a v3 envelope");
  assert.match(
    output,
    /unsupported-schema|rebuild/i,
    `the v1/v2 reader refused v3 as: ${output.trim()}`,
  );
  pass("the production v1/v2 reader refuses v3 as rebuild-required");
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}

process.stdout.write(
  `PASS: KIF generics v3 encodes eleven record kinds canonically, sorts by identity rather than declaration order, moves a semantic digest for every field, refuses unknown kinds/versions, duplicate and dangling identities, invalid binders, forbidden layout cycles, visibility leaks, slot mismatch, coherence overlap in either combination order, limit overflow, truncation, corruption, digest mismatch, downgrade, replay, and cancellation without replacing a prior artifact, and is refused as rebuild-required by the production v1/v2 reader (${checks} checks)\n`,
);

#!/usr/bin/env node

import assert from "node:assert/strict";
import crypto from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  HIR_SCHEMA,
  KSE_SCHEMA,
  KSE2_LIMITS,
  LIMITS,
  PROFILE,
  SIDECAR_SCHEMA,
  SIDECAR_V2_LIMITS,
  analyzeCaptureContract,
  buildScopeHir,
  canonicalJson,
  projectKse2CaptureSection,
  projectTypedSidecarV2,
  validateKse2CaptureSection,
  validateScopeHir,
  validateTypedSidecarV2,
} from "./model.mjs";
import { validateAgainstSchema } from "../../../tests/lib/json-schema.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../../..");
const FIXTURE = path.join(HERE, "fixtures", "canonical.json");
const HIR_SCHEMA_FILE = path.join(HERE, "kofun.scope-hir.v2.schema.json");
const KSE_SCHEMA_FILE = path.join(
  HERE,
  "kofun.stage2-semantic-events.v2-captures.schema.json",
);
const SIDECAR_SCHEMA_FILE = path.join(
  ROOT,
  "spec",
  "typed-sidecar",
  "kofun.typed-sidecar.v2.schema.json",
);
const SIDECAR_V1_SCHEMA_FILE = path.join(
  ROOT,
  "spec",
  "typed-sidecar",
  "kofun.typed-sidecar.v1.schema.json",
);
const SIDECAR_V1_EXAMPLE = path.join(
  ROOT,
  "spec",
  "typed-sidecar",
  "examples",
  "complete.json",
);

const readJson = (file) => JSON.parse(readFileSync(file, "utf8"));
const clone = (value) => structuredClone(value);
const fixture = readJson(FIXTURE);
let assertions = 0;
let mutations = 0;

function checked(operation, message) {
  operation();
  assertions += 1;
  if (message === undefined) throw new Error("checked assertion needs a message");
}

function equal(actual, expected, message) {
  assert.equal(actual, expected, message);
  assertions += 1;
}

function deepEqual(actual, expected, message) {
  assert.deepEqual(actual, expected, message);
  assertions += 1;
}

function refuses(label, operation) {
  assert.throws(operation, undefined, label);
  assertions += 1;
  mutations += 1;
}

function refusesMatching(label, expected, operation) {
  assert.throws(operation, expected, label);
  assertions += 1;
  mutations += 1;
}

function fakeId(label) {
  return crypto.createHash("sha256").update(`kofun-1219:${label}`).digest("hex");
}

function pointer(root, reference) {
  if (reference === "#") return root;
  assert.match(reference, /^#\//, `local schema ref ${reference}`);
  return reference.slice(2).split("/").reduce((value, component) =>
    value[component.replaceAll("~1", "/").replaceAll("~0", "~")], root);
}

function validateSchemaDocument(schema, label, v1Schema) {
  assert.equal(schema.$schema, "https://json-schema.org/draft/2020-12/schema", `${label}: dialect`);
  assert.equal(schema.additionalProperties, false, `${label}: closed root`);
  const expectedRoot = [...Object.keys(schema.properties)].sort();
  assert.deepEqual([...schema.required].sort(), expectedRoot, `${label}: every root field is required`);

  function visit(value, at) {
    if (Array.isArray(value)) {
      value.forEach((item, index) => visit(item, `${at}[${index}]`));
      return;
    }
    if (value === null || typeof value !== "object") return;
    if (typeof value.$ref === "string") {
      if (value.$ref.startsWith("#")) {
        assert.notEqual(pointer(schema, value.$ref), undefined, `${at}: local ref closes`);
      } else {
        const [file, fragment] = value.$ref.split("#");
        assert.equal(file, "kofun.typed-sidecar.v1.schema.json", `${at}: only frozen v1 may be referenced`);
        assert.notEqual(pointer(v1Schema, `#${fragment}`), undefined, `${at}: v1 ref closes`);
      }
    }
    if (value.type === "object") {
      assert.equal(value.additionalProperties, false, `${at}: object is closed`);
      const properties = Object.keys(value.properties ?? {}).sort();
      const required = [...(value.required ?? [])].sort();
      assert.deepEqual(required, properties, `${at}: every object field is required`);
    }
    for (const [key, nested] of Object.entries(value)) visit(nested, `${at}.${key}`);
  }
  visit(schema, label);
}

function rewriteRefs(value, rewrite) {
  if (Array.isArray(value)) return value.map((item) => rewriteRefs(item, rewrite));
  if (value === null || typeof value !== "object") return value;
  const result = {};
  for (const [key, nested] of Object.entries(value)) {
    result[key] = key === "$ref" ? rewrite(nested) : rewriteRefs(nested, rewrite);
  }
  return result;
}

function bundleSidecarSchema(schema, v1) {
  const bundled = clone(schema);
  const embeddedV1 = rewriteRefs(v1, (reference) =>
    reference.startsWith("#/") ? `#/$defs/v1/${reference.slice(2)}` : reference);
  delete embeddedV1.$id;
  bundled.$defs.v1 = embeddedV1;
  return rewriteRefs(bundled, (reference) => {
    const prefix = "kofun.typed-sidecar.v1.schema.json#/";
    return reference.startsWith(prefix)
      ? `#/$defs/v1/${reference.slice(prefix.length)}`
      : reference;
  });
}

function schemaErrors(schema, value) {
  const errors = [];
  validateAgainstSchema(schema, schema, value, "$", errors);
  return errors;
}

function schemaAccepts(label, schema, value) {
  deepEqual(schemaErrors(schema, value), [], label);
}

function schemaRefuses(label, schema, value) {
  assert.notEqual(schemaErrors(schema, value).length, 0, label);
  assertions += 1;
  mutations += 1;
}

const v1Schema = readJson(SIDECAR_V1_SCHEMA_FILE);
const hirSchema = readJson(HIR_SCHEMA_FILE);
const kseSchema = readJson(KSE_SCHEMA_FILE);
const sidecarSchema = readJson(SIDECAR_SCHEMA_FILE);
const bundledSidecarSchema = bundleSidecarSchema(sidecarSchema, v1Schema);

validateSchemaDocument(hirSchema, "scope-HIR schema", v1Schema);
validateSchemaDocument(kseSchema, "KSE2 capture schema", v1Schema);
validateSchemaDocument(sidecarSchema, "typed-sidecar v2 schema", v1Schema);
assert.equal(hirSchema.properties.schema.const, HIR_SCHEMA);
assert.equal(hirSchema.properties.profile.const, PROFILE);
assert.equal(kseSchema.properties.schema.const, KSE_SCHEMA);
assert.equal(kseSchema.properties.profile.const, PROFILE);
assert.equal(sidecarSchema.properties.schema.const, SIDECAR_SCHEMA);
assert.equal(sidecarSchema.properties.capture_profile.const, PROFILE);
assert.equal(hirSchema.$defs.place.properties.projections.maxItems, LIMITS.projection_depth);
assert.equal(hirSchema.$defs.capture.properties.origins.maxItems, LIMITS.origins_per_capture);
assert.equal(hirSchema.properties.records.maxItems, LIMITS.records);
assert.equal(hirSchema.properties.limits.properties.document_bytes.const, LIMITS.document_bytes);
assert.equal(sidecarSchema.properties.captures.maxItems, LIMITS.tasks * LIMITS.captures_per_task);
assert.equal(
  sidecarSchema.properties.limits.properties.document_bytes.const,
  SIDECAR_V2_LIMITS.document_bytes,
);
for (const [name, expected] of Object.entries(KSE2_LIMITS)) {
  assert.equal(kseSchema.properties.limits.properties[name].const, expected);
}
assertions += 15 + Object.keys(KSE2_LIMITS).length;

const first = analyzeCaptureContract(fixture);
const second = analyzeCaptureContract(fixture);
equal(canonicalJson(first), canonicalJson(second), "repeated model output is byte-identical");
checked(() => validateScopeHir(first.scope_hir), "scope-HIR validates");
schemaAccepts("scope-HIR instance satisfies its JSON Schema", hirSchema, first.scope_hir);
checked(
  () => validateKse2CaptureSection(first.kse2_capture_section, first.scope_hir),
  "KSE2 projection validates",
);
schemaAccepts(
  "KSE2 capture instance satisfies its JSON Schema",
  kseSchema,
  first.kse2_capture_section,
);

const records = first.scope_hir.records;
const byKind = (kind) => records.filter(({ record }) => record === kind);
deepEqual(byKind("par").map(({ id }) => id), [
  "19c6adddf7fcff978f5659cd9e68505f5f98a800dc20087b08e122783dea1da1",
], "ParId golden");
deepEqual(byKind("task").map(({ id }) => id), [
  "9501bf16630251818a14bcc74793bfd592470940f3f2ac5e296e9d8d76769730",
  "5855f4d04b4583b47dacea7b98abaa96d290613b3e68507459b65de9075fd87e",
], "TaskId goldens");
deepEqual(byKind("join").map(({ id }) => id), [
  "7f442458ee04975309710d797cd25da3edeffc1e381547c51dc8eb49f0806c75",
  "e0cde256678d6e8277ae0d073e70cee51bfefad0e816d6a605ad38a0a3a2b369",
], "JoinId goldens");
deepEqual(byKind("place").map(({ canonical_bytes }) => canonical_bytes), [
  "4b504c000210101010101010101010101010101010101010101010101010101010101010100102010000000000000000010000000000000008",
  "4b504c0002101010101010101010101010101010101010101010101010101010101010101002011111111111111111111111111111111111111111111111111111111111111111000000010201fffffffffffffffe021212121212121212121212121212121212121212121212121212121212121212",
], "known slice and field/slice place bytes are frozen");
deepEqual(byKind("place").map(({ id }) => id), [
  "ceb57ee7a4a8d9d476b287aeecbd34b22a93a6895c5a99ce8a6ba8f2eb967d46",
  "fe11686f6c48f5ecf91f475b05356bd871521db731ce469a5c45c64ba631e65c",
], "PlaceId goldens");
deepEqual(byKind("unknown").map(({ reason }) => reason), [
  "unresolved-call",
  "projection-depth-exceeded",
  "unnameable-place",
], "all unknown reasons are explicit and canonically ordered");
equal(
  byKind("place").every(({ projections }) => projections.length <= 8),
  true,
  "depth nine is never represented as a truncated known place",
);
const merged = byKind("capture").find(({ origins }) => origins.length === 2);
equal(merged.mode, "edit", "read plus edit merges to strongest mode edit");
equal(byKind("capture").length, 6, "seven observations become six exact captures");

const captureFrames = Buffer.from(first.kse2_capture_section.capture_frames_hex, "hex");
equal(
  crypto.createHash("sha256").update(captureFrames).digest("hex"),
  "40b8fc17ec59f9766a730f8a831c4454412c6229a7e5a25e19ab09b448951274",
  "KSE2 capture frame bytes are frozen",
);
equal(
  first.kse2_capture_section.events[0].wire_hex,
  "08000006000000d4010300000000002019c6adddf7fcff978f5659cd9e68505f5f98a800dc20087b08e122783dea1da102030000000000200303030303030303030303030303030303030303030303030303030303030303030300000000002004040404040404040404040404040404040404040404040404040404040404040403000000000020020202020202020202020202020202020202020202020202020202020202020205030000000000200505050505050505050505050505050505050505050505050505050505050505060500000000000400000000",
  "KSE2 par event field tags and widths are frozen",
);

const reordered = clone(fixture);
reordered.pars[0].tasks.reverse();
for (const task of reordered.pars[0].tasks) task.observations.reverse();
equal(
  canonicalJson(analyzeCaptureContract(reordered)),
  canonicalJson(first),
  "input container order cannot change canonical output",
);

const tiedOrigins = clone(fixture);
tiedOrigins.pars[0].tasks = tiedOrigins.pars[0].tasks.slice(0, 1);
const tiedRead = clone(tiedOrigins.pars[0].tasks[0].observations[0]);
const tiedEdit = clone(tiedRead);
tiedEdit.mode = "edit";
tiedOrigins.pars[0].tasks[0].observations = [tiedRead, tiedEdit];
const tiedForward = analyzeCaptureContract(tiedOrigins);
tiedOrigins.pars[0].tasks[0].observations.reverse();
equal(
  canonicalJson(analyzeCaptureContract(tiedOrigins)),
  canonicalJson(tiedForward),
  "an exact tied origin is deduplicated independently of input order",
);

const conflictingDisplay = clone(tiedOrigins);
conflictingDisplay.pars[0].tasks[0].observations[1].target.display.text = "conflict";
refusesMatching(
  "tied origin with conflicting display metadata",
  /conflicting display metadata/,
  () => buildScopeHir(conflictingDisplay),
);

const conflictingOriginSpan = clone(tiedOrigins);
conflictingOriginSpan.pars[0].tasks[0].observations[1].origin.span = { end: 4, start: 3 };
refusesMatching(
  "one origin NodeId with two spans",
  /must not carry two source spans/,
  () => buildScopeHir(conflictingOriginSpan),
);

const renamed = clone(fixture);
renamed.pars[0].display.text = "scope_renamed";
renamed.pars[0].tasks[0].display.text = "handle_renamed";
renamed.pars[0].tasks[0].observations[0].target.display.text = "base_renamed";
renamed.pars[0].tasks[0].observations[0].target.projections[0].display.text = "field_renamed";
const renamedResult = analyzeCaptureContract(renamed);
deepEqual(
  renamedResult.scope_hir.records.map(({ id }) => id),
  first.scope_hir.records.map(({ id }) => id),
  "display renaming cannot change an identity",
);
equal(
  canonicalJson(renamedResult.typed_sidecar_captures),
  canonicalJson(first.typed_sidecar_captures),
  "display renaming cannot change capture equality or projection",
);
equal(
  canonicalJson(renamedResult.kse2_capture_section),
  canonicalJson(first.kse2_capture_section),
  "display names never enter KSE2 bytes",
);

const typedV1 = readJson(SIDECAR_V1_EXAMPLE);
typedV1.file.file_id = first.scope_hir.file_id;
const typedV2 = projectTypedSidecarV2(typedV1, first.scope_hir);
checked(() => validateTypedSidecarV2(typedV2, first.scope_hir), "typed-sidecar v2 projection validates");
schemaAccepts(
  "typed-sidecar v2 instance satisfies its JSON Schema",
  bundledSidecarSchema,
  typedV2,
);
equal(typedV2.authoritative, false, "typed-sidecar v2 remains non-authoritative");
equal(canonicalJson(typedV2.captures).includes("items"), false, "display names are absent from captures");

const wrongFileBase = clone(typedV1);
wrongFileBase.file.file_id = fakeId("wrong-sidecar-file");
refusesMatching(
  "cross-file typed-sidecar projection",
  /must name the same file/,
  () => projectTypedSidecarV2(wrongFileBase, first.scope_hir),
);
const wrongFileDocument = clone(typedV2);
wrongFileDocument.file.file_id = wrongFileBase.file.file_id;
refusesMatching(
  "cross-file typed-sidecar validation",
  /must name the same file/,
  () => validateTypedSidecarV2(wrongFileDocument, first.scope_hir),
);
const zeroSidecarId = clone(typedV2);
zeroSidecarId.captures[0].id = "0".repeat(64);
schemaRefuses(
  "typed-sidecar schema rejects zero capture identities",
  bundledSidecarSchema,
  zeroSidecarId,
);
refuses("typed-sidecar semantic validator rejects zero capture identities", () =>
  validateTypedSidecarV2(zeroSidecarId, first.scope_hir));

// Every scope-HIR record field is load-bearing: removal and addition both fail.
for (let recordIndex = 0; recordIndex < records.length; recordIndex += 1) {
  for (const field of Object.keys(records[recordIndex])) {
    const mutated = clone(first.scope_hir);
    delete mutated.records[recordIndex][field];
    refuses(`record ${recordIndex} missing ${field}`, () => validateScopeHir(mutated));
  }
  const extra = clone(first.scope_hir);
  extra.records[recordIndex].extra = true;
  refuses(`record ${recordIndex} unknown field`, () => validateScopeHir(extra));
}
for (const field of Object.keys(first.scope_hir)) {
  const mutated = clone(first.scope_hir);
  delete mutated[field];
  refuses(`HIR root missing ${field}`, () => validateScopeHir(mutated));
}
for (const name of Object.keys(LIMITS)) {
  const mutated = clone(first.scope_hir);
  mutated.limits[name] += 1;
  refuses(`fixed limit ${name}`, () => validateScopeHir(mutated));
}
for (const name of Object.keys(KSE2_LIMITS)) {
  const mutated = clone(first.kse2_capture_section);
  mutated.limits[name] += 1;
  refuses(`fixed KSE2 limit ${name}`, () =>
    validateKse2CaptureSection(mutated, first.scope_hir));
}

for (let recordIndex = 0; recordIndex < records.length; recordIndex += 1) {
  const mutated = clone(first.scope_hir);
  mutated.records[recordIndex].id = fakeId(`wrong-record-id-${recordIndex}`);
  refuses(`record ${recordIndex} ID preimage`, () => validateScopeHir(mutated));
}

const badParent = clone(first.scope_hir);
badParent.records.find(({ record }) => record === "par").parent_scope_id = fakeId("missing-parent");
refuses("invalid par parent", () => validateScopeHir(badParent));
const badTaskLink = clone(first.scope_hir);
badTaskLink.records.find(({ record }) => record === "task").par_id = fakeId("missing-par");
refuses("invalid task link", () => validateScopeHir(badTaskLink));
const badJoinLink = clone(first.scope_hir);
badJoinLink.records.find(({ record }) => record === "join").task_id = fakeId("missing-task");
refuses("invalid join link", () => validateScopeHir(badJoinLink));
const badCaptureLink = clone(first.scope_hir);
badCaptureLink.records.find(({ record }) => record === "capture").target_id = fakeId("missing-target");
refuses("invalid capture target", () => validateScopeHir(badCaptureLink));
const duplicateOriginNode = clone(first.scope_hir);
const multiOriginCapture = duplicateOriginNode.records.find(
  ({ record, origins }) => record === "capture" && origins.length > 1,
);
multiOriginCapture.origins[1].node_id = multiOriginCapture.origins[0].node_id;
multiOriginCapture.origins[1].span = clone(multiOriginCapture.origins[0].span);
refusesMatching(
  "serialized capture duplicate origin NodeId",
  /origin NodeIds must be unique/,
  () => validateScopeHir(duplicateOriginNode),
);
const conflictingSerializedOrigin = clone(first.scope_hir);
const serializedCaptures = conflictingSerializedOrigin.records.filter(
  ({ record }) => record === "capture",
);
serializedCaptures[1].origins[0].node_id = serializedCaptures[0].origins[0].node_id;
refusesMatching(
  "serialized origin NodeId with two spans",
  /must not carry two source spans/,
  () => validateScopeHir(conflictingSerializedOrigin),
);
const unrelatedUnknownOrigin = clone(first.scope_hir);
const unrelatedUnknownCapture = unrelatedUnknownOrigin.records.find(
  ({ record, target_kind: targetKind }) => record === "capture" && targetKind === "unknown",
);
unrelatedUnknownCapture.origins[0].node_id = fakeId("unrelated-unknown-origin");
refusesMatching(
  "unknown capture origin differs from its witness",
  /exactly its witness NodeId/,
  () => validateScopeHir(unrelatedUnknownOrigin),
);
const duplicateUnknownOrigin = clone(first.scope_hir);
const duplicateUnknownCapture = duplicateUnknownOrigin.records.find(
  ({ record, target_kind: targetKind }) => record === "capture" && targetKind === "unknown",
);
duplicateUnknownCapture.origins.push({
  node_id: fakeId("second-unknown-origin"),
  span: { end: 202, start: 201 },
});
schemaRefuses(
  "scope-HIR schema fixes an unknown capture to one origin",
  hirSchema,
  duplicateUnknownOrigin,
);

const duplicateId = clone(first.scope_hir);
duplicateId.records[1].id = duplicateId.records[0].id;
refuses("duplicate record identity", () => validateScopeHir(duplicateId));
const noncanonicalTaskOrder = clone(first.scope_hir);
const firstTask = noncanonicalTaskOrder.records.findIndex(({ record }) => record === "task");
[noncanonicalTaskOrder.records[firstTask], noncanonicalTaskOrder.records[firstTask + 1]] =
  [noncanonicalTaskOrder.records[firstTask + 1], noncanonicalTaskOrder.records[firstTask]];
refuses("noncanonical task order", () => validateScopeHir(noncanonicalTaskOrder));
const noncanonicalCaptureOrder = clone(first.scope_hir);
const firstCapture = noncanonicalCaptureOrder.records.findIndex(({ record }) => record === "capture");
[noncanonicalCaptureOrder.records[firstCapture], noncanonicalCaptureOrder.records[firstCapture + 1]] =
  [noncanonicalCaptureOrder.records[firstCapture + 1], noncanonicalCaptureOrder.records[firstCapture]];
refuses("noncanonical capture order", () => validateScopeHir(noncanonicalCaptureOrder));

const depthNineHir = clone(first.scope_hir);
const mutatedPlace = depthNineHir.records.find(({ record }) => record === "place");
while (mutatedPlace.projections.length < 9) {
  mutatedPlace.projections.push({
    display: { disclosure: "hidden", text: null },
    kind: "field",
    ordinal: mutatedPlace.projections.length,
    owner_type_id: fakeId(`depth-${mutatedPlace.projections.length}`),
  });
}
refuses("depth-nine known place", () => validateScopeHir(depthNineHir));
const reversedSerializedSlice = clone(first.scope_hir);
const reversedSerializedProjection = reversedSerializedSlice.records
  .filter(({ record }) => record === "place")
  .flatMap(({ projections }) => projections)
  .find(({ kind, lower, upper }) =>
    kind === "slice" && lower.kind === "constant" && upper.kind === "constant");
reversedSerializedProjection.lower.value = "9";
reversedSerializedProjection.upper.value = "2";
refusesMatching(
  "serialized constant slice lower greater than upper",
  /lower greater than upper/,
  () => validateScopeHir(reversedSerializedSlice),
);
const badReason = clone(first.scope_hir);
badReason.records.find(({ record }) => record === "unknown").reason = "timeout";
refuses("open-ended unknown reason", () => validateScopeHir(badReason));
const inaccessibleName = clone(first.scope_hir);
const hidden = inaccessibleName.records
  .flatMap((record) => [record.display, ...(record.projections ?? []).map(({ display }) => display)])
  .find((display) => display?.disclosure === "hidden");
hidden.text = "private_name";
refuses("inaccessible display name", () => validateScopeHir(inaccessibleName));

const tooLongDisplay = clone(fixture);
tooLongDisplay.pars[0].display.text = "é".repeat(65);
refuses("display UTF-8 byte limit", () => buildScopeHir(tooLongDisplay));
const exactDisplay = clone(fixture);
exactDisplay.pars[0].display.text = "é".repeat(64);
checked(() => buildScopeHir(exactDisplay), "exact 128-byte display is accepted");

const i64Minimum = clone(fixture);
i64Minimum.pars[0].tasks[0].observations[0].target.projections[1].lower.value = "-9223372036854775808";
checked(() => buildScopeHir(i64Minimum), "i64 minimum is accepted");
const i64Maximum = clone(fixture);
i64Maximum.pars[0].tasks[0].observations[0].target.projections[1].lower.value = "9223372036854775807";
checked(() => buildScopeHir(i64Maximum), "i64 maximum is accepted");
for (const bad of ["-9223372036854775809", "9223372036854775808", "01", "+1"] ) {
  const mutated = clone(fixture);
  mutated.pars[0].tasks[0].observations[0].target.projections[1].lower.value = bad;
  refuses(`invalid i64 ${bad}`, () => buildScopeHir(mutated));
}
const emptyConstantSlice = clone(fixture);
const emptySliceProjection = emptyConstantSlice.pars[0].tasks
  .flatMap(({ observations }) => observations)
  .flatMap(({ target }) => target.kind === "place" ? target.projections : [])
  .find(({ kind, lower, upper }) =>
    kind === "slice" && lower.kind === "constant" && upper.kind === "constant");
emptySliceProjection.lower.value = "2";
emptySliceProjection.upper.value = "2";
checked(() => buildScopeHir(emptyConstantSlice), "equal constant bounds form a valid empty slice");
const reversedConstantSlice = clone(emptyConstantSlice);
const reversedSliceProjection = reversedConstantSlice.pars[0].tasks
  .flatMap(({ observations }) => observations)
  .flatMap(({ target }) => target.kind === "place" ? target.projections : [])
  .find(({ kind, lower, upper }) =>
    kind === "slice" && lower.kind === "constant" && upper.kind === "constant");
reversedSliceProjection.lower.value = "9";
reversedSliceProjection.upper.value = "2";
refusesMatching(
  "constant slice lower greater than upper",
  /lower greater than upper/,
  () => buildScopeHir(reversedConstantSlice),
);

const badOrdinal = clone(fixture);
badOrdinal.pars[0].tasks[0].observations[0].target.projections[0].ordinal = 0x100000000;
refuses("field ordinal above u32", () => buildScopeHir(badOrdinal));
const badSpan = clone(fixture);
badSpan.pars[0].tasks[0].observations[0].origin.span.end = 0x100000000;
refuses("span above u32", () => buildScopeHir(badSpan));
const emptySpan = clone(fixture);
emptySpan.pars[0].tasks[0].observations[0].origin.span.end = 100;
refuses("empty half-open span", () => buildScopeHir(emptySpan));

function minimalFixture() {
  const value = clone(fixture);
  value.pars[0].tasks = [];
  return value;
}

function taskInput(index, observations = []) {
  return {
    display: { disclosure: "hidden", text: null },
    handle_binding_id: fakeId(`handle-${index}`),
    join: { kind: "scope-exit", node_id: null },
    lambda_node_id: fakeId(`lambda-${index}`),
    lexical_index: index,
    observations,
    spawn_node_id: fakeId(`spawn-${index}`),
  };
}

const taskBoundary = minimalFixture();
taskBoundary.pars[0].tasks = Array.from({ length: 64 }, (_, index) => taskInput(index));
const taskBoundaryHir = buildScopeHir(taskBoundary);
checked(() => validateScopeHir(taskBoundaryHir), "64 tasks are accepted");
const taskOverflow = clone(taskBoundary);
taskOverflow.pars[0].tasks.push(taskInput(64));
refuses("65 tasks", () => buildScopeHir(taskOverflow));
const serializedTaskOverflow = clone(taskBoundaryHir);
const firstJoinRecord = serializedTaskOverflow.records.findIndex(({ record }) => record === "join");
serializedTaskOverflow.records.splice(firstJoinRecord, 0, {
  display: { disclosure: "hidden", text: null },
  handle_binding_id: fakeId("serialized-handle-64"),
  id: fakeId("serialized-task-64"),
  lambda_node_id: fakeId("serialized-lambda-64"),
  lexical_index: 64,
  par_id: serializedTaskOverflow.records[0].id,
  record: "task",
  spawn_node_id: fakeId("serialized-spawn-64"),
});
refusesMatching(
  "serialized 65-task HIR",
  /task limit exceeded/,
  () => validateScopeHir(serializedTaskOverflow),
);

const parBoundary = minimalFixture();
parBoundary.pars = Array.from({ length: 64 }, (_, index) => ({
  display: { disclosure: "hidden", text: null },
  lexical_index: index,
  node_id: fakeId(`par-node-${index}`),
  parent_scope_id: parBoundary.root_scope_id,
  scope_id: fakeId(`par-scope-${index}`),
  scope_token_binding_id: fakeId(`par-token-${index}`),
  tasks: [],
}));
const parBoundaryHir = buildScopeHir(parBoundary);
checked(() => validateScopeHir(parBoundaryHir), "64 par records are accepted");
const parOverflow = clone(parBoundary);
parOverflow.pars.push({
  display: { disclosure: "hidden", text: null },
  lexical_index: 64,
  node_id: fakeId("par-node-64"),
  parent_scope_id: parBoundary.root_scope_id,
  scope_id: fakeId("par-scope-64"),
  scope_token_binding_id: fakeId("par-token-64"),
  tasks: [],
});
refuses("65 par records", () => buildScopeHir(parOverflow));
const serializedParOverflow = clone(parBoundaryHir);
serializedParOverflow.records.push({
  display: { disclosure: "hidden", text: null },
  id: fakeId("serialized-par-64"),
  lexical_index: 64,
  node_id: fakeId("serialized-par-node-64"),
  parent_scope_id: serializedParOverflow.root_scope_id,
  record: "par",
  scope_id: fakeId("serialized-par-scope-64"),
  scope_token_binding_id: fakeId("serialized-par-token-64"),
});
refusesMatching(
  "serialized 65-par HIR",
  /par limit exceeded/,
  () => validateScopeHir(serializedParOverflow),
);

const duplicateScopeInput = clone(parBoundary);
duplicateScopeInput.pars = duplicateScopeInput.pars.slice(0, 2);
duplicateScopeInput.pars[1].scope_id = duplicateScopeInput.pars[0].scope_id;
refusesMatching(
  "duplicate input par ScopeId",
  /duplicate par scope identity/,
  () => buildScopeHir(duplicateScopeInput),
);
const duplicateScopeHir = clone(buildScopeHir({
  ...parBoundary,
  pars: parBoundary.pars.slice(0, 2),
}));
duplicateScopeHir.records[1].scope_id = duplicateScopeHir.records[0].scope_id;
duplicateScopeHir.records[1].id = fakeId("recomputed-duplicate-scope-par");
refusesMatching(
  "duplicate serialized par ScopeId",
  /duplicate par scope identity/,
  () => validateScopeHir(duplicateScopeHir),
);

const rootAliasInput = minimalFixture();
rootAliasInput.pars[0].scope_id = rootAliasInput.root_scope_id;
rootAliasInput.pars[0].parent_scope_id = rootAliasInput.root_scope_id;
refusesMatching(
  "input par scope aliases root",
  /must not alias the root scope/,
  () => buildScopeHir(rootAliasInput),
);
const rootAliasHir = clone(parBoundaryHir);
rootAliasHir.records[0].scope_id = rootAliasHir.root_scope_id;
rootAliasHir.records[0].id = fakeId("recomputed-root-alias-par");
refusesMatching(
  "serialized par scope aliases root",
  /must not alias the root scope/,
  () => validateScopeHir(rootAliasHir),
);

function unknownObservation(index) {
  return {
    mode: ["read", "edit", "take"][index % 3],
    origin: {
      node_id: fakeId(`origin-${index}`),
      span: { end: index * 2 + 2, start: index * 2 + 1 },
    },
    target: { kind: "unknown", reason: "unnameable-place" },
  };
}

const captureBoundary = minimalFixture();
captureBoundary.pars[0].tasks = [taskInput(
  0,
  Array.from({ length: 64 }, (_, index) => unknownObservation(index)),
)];
checked(() => buildScopeHir(captureBoundary), "64 captures per task are accepted");
const captureOverflow = clone(captureBoundary);
captureOverflow.pars[0].tasks[0].observations.push(unknownObservation(64));
refuses("65 captures per task", () => buildScopeHir(captureOverflow));

const originBoundary = minimalFixture();
const repeatedPlace = clone(fixture.pars[0].tasks[0].observations[0].target);
originBoundary.pars[0].tasks = [taskInput(0, Array.from({ length: 256 }, (_, index) => ({
  mode: "read",
  origin: {
    node_id: fakeId(`merged-origin-${index}`),
    span: { end: index * 2 + 2, start: index * 2 + 1 },
  },
  target: clone(repeatedPlace),
})))];
const originResult = buildScopeHir(originBoundary);
equal(
  originResult.records.find(({ record }) => record === "capture").origins.length,
  256,
  "256 origins per merged capture are accepted",
);
const observationOverflow = clone(originBoundary);
observationOverflow.pars[0].tasks[0].observations.push({
  mode: "read",
  origin: { node_id: fakeId("merged-origin-256"), span: { end: 514, start: 513 } },
  target: clone(repeatedPlace),
});
refuses("257 observations or origins", () => buildScopeHir(observationOverflow));

const depthBoundary = clone(fixture);
const depthTarget = depthBoundary.pars[0].tasks[0].observations[5].target;
while (depthTarget.projections.length < 64) depthTarget.projections.push(clone(depthTarget.projections[0]));
checked(() => buildScopeHir(depthBoundary), "candidate depth 64 becomes explicit unknown");
const depthOverflow = clone(depthBoundary);
depthOverflow.pars[0].tasks[0].observations[5].target.projections.push(clone(depthTarget.projections[0]));
refuses("candidate depth 65", () => buildScopeHir(depthOverflow));

const oversizedInput = minimalFixture();
oversizedInput.pars[0].tasks = Array.from({ length: 4 }, (_, taskIndex) => {
  const origin = {
    node_id: fakeId(`oversized-origin-${taskIndex}`),
    span: { end: taskIndex * 2 + 2, start: taskIndex * 2 + 1 },
  };
  const target = {
    base_binding_id: fakeId(`oversized-base-${taskIndex}`),
    display: { disclosure: "visible", text: "x".repeat(LIMITS.display_bytes) },
    kind: "place",
    projections: Array.from({ length: LIMITS.candidate_projection_depth }, (_, index) => ({
      display: { disclosure: "visible", text: "y".repeat(LIMITS.display_bytes) },
      kind: "field",
      ordinal: index,
      owner_type_id: fakeId(`oversized-owner-${taskIndex}-${index}`),
    })),
  };
  return taskInput(taskIndex, Array.from(
    { length: LIMITS.capture_observations_per_task },
    () => ({ mode: "read", origin: clone(origin), target: clone(target) }),
  ));
});
refusesMatching(
  "canonical model input above its byte budget",
  /model input byte limit exceeded/,
  () => buildScopeHir(oversizedInput),
);

const fullCardinality = minimalFixture();
fullCardinality.pars = Array.from({ length: 64 }, (_, parIndex) => ({
  display: { disclosure: "hidden", text: null },
  lexical_index: parIndex,
  node_id: fakeId(`full-par-node-${parIndex}`),
  parent_scope_id: fullCardinality.root_scope_id,
  scope_id: fakeId(`full-par-scope-${parIndex}`),
  scope_token_binding_id: fakeId(`full-par-token-${parIndex}`),
  tasks: parIndex === 0 ? Array.from({ length: 64 }, (_, taskIndex) => taskInput(
  taskIndex,
  Array.from({ length: 64 }, (_, captureIndex) => ({
    mode: "read",
    origin: {
      node_id: fakeId(`record-origin-${taskIndex}-${captureIndex}`),
      span: { end: captureIndex * 2 + 2, start: captureIndex * 2 + 1 },
    },
    target: { kind: "unknown", reason: "unresolved-call" },
  })),
  )) : [],
}));
const fullCardinalityHir = buildScopeHir(fullCardinality);
equal(
  Buffer.byteLength(canonicalJson(fullCardinality), "utf8") <= LIMITS.document_bytes,
  true,
  "the full task/capture input fits the model byte budget",
);
equal(
  fullCardinalityHir.records.length,
  LIMITS.records,
  "64 pars and 64-by-64 distinct captures exactly fill the derived record bound",
);
equal(
  fullCardinalityHir.records.filter(({ record }) => record === "capture").length,
  LIMITS.tasks * LIMITS.captures_per_task,
  "the full task/capture product is representable without truncation",
);
const fullCardinalityKse = projectKse2CaptureSection(fullCardinalityHir);
equal(
  fullCardinalityKse.events.length,
  KSE2_LIMITS.capture_events,
  "the full HIR cardinality exactly fills the KSE2 capture-section event bound",
);
checked(
  () => validateKse2CaptureSection(fullCardinalityKse, fullCardinalityHir),
  "the full KSE2 capture section validates",
);
const fullCardinalitySidecar = projectTypedSidecarV2(typedV1, fullCardinalityHir);
equal(
  fullCardinalitySidecar.captures.length,
  LIMITS.tasks * LIMITS.captures_per_task,
  "the full capture product fits typed-sidecar v2",
);
checked(
  () => validateTypedSidecarV2(fullCardinalitySidecar, fullCardinalityHir),
  "the full typed-sidecar v2 projection validates",
);
const recordOverflow = clone(fullCardinalityHir);
recordOverflow.records.push(null);
refusesMatching(
  "one record above the derived bound",
  /limit exceeded/,
  () => validateScopeHir(recordOverflow),
);

const badWire = clone(first.kse2_capture_section);
badWire.events[0].wire_hex = `ff${badWire.events[0].wire_hex.slice(2)}`;
refuses("KSE2 field-byte mutation", () => validateKse2CaptureSection(badWire, first.scope_hir));
const badFrames = clone(first.kse2_capture_section);
badFrames.capture_frames_hex = badFrames.capture_frames_hex.slice(2);
refuses("KSE2 section-byte mutation", () => validateKse2CaptureSection(badFrames, first.scope_hir));
const tooManyRelations = clone(first.kse2_capture_section);
const relationCapture = tooManyRelations.events.find(({ event }) => event === "capture");
relationCapture.origin_node_ids = Array.from(
  { length: KSE2_LIMITS.relations + 1 },
  (_, index) => fakeId(`relation-${index}`),
);
refusesMatching(
  "KSE2 relation one-over",
  /limit exceeded/,
  () => validateKse2CaptureSection(tooManyRelations, first.scope_hir),
);
schemaRefuses("KSE2 schema relation one-over", kseSchema, tooManyRelations);
const duplicateRelations = clone(first.kse2_capture_section);
const duplicateRelationCapture = duplicateRelations.events.find(({ event }) => event === "capture");
duplicateRelationCapture.origin_node_ids.push(duplicateRelationCapture.origin_node_ids[0]);
refusesMatching(
  "KSE2 duplicate origin NodeId",
  /origin NodeIds must be unique/,
  () => validateKse2CaptureSection(duplicateRelations, first.scope_hir),
);
schemaRefuses("KSE2 schema duplicate origin NodeId", kseSchema, duplicateRelations);
refusesMatching(
  "KSE2 semantic projection validation requires matching HIR",
  /matching scope-HIR is required/,
  () => validateKse2CaptureSection(first.kse2_capture_section),
);
const mismatchedKsePlace = clone(first.kse2_capture_section);
const mismatchedKseProjection = mismatchedKsePlace.events
  .find(({ event, projections }) => event === "place" &&
    projections.some(({ kind }) => kind === "field"))
  .projections.find(({ kind }) => kind === "field");
mismatchedKseProjection.ordinal += 1;
refusesMatching(
  "KSE2 decoded place projection differs from canonical bytes",
  /does not exactly project/,
  () => validateKse2CaptureSection(mismatchedKsePlace, first.scope_hir),
);
const multipleUnknownKseOrigins = clone(first.kse2_capture_section);
const unknownKseCapture = multipleUnknownKseOrigins.events.find(
  ({ event, target_kind: targetKind }) => event === "capture" && targetKind === "unknown",
);
unknownKseCapture.origin_node_ids.push(fakeId("second-kse-unknown-origin"));
schemaRefuses(
  "KSE2 schema fixes an unknown capture to one origin",
  kseSchema,
  multipleUnknownKseOrigins,
);
const reorderedEvents = clone(first.kse2_capture_section);
[reorderedEvents.events[0], reorderedEvents.events[1]] = [reorderedEvents.events[1], reorderedEvents.events[0]];
refuses("KSE2 phase mutation", () => validateKse2CaptureSection(reorderedEvents, first.scope_hir));

const leakedSidecar = clone(typedV2);
leakedSidecar.captures[0].display = "private_name";
refuses("typed-sidecar inaccessible name", () => validateTypedSidecarV2(leakedSidecar, first.scope_hir));
const reorderedSidecar = clone(typedV2);
reorderedSidecar.captures.reverse();
refuses("typed-sidecar capture order", () => validateTypedSidecarV2(reorderedSidecar, first.scope_hir));
const multipleUnknownSidecarOrigins = clone(typedV2);
const unknownSidecarCapture = multipleUnknownSidecarOrigins.captures.find(
  ({ target }) => target.kind === "unknown",
);
unknownSidecarCapture.origin_node_ids.push(fakeId("second-sidecar-unknown-origin"));
schemaRefuses(
  "typed-sidecar schema fixes an unknown capture to one origin",
  bundledSidecarSchema,
  multipleUnknownSidecarOrigins,
);

const schemaMissingHirField = clone(first.scope_hir);
delete schemaMissingHirField.profile;
schemaRefuses("scope-HIR schema instance mutation", hirSchema, schemaMissingHirField);
const schemaWrongKseKind = clone(first.kse2_capture_section);
schemaWrongKseKind.events[0].kind = 13;
schemaRefuses("KSE2 schema instance mutation", kseSchema, schemaWrongKseKind);
const schemaLeakedSidecar = clone(typedV2);
schemaLeakedSidecar.captures[0].display = "private_name";
schemaRefuses(
  "typed-sidecar schema instance mutation",
  bundledSidecarSchema,
  schemaLeakedSidecar,
);

const openSchema = clone(hirSchema);
delete openSchema.$defs.par.additionalProperties;
refuses("schema object closure", () => validateSchemaDocument(openSchema, "mutated HIR", v1Schema));
const driftedSchema = clone(kseSchema);
driftedSchema.properties.schema.const = "kofun-stage2-semantic-events/v3";
refuses("schema version mutation", () => {
  validateSchemaDocument(driftedSchema, "mutated KSE", v1Schema);
  assert.equal(driftedSchema.properties.schema.const, KSE_SCHEMA);
});
const widenedSidecar = clone(sidecarSchema);
widenedSidecar.properties.captures.maxItems += 1;
refuses("schema limit mutation", () => {
  validateSchemaDocument(widenedSidecar, "mutated sidecar", v1Schema);
  assert.equal(widenedSidecar.properties.captures.maxItems, LIMITS.tasks * LIMITS.captures_per_task);
});

process.stdout.write(
  `PASS: scoped-capture v2 contract (${assertions} assertions, ${mutations} refused mutations)\n`,
);

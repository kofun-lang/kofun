import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

import { encodeTypedSidecar } from "../../tooling/typed-sidecar/codec.mjs";
import {
  canonicalDocumentationIndexBytes,
  parseKifVisibilityProjection,
  projectDocumentationIndex,
  writeDocumentationIndexAtomic,
} from "../../tooling/typed-sidecar/documentation-index.mjs";

const [work] = process.argv.slice(2);
if (!work) throw new Error("usage: authority_boundary_test.mjs WORK");

const PACKAGE_ID = "d".repeat(64);
const MODULE_ID = "c".repeat(64);
const OLD_SYMBOL_ID = "1".repeat(64);
const LIVE_SYMBOL_ID = "2".repeat(64);
const SOURCE_DIGEST = "a".repeat(64);
const PRIVATE_PATH = "/private/workspace/removed-secret.kofun";
const PRIVATE_CONTENT = "removed_secret_value";

function functionFact(symbolId, visibility, name) {
  return {
    kind: "function",
    name,
    namespace_id: "3".repeat(64),
    parameter_count: 0,
    parameter_labels: [],
    parameter_types: [],
    result: "Int",
    symbol_id: symbolId,
    visibility,
  };
}

function visibilityProjection(facts, digestSeed) {
  const publicSeed = (Number.parseInt(digestSeed, 16) + 1).toString(16);
  const parsed = parseKifVisibilityProjection(Buffer.from(JSON.stringify({
    authoritative: false,
    edition: "kofun-2026",
    facts,
    module_id: MODULE_ID,
    module_trust: "ordinary",
    package_id: PACKAGE_ID,
    package_internal_semantic_digest: digestSeed.repeat(64),
    public_semantic_digest: publicSeed.repeat(64),
    schema: "kofun.interface-dump/v1",
  })));
  assert.equal(parsed.ok, true, parsed.error?.message);
  return parsed.projection;
}

const source = JSON.parse(fs.readFileSync(
  path.resolve("spec/typed-sidecar/examples/complete.json"),
));
source.file.logical_path = "src/removed-secret.kofun";
source.file.module_id = MODULE_ID;
source.file.package_id = PACKAGE_ID;
source.file.content_sha256 = SOURCE_DIGEST;
source.file.path_remap_root_id = "4".repeat(64);
source.nodes = [structuredClone(source.nodes[0])];
source.nodes[0].identities = [{ kind: "SymbolId", value: OLD_SYMBOL_ID }];
source.nodes[0].span = { start: 4, end: 19 };
source.nodes[0].type.display = `${PRIVATE_CONTENT} ${PRIVATE_PATH}`;
source.diagnostics = [];
source.references = [];

function encode(document) {
  const encoded = encodeTypedSidecar(document);
  assert.equal(encoded.ok, true, encoded.error?.message);
  return encoded.bytes;
}

function project(sidecar, projection, context = {}) {
  return projectDocumentationIndex(sidecar, projection, {
    currentGeneration: source.generation.sequence,
    currentSourceDigest: SOURCE_DIGEST,
    view: "public",
    ...context,
  });
}

function safeResult(result) {
  const text = JSON.stringify(result);
  for (const forbidden of [PRIVATE_PATH, PRIVATE_CONTENT, '"span"', '"logical_path"']) {
    assert.equal(text.includes(forbidden), false, forbidden);
  }
  return text;
}

const oldSidecar = encode(source);
const oldVisibility = visibilityProjection([
  functionFact(OLD_SYMBOL_ID, "pub", "formerly_visible"),
], "5");
const oldResult = project(oldSidecar, oldVisibility);
assert.equal(oldResult.ok, true, oldResult.error?.message);
assert.deepEqual(oldResult.index.entries.map((entry) => entry.declaration_id), [OLD_SYMBOL_ID]);
safeResult(oldResult);

// A replayed sidecar cannot restore a declaration whose live KIF visibility
// changed from public to package-internal.
const restrictedVisibility = visibilityProjection([
  functionFact(OLD_SYMBOL_ID, "internal", "formerly_visible"),
], "6");
const restrictedResult = project(oldSidecar, restrictedVisibility);
assert.equal(restrictedResult.ok, true, restrictedResult.error?.message);
assert.deepEqual(restrictedResult.index.entries, []);
safeResult(restrictedResult);

const removedVisibility = visibilityProjection([], "9");
const removedResult = project(oldSidecar, removedVisibility);
assert.equal(removedResult.ok, true, removedResult.error?.message);
assert.deepEqual(removedResult.index.entries, []);
safeResult(removedResult);

// Removal produces the same safe empty public projection. A replacement with
// a different SymbolId makes the required current projection incomplete, so
// the old sidecar cannot produce an index at all.
const replacedVisibility = visibilityProjection([
  functionFact(LIVE_SYMBOL_ID, "pub", "current_api"),
], "7");
const replacedResult = project(oldSidecar, replacedVisibility);
assert.equal(replacedResult.ok, false);
assert.equal(replacedResult.error.reason, "incomplete-join");
assert.equal("index" in replacedResult, false);
safeResult(replacedResult);

const forged = structuredClone(source);
forged.nodes[0].identities[0].value = "f".repeat(64);
const forgedResult = project(encode(forged), replacedVisibility);
assert.equal(forgedResult.ok, false);
assert.equal(forgedResult.error.reason, "incomplete-join");
assert.equal("index" in forgedResult, false);
safeResult(forgedResult);

const forgedCaller = projectDocumentationIndex(oldSidecar, restrictedVisibility, {
  currentGeneration: source.generation.sequence,
  currentSourceDigest: SOURCE_DIGEST,
  requestingPackageId: "f".repeat(64),
  view: "package-internal",
});
assert.equal(forgedCaller.ok, false);
assert.equal(forgedCaller.error.reason, "package-boundary");
assert.equal("index" in forgedCaller, false);
safeResult(forgedCaller);

const truncated = project(oldSidecar.subarray(0, oldSidecar.length - 1), oldVisibility);
assert.equal(truncated.ok, false);
assert.equal(truncated.error.reason, "invalid-sidecar");
assert.equal("index" in truncated, false);
safeResult(truncated);

const remapped = structuredClone(source);
remapped.file.path_remap_root_id = "8".repeat(64);
const remappedResult = project(encode(remapped), oldVisibility);
assert.equal(remappedResult.ok, true, remappedResult.error?.message);
assert.equal(
  canonicalDocumentationIndexBytes(remappedResult.index),
  canonicalDocumentationIndexBytes(oldResult.index),
);

const current = structuredClone(source);
current.nodes[0].identities[0].value = LIVE_SYMBOL_ID;
const currentResult = project(encode(current), replacedVisibility);
assert.equal(currentResult.ok, true, currentResult.error?.message);
safeResult(currentResult);

const destination = path.join(work, "authority-boundary.docs-index.json");
const written = await writeDocumentationIndexAtomic(destination, currentResult.index);
assert.equal(written.ok, true, written.error?.message);
const committed = fs.readFileSync(destination);
for (const refused of [replacedResult, forgedResult, forgedCaller, truncated]) {
  assert.equal("index" in refused, false);
  assert.deepEqual(fs.readFileSync(destination), committed);
}

console.log("PASS: live KIF visibility removes replayed sidecar access before publication");
console.log("PASS: forged caller/symbol identities and corrupt sidecars fail closed without disclosure");
console.log("PASS: path remap preserves the safe public result and prior committed bytes");

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

import { encodeTypedSidecar } from "../../tooling/typed-sidecar/codec.mjs";
import {
  canonicalDocumentationIndexBytes,
  parseKifVisibilityProjection,
  projectDocumentationIndex,
  readKifVisibilityProjection,
  writeDocumentationIndexAtomic,
} from "../../tooling/typed-sidecar/documentation-index.mjs";

const [work, reader, kif] = process.argv.slice(2);
if (!work || !reader || !kif) {
  throw new Error("usage: documentation_index_test.mjs WORK KIF_READER KIF");
}

const id = (value) => value.toString(16).padStart(64, "0");
const sourceDigest = "a".repeat(64);

const visibilityResult = readKifVisibilityProjection(kif, reader);
assert.equal(visibilityResult.ok, true, visibilityResult.error?.message);
const visibility = visibilityResult.projection;
assert.ok(visibility.facts.some((fact) => fact.visibility === "pub"));
assert.ok(visibility.facts.some((fact) => fact.visibility === "internal"));
assert.ok(visibility.facts.filter((fact) => fact.kind === "function")
  .every((fact) =>
    fact.signature.parameter_labels.length === fact.signature.parameters.length));

function completeDocument(sequence = 17) {
  const nodes = visibility.facts.map((fact, index) => ({
    depends_on: [],
    diagnostic_ids: [],
    id: id(index + 1),
    identities: [{ kind: fact.identity_kind, value: fact.symbol_id }],
    kind: {
      adt: "adt.declaration",
      constructor: "constructor.declaration",
      export: "export.binding",
      function: "function.declaration",
    }[fact.kind],
    span: { end: index * 10 + 9, start: index * 10 },
    status: "validated",
  }));
  const privateSpan = nodes.length * 10;
  nodes.push({
    depends_on: [],
    diagnostic_ids: [],
    id: id(nodes.length + 1),
    identities: [{ kind: "SymbolId", value: "e".repeat(64) }],
    kind: "function.declaration",
    span: { end: privateSpan + 9, start: privateSpan },
    status: "validated",
    type: {
      display: "PrivateSecret /home/hidden/private.kofun",
      status: "validated",
    },
  });
  return {
    authoritative: false,
    compiler: {
      edition: "kofun-2026",
      semantic_compatibility: "bootstrap-0.3",
    },
    completeness: "complete",
    diagnostics: [],
    file: {
      byte_length: privateSpan + 10,
      content_sha256: sourceDigest,
      file_id: "b".repeat(64),
      logical_path: "demo/api.kofun",
      module_id: visibility.module_id,
      package_id: visibility.package_id,
      path_remap_root_id: "c".repeat(64),
    },
    generation: { sequence },
    limits: {
      document_bytes: 16777216,
      max_depth: 128,
      profile: "default-v1",
    },
    nodes,
    references: [],
    schema: "kofun.typed-sidecar/v1",
    source_status: "checked",
  };
}

function partialDocument(sequence = 18) {
  const document = completeDocument(sequence);
  document.completeness = "partial";
  document.source_status = "failed";
  const publicFact = visibility.facts.find((fact) => fact.visibility === "pub");
  const node = document.nodes.find((candidate) =>
    candidate.identities.some((identity) => identity.value === publicFact.symbol_id));
  const diagnosticId = "d".repeat(64);
  node.status = "error";
  node.diagnostic_ids = [diagnosticId];
  document.diagnostics = [{
    affected_ids: [node.id],
    category: "documentation",
    code: "E2S16",
    fallback_text: "declaration is unavailable after a failed check",
    id: diagnosticId,
    primary: {
      file_id: document.file.file_id,
      span: node.span,
    },
    related: [],
    remedies: [],
    severity: "error",
    template_id: "unavailable-declaration",
    truncated: false,
  }];
  return document;
}

function encode(document) {
  const result = encodeTypedSidecar(document);
  assert.equal(result.ok, true, result.error?.message);
  return result.bytes;
}

function project(document, view, extra = {}) {
  return projectDocumentationIndex(encode(document), visibility, {
    currentGeneration: document.generation.sequence,
    currentSourceDigest: document.file.content_sha256,
    requestingPackageId: view === "package-internal" ? visibility.package_id : undefined,
    view,
    ...extra,
  });
}

const complete = completeDocument();
let result = projectDocumentationIndex(encode(complete), structuredClone(visibility), {
  currentGeneration: complete.generation.sequence,
  currentSourceDigest: sourceDigest,
  view: "public",
});
assert.equal(result.ok, false);
assert.equal(result.error.reason, "unvalidated-visibility-projection");
assert.equal("index" in result, false);

result = project(complete, "public");
assert.equal(result.ok, true, result.error?.message);
const publicIndex = result.index;
assert.equal(publicIndex.schema, "kofun.documentation-index/v1");
assert.equal(publicIndex.authoritative, false);
assert.equal(publicIndex.current, true);
assert.equal(publicIndex.status, "complete");
assert.equal(publicIndex.visibility_scope, "public");
assert.equal(publicIndex.visibility_digest, visibility.public_semantic_digest);
assert.equal(publicIndex.entries.length,
  visibility.facts.filter((fact) => fact.visibility === "pub").length);
assert.ok(publicIndex.entries.every((entry) => entry.visibility === "public"));
assert.ok(publicIndex.entries.every((entry) => entry.status === "validated"));
for (const entry of publicIndex.entries.filter((item) => item.kind === "function")) {
  const fact = visibility.facts.find((item) => item.symbol_id === entry.declaration_id);
  assert.deepEqual(entry.signature.parameter_labels, fact.signature.parameter_labels);
}

const publicBytes = canonicalDocumentationIndexBytes(publicIndex);
for (const forbidden of [
  "PrivateSecret", "/home/hidden", "logical_path", "path_remap_root_id",
  '"span"', "diagnostic_ids",
]) {
  assert.equal(publicBytes.includes(forbidden), false, forbidden);
}
for (const fact of visibility.facts.filter((item) => item.visibility === "internal")) {
  assert.equal(publicBytes.includes(fact.name), false, fact.name);
  assert.equal(publicBytes.includes(fact.symbol_id), false, fact.symbol_id);
}

result = project(complete, "package-internal");
assert.equal(result.ok, true, result.error?.message);
const internalIndex = result.index;
assert.equal(internalIndex.entries.length, visibility.facts.length);
assert.equal(internalIndex.visibility_digest,
  visibility.package_internal_semantic_digest);
assert.ok(internalIndex.entries.some((entry) =>
  entry.visibility === "package-internal"));

result = projectDocumentationIndex(encode(complete), visibility, {
  currentGeneration: complete.generation.sequence,
  currentSourceDigest: sourceDigest,
  requestingPackageId: "0".repeat(64),
  view: "package-internal",
});
assert.equal(result.ok, false);
assert.equal(result.error.code, "TDI02");
assert.equal(result.error.reason, "package-boundary");
assert.equal("index" in result, false);

const remapped = structuredClone(complete);
remapped.file.path_remap_root_id = "f".repeat(64);
result = project(remapped, "public");
assert.equal(result.ok, true, result.error?.message);
assert.equal(canonicalDocumentationIndexBytes(result.index), publicBytes);

const partial = partialDocument();
result = project(partial, "public");
assert.equal(result.ok, true, result.error?.message);
const partialIndex = result.index;
assert.equal(partialIndex.status, "partial");
assert.equal(partialIndex.current, true);
assert.equal(partialIndex.reason, "validated-prefix-only");
assert.ok(partialIndex.entries.length < publicIndex.entries.length);

result = projectDocumentationIndex(encode(complete), visibility, {
  currentGeneration: complete.generation.sequence,
  currentSourceDigest: "0".repeat(64),
  view: "public",
});
assert.equal(result.ok, true, result.error?.message);
const staleIndex = result.index;
assert.equal(staleIndex.status, "stale");
assert.equal(staleIndex.current, false);
assert.deepEqual(staleIndex.entries, []);

const cancelled = partialDocument(19);
cancelled.source_status = "cancelled";
result = project(cancelled, "public");
assert.equal(result.ok, true, result.error?.message);
assert.equal(result.index.status, "cancelled");
assert.equal(result.index.current, false);
assert.deepEqual(result.index.entries, []);

result = projectDocumentationIndex(Buffer.from("{"), visibility, {
  currentSourceDigest: sourceDigest,
  view: "public",
});
assert.equal(result.ok, false);
assert.equal(result.error.code, "TDI03");
assert.equal(result.error.reason, "invalid-sidecar");
assert.equal("index" in result, false);

result = projectDocumentationIndex(Buffer.alloc(16 * 1024 * 1024 + 1), visibility, {
  currentSourceDigest: sourceDigest,
  view: "public",
});
assert.equal(result.ok, false);
assert.equal("index" in result, false);

const wrongSchema = JSON.parse(spawnSync(reader, ["read", kif], {
  encoding: "utf8",
}).stdout);
wrongSchema.schema = "kofun.interface-dump/v2";
result = parseKifVisibilityProjection(Buffer.from(JSON.stringify(wrongSchema)));
assert.equal(result.ok, false);
assert.equal(result.error.reason, "invalid-visibility-projection");

// RFC-0012 tag 0x800A on the diagnostic surface. Both directions: a class
// outside the closed set is refused, and an absent one is refused rather than
// defaulting to `ordinary` — absence is the permissive reading, which is the
// downgrade the tag exists to close.
const unknownTrust = JSON.parse(spawnSync(reader, ["read", kif], {
  encoding: "utf8",
}).stdout);
assert.equal(unknownTrust.module_trust, "ordinary");
unknownTrust.module_trust = "raw - foreign";
result = parseKifVisibilityProjection(Buffer.from(JSON.stringify(unknownTrust)));
assert.equal(result.ok, false);
assert.equal(result.error.reason, "invalid-visibility-projection");

const absentTrust = JSON.parse(spawnSync(reader, ["read", kif], {
  encoding: "utf8",
}).stdout);
delete absentTrust.module_trust;
result = parseKifVisibilityProjection(Buffer.from(JSON.stringify(absentTrust)));
assert.equal(result.ok, false);
assert.equal(result.error.reason, "invalid-visibility-projection");

const validDump = spawnSync(reader, ["read", kif]).stdout;
const duplicateSchema = Buffer.from(validDump.toString("utf8").replace(
  "{\n", "{\n  \"schema\": \"kofun.interface-dump/v1\",\n",
));
result = parseKifVisibilityProjection(duplicateSchema);
assert.equal(result.ok, false);
assert.equal(result.error.reason, "invalid-visibility-projection");

const invalidUtf8 = Buffer.from(validDump);
const editionMarker = Buffer.from('"edition": "2026"');
const editionMarkerOffset = invalidUtf8.indexOf(editionMarker);
assert.notEqual(editionMarkerOffset, -1);
const editionOffset = editionMarkerOffset + Buffer.byteLength('"edition": "');
invalidUtf8[editionOffset] = 0xff;
result = parseKifVisibilityProjection(invalidUtf8);
assert.equal(result.ok, false);
assert.equal(result.error.reason, "invalid-visibility-projection");

const invalidKif = path.join(work, "invalid.kif");
fs.writeFileSync(invalidKif, "not a KIF\n");
result = readKifVisibilityProjection(invalidKif, reader);
assert.equal(result.ok, false);
assert.equal(result.error.reason, "invalid-kif");
assert.equal(result.error.message.includes("PrivateSecret"), false);

const destination = path.join(work, "public.docs-index.json");
result = await writeDocumentationIndexAtomic(destination, publicIndex);
assert.equal(result.ok, true, result.error?.message);
assert.equal(fs.statSync(destination).mode & 0o777, 0o600);
assert.equal(fs.readFileSync(destination, "utf8"), publicBytes);

const winnerBytes = fs.readFileSync(destination);
result = await writeDocumentationIndexAtomic(destination, partialIndex);
assert.equal(result.ok, false);
assert.equal(result.error.code, "TDI05");
assert.equal(result.error.reason, "trust-regression");
assert.deepEqual(fs.readFileSync(destination), winnerBytes);

const staleForWrite = structuredClone(staleIndex);
staleForWrite.generation.sequence = 19;
result = await writeDocumentationIndexAtomic(destination, staleForWrite);
assert.equal(result.ok, false);
assert.equal(result.error.reason, "non-current");
assert.deepEqual(fs.readFileSync(destination), winnerBytes);

const nextComplete = project(completeDocument(20), "public").index;
result = await writeDocumentationIndexAtomic(destination, nextComplete);
assert.equal(result.ok, true, result.error?.message);

const contender = project(completeDocument(21), "public").index;
const race = await Promise.all([
  writeDocumentationIndexAtomic(destination, contender),
  writeDocumentationIndexAtomic(destination, contender),
]);
assert.equal(race.filter((item) => item.ok).length, 1);
assert.equal(race.filter((item) =>
  !item.ok && item.error.reason === "stale-sequence").length, 1);

const invalidDestination = path.join(work, "invalid-old.docs-index.json");
fs.writeFileSync(invalidDestination, "PrivateSecret /home/hidden\n");
const invalidBefore = fs.readFileSync(invalidDestination);
result = await writeDocumentationIndexAtomic(
  invalidDestination,
  project(completeDocument(22), "public").index,
);
assert.equal(result.ok, false);
assert.equal(result.error.reason, "invalid-old");
assert.deepEqual(fs.readFileSync(invalidDestination), invalidBefore);

const victim = path.join(work, "victim.txt");
const symlink = path.join(work, "symlink.docs-index.json");
fs.writeFileSync(victim, "keep\n");
fs.symlinkSync(victim, symlink);
result = await writeDocumentationIndexAtomic(
  symlink,
  project(completeDocument(22), "public").index,
);
assert.equal(result.ok, false);
assert.equal(result.error.code, "TDI06");
assert.equal(fs.readFileSync(victim, "utf8"), "keep\n");

const directory = path.join(work, "directory.docs-index.json");
fs.mkdirSync(directory);
result = await writeDocumentationIndexAtomic(
  directory,
  project(completeDocument(22), "public").index,
);
assert.equal(result.ok, false);
assert.equal(result.error.code, "TDI06");

const sidecarPath = path.join(work, "complete.kofun-semantic.json");
const cliOutput = path.join(work, "cli.docs-index.json");
fs.writeFileSync(sidecarPath, encode(complete));
const cli = spawnSync(process.execPath, [
  path.resolve("tooling/typed-sidecar/documentation-index-cli.mjs"),
  "--sidecar", sidecarPath,
  "--kif", kif,
  "--kif-reader", reader,
  "--output", cliOutput,
  "--view", "public",
  "--current-source", sourceDigest,
  "--current-generation", String(complete.generation.sequence),
], { encoding: "utf8" });
assert.equal(cli.status, 0, cli.stderr);
assert.equal(fs.readFileSync(cliOutput, "utf8"), publicBytes);

const leftovers = fs.readdirSync(work).filter((name) =>
  name.includes(".tmp-") || name.endsWith(".documentation-index.lock"));
assert.deepEqual(leftovers, []);

console.log("PASS: KIF visibility and typed-sidecar facts join into canonical public/internal docs indexes");
console.log("PASS: private names, paths, spans, diagnostics, and cross-package internal facts stay absent");
console.log("PASS: partial/stale/cancelled trust and atomic newest-complete replacement are explicit");
console.log("PASS: malformed, oversized, raced, symlinked, and path-remapped inputs are bounded");

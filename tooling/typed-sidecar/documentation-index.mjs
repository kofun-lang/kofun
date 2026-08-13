import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

import {
  canonicalTypedSidecarBytes,
  parseJsonBytesStrict,
  readTypedSidecar,
} from "./codec.mjs";

export const DOCUMENTATION_INDEX_LIMITS = Object.freeze({
  documentBytes: 4 * 1024 * 1024,
  entries: 4096,
  inputBytes: 16 * 1024 * 1024,
  nameBytes: 256,
});

const HEX_ID = /^[0-9a-f]{64}$/;
const LOCK_POLL_MILLISECONDS = 10;
const LOCK_WAIT_MILLISECONDS = 2000;
const VISIBILITY_SCOPE = new Set(["public", "package-internal"]);
const KIND_TO_IDENTITY = Object.freeze({
  adt: "SymbolId",
  constructor: "SymbolId",
  export: "ExportBindingId",
  function: "SymbolId",
});
const KIND_TO_NODE = Object.freeze({
  adt: "adt.declaration",
  constructor: "constructor.declaration",
  export: "export.binding",
  function: "function.declaration",
});
const validatedVisibilityProjections = new WeakSet();

let temporaryCounter = 0;
const destinationQueues = new Map();

class DocumentationIndexFailure extends Error {
  constructor(code, message, reason) {
    super(message);
    this.name = "DocumentationIndexFailure";
    this.code = code;
    this.reason = reason;
  }
}

function fail(code, message, reason) {
  throw new DocumentationIndexFailure(code, message, reason);
}

function boundedMessage(message) {
  return message.length <= 256 ? message : message.slice(0, 253) + "...";
}

function errorResult(error, fallbackCode = "TDI03") {
  const known = error instanceof DocumentationIndexFailure;
  return Object.freeze({
    ok: false,
    error: Object.freeze({
      code: known ? error.code : fallbackCode,
      message: boundedMessage(known ? error.message : "documentation index operation failed"),
      reason: known ? error.reason : "operation-failed",
    }),
  });
}

function deepFreeze(root) {
  const pending = [root];
  const seen = new WeakSet();
  while (pending.length > 0) {
    const value = pending.pop();
    if (value === null || typeof value !== "object" || seen.has(value)) continue;
    seen.add(value);
    for (const child of Array.isArray(value) ? value : Object.values(value)) {
      pending.push(child);
    }
    Object.freeze(value);
  }
  return root;
}

function exactObject(value, where, required, optional = []) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    fail("TDI03", `${where} must be an object`, "invalid-visibility-projection");
  }
  const allowed = new Set([...required, ...optional]);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      fail("TDI03", `${where}.${key} is not supported`, "invalid-visibility-projection");
    }
  }
  for (const key of required) {
    if (!(key in value)) {
      fail("TDI03", `${where}.${key} is required`, "invalid-visibility-projection");
    }
  }
  return value;
}

function requireHex(value, where) {
  if (typeof value !== "string" || !HEX_ID.test(value)) {
    fail("TDI03", `${where} must be a lowercase SHA-256 identity`, "invalid-visibility-projection");
  }
  return value;
}

function requireName(value, where, limits) {
  if (typeof value !== "string" || value.length === 0 ||
      value.normalize("NFC") !== value || /[\u0000-\u001f\u007f]/u.test(value) ||
      Buffer.byteLength(value, "utf8") > limits.nameBytes) {
    fail("TDI03", `${where} is not a bounded NFC declaration name`, "invalid-visibility-projection");
  }
  return value;
}

function requireTypeReference(value, where) {
  if (value === "Int") return value;
  if (typeof value === "string" && value.startsWith("nominal:") &&
      HEX_ID.test(value.slice("nominal:".length))) return value;
  fail("TDI03", `${where} is not a supported KIF type reference`, "invalid-visibility-projection");
}

function requireParameterLabel(value, where, limits) {
  if (value === "unlabelled") return value;
  return requireName(value, where, limits);
}

function requireInteger(value, where, maximum = 0xffff_ffff) {
  if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
    fail("TDI03", `${where} is outside its bounded integer range`, "invalid-visibility-projection");
  }
  return value;
}

function configuredLimits(overrides = {}) {
  if (overrides === null || typeof overrides !== "object" || Array.isArray(overrides)) {
    fail("TDI01", "documentation index limits must be an object", "invalid-limits");
  }
  const result = {};
  for (const [name, maximum] of Object.entries(DOCUMENTATION_INDEX_LIMITS)) {
    const value = overrides[name] ?? maximum;
    if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
      fail("TDI01", `documentation index limit ${name} exceeds the reviewed maximum`, "invalid-limits");
    }
    result[name] = value;
  }
  return Object.freeze(result);
}

function functionSignature(fact, where, limits) {
  const parameters = fact.parameter_types;
  const parameterLabels = fact.parameter_labels;
  if (!Array.isArray(parameters) || parameters.length !== fact.parameter_count ||
      parameters.length > 256) {
    fail("TDI03", `${where}.parameter_types does not match parameter_count`, "invalid-visibility-projection");
  }
  if (!Array.isArray(parameterLabels) ||
      parameterLabels.length !== fact.parameter_count ||
      parameterLabels.length > 256) {
    fail("TDI03", `${where}.parameter_labels does not match parameter_count`, "invalid-visibility-projection");
  }
  return Object.freeze({
    parameter_labels: Object.freeze(parameterLabels.map((value, index) =>
      requireParameterLabel(value, `${where}.parameter_labels[${index}]`, limits))),
    parameters: Object.freeze(parameters.map((value, index) =>
      requireTypeReference(value, `${where}.parameter_types[${index}]`))),
    result: requireTypeReference(fact.result, `${where}.result`),
  });
}

function constructorSignature(fact, where) {
  if (fact.payload_count !== 0 && fact.payload_count !== 1) {
    fail("TDI03", `${where}.payload_count is not zero or one`, "invalid-visibility-projection");
  }
  if ((fact.payload_count === 1) !== ("payload_type" in fact)) {
    fail("TDI03", `${where}.payload_type does not match payload_count`, "invalid-visibility-projection");
  }
  return Object.freeze({
    ordinal: requireInteger(fact.ordinal, `${where}.ordinal`),
    owner_symbol_id: requireHex(fact.owner_symbol_id, `${where}.owner_symbol_id`),
    payload: fact.payload_count === 1 ?
      requireTypeReference(fact.payload_type, `${where}.payload_type`) : null,
  });
}

function exportSignature(fact, where) {
  const result = {
    target_kind: fact.target_kind,
    target_module_id: requireHex(fact.target_module_id, `${where}.target_module_id`),
    target_symbol_id: requireHex(fact.target_symbol_id, `${where}.target_symbol_id`),
  };
  if (!["adt", "constructor", "function", "module"].includes(result.target_kind)) {
    fail("TDI03", `${where}.target_kind is invalid`, "invalid-visibility-projection");
  }
  return Object.freeze(result);
}

function validateVisibilityFact(value, index, limits) {
  const where = `$.facts[${index}]`;
  const common = ["kind", "name", "namespace_id", "symbol_id", "visibility"];
  const kind = value?.kind;
  const optionalByKind = {
    adt: [],
    constructor: ["ordinal", "owner_symbol_id", "payload_count", "payload_type"],
    export: [
      "chain_count", "chain_first", "chain_ids", "payload_count",
      "source_import_binding_id", "target_constructor_ordinal", "target_kind",
      "target_module_id", "target_module_path", "target_owner_symbol_id",
      "target_symbol_id",
    ],
    function: ["parameter_count", "parameter_labels", "parameter_types", "result"],
  };
  if (!(kind in optionalByKind)) {
    fail("TDI03", `${where}.kind is not supported`, "invalid-visibility-projection");
  }
  const fact = exactObject(value, where, common, optionalByKind[kind]);
  requireName(fact.name, `${where}.name`, limits);
  requireHex(fact.namespace_id, `${where}.namespace_id`);
  requireHex(fact.symbol_id, `${where}.symbol_id`);
  if (fact.visibility !== "pub" && fact.visibility !== "internal") {
    fail("TDI03", `${where}.visibility is invalid`, "invalid-visibility-projection");
  }
  let signature = null;
  if (kind === "function") {
    requireInteger(fact.parameter_count, `${where}.parameter_count`, 256);
    signature = functionSignature(fact, where, limits);
  } else if (kind === "constructor") {
    requireInteger(fact.payload_count, `${where}.payload_count`, 1);
    signature = constructorSignature(fact, where);
  } else if (kind === "export") {
    signature = exportSignature(fact, where);
  }
  return Object.freeze({
    identity_kind: KIND_TO_IDENTITY[kind],
    kind,
    name: fact.name,
    namespace_id: fact.namespace_id,
    signature,
    symbol_id: fact.symbol_id,
    visibility: fact.visibility,
  });
}

export function parseKifVisibilityProjection(input, options = {}) {
  try {
    const limits = configuredLimits(options.limits);
    const bytes = Buffer.isBuffer(input) ? input : Buffer.from(input);
    if (bytes.length === 0 || bytes.length > limits.inputBytes) {
      fail("TDI04", "KIF visibility projection exceeds its byte limit", "input-byte-limit");
    }
    let document;
    try {
      document = parseJsonBytesStrict(bytes);
    } catch {
      fail("TDI03", "KIF visibility projection is not valid JSON", "invalid-visibility-projection");
    }
    const root = exactObject(document, "$", [
      "authoritative", "edition", "facts", "module_id", "module_trust",
      "package_id", "package_internal_semantic_digest",
      "public_semantic_digest", "schema",
    ]);
    if (root.schema !== "kofun.interface-dump/v1" || root.authoritative !== false) {
      fail("TDI03", "KIF visibility projection has the wrong schema or authority marker", "invalid-visibility-projection");
    }
    // RFC-0012 tag 0x800A, required rather than optional. A dump without it is
    // refused for the same reason the envelope refuses an absent 0x800A:
    // absence is the permissive reading, and treating it as `ordinary` here
    // would reintroduce through the diagnostic surface the downgrade the tag
    // exists to close. The closed set is checked, not just the key's presence.
    if (root.module_trust !== "ordinary" && root.module_trust !== "raw-foreign") {
      fail("TDI03", "KIF visibility projection has an unknown module trust class", "invalid-visibility-projection");
    }
    requireName(root.edition, "$.edition", limits);
    requireHex(root.module_id, "$.module_id");
    requireHex(root.package_id, "$.package_id");
    requireHex(root.public_semantic_digest, "$.public_semantic_digest");
    requireHex(root.package_internal_semantic_digest, "$.package_internal_semantic_digest");
    if (!Array.isArray(root.facts) || root.facts.length > limits.entries) {
      fail("TDI04", "KIF visibility fact limit exceeded", "entry-limit");
    }
    const facts = root.facts.map((fact, index) =>
      validateVisibilityFact(fact, index, limits));
    const identities = new Set();
    for (const fact of facts) {
      const key = `${fact.identity_kind}:${fact.symbol_id}`;
      if (identities.has(key)) {
        fail("TDI03", "KIF visibility projection repeats a declaration identity", "duplicate-visibility-fact");
      }
      identities.add(key);
    }
    const projection = deepFreeze({
      edition: root.edition,
      facts,
      module_id: root.module_id,
      package_id: root.package_id,
      package_internal_semantic_digest: root.package_internal_semantic_digest,
      public_semantic_digest: root.public_semantic_digest,
    });
    validatedVisibilityProjections.add(projection);
    return Object.freeze({
      ok: true,
      projection,
    });
  } catch (error) {
    return errorResult(error);
  }
}

export function readKifVisibilityProjection(kifPath, readerPath, options = {}) {
  try {
    if (typeof kifPath !== "string" || kifPath.length === 0 ||
        typeof readerPath !== "string" || readerPath.length === 0) {
      throw new TypeError("KIF path and reader path must be non-empty strings");
    }
    const limits = configuredLimits(options.limits);
    const result = spawnSync(readerPath, ["read", kifPath], {
      encoding: null,
      maxBuffer: limits.inputBytes,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (result.error || result.status !== 0 || !Buffer.isBuffer(result.stdout)) {
      fail("TDI03", "bounded KIF reader rejected the compiled interface", "invalid-kif");
    }
    return parseKifVisibilityProjection(result.stdout, { limits });
  } catch (error) {
    if (error instanceof TypeError) throw error;
    return errorResult(error);
  }
}

function identityKey(kind, value) {
  return `${kind}:${value}`;
}

function selectedFacts(projection, view, requestingPackageId) {
  if (!VISIBILITY_SCOPE.has(view)) {
    fail("TDI01", "documentation index view must be public or package-internal", "invalid-view");
  }
  if (view === "package-internal" && requestingPackageId !== projection.package_id) {
    fail("TDI02", "package-internal documentation requires the declaring PackageId", "package-boundary");
  }
  return projection.facts.filter((fact) =>
    fact.visibility === "pub" || view === "package-internal");
}

function safeEntry(fact) {
  const result = {
    declaration_id: fact.symbol_id,
    identity_kind: fact.identity_kind,
    kind: fact.kind,
    name: fact.name,
    namespace_id: fact.namespace_id,
    status: "validated",
    visibility: fact.visibility === "pub" ? "public" : "package-internal",
  };
  if (fact.signature !== null) result.signature = fact.signature;
  return result;
}

function emptyIndex(document, projection, context, limits, status, reason) {
  return {
    authoritative: false,
    current: false,
    entries: [],
    generation: { sequence: document.generation.sequence },
    limits: {
      document_bytes: limits.documentBytes,
      entries: limits.entries,
      profile: "documentation-index-v1",
    },
    module_id: projection.module_id,
    package_id: projection.package_id,
    reason,
    schema: "kofun.documentation-index/v1",
    source_sha256: document.file.content_sha256,
    source_status: document.source_status,
    status,
    visibility_digest: context.view === "public" ?
      projection.public_semantic_digest : projection.package_internal_semantic_digest,
    visibility_scope: context.view,
  };
}

function buildIndex(document, projection, context, limits) {
  if (typeof context.currentSourceDigest !== "string" ||
      !HEX_ID.test(context.currentSourceDigest)) {
    fail("TDI01", "currentSourceDigest must be a lowercase SHA-256 digest", "missing-current-source");
  }
  if (context.currentGeneration !== undefined &&
      (!Number.isSafeInteger(context.currentGeneration) || context.currentGeneration < 0)) {
    fail("TDI01", "currentGeneration must be a non-negative safe integer", "invalid-generation");
  }
  const facts = selectedFacts(projection, context.view, context.requestingPackageId);
  if (document.file.package_id !== projection.package_id ||
      document.file.module_id !== projection.module_id) {
    fail("TDI02", "typed sidecar and KIF projection identify different package/module inputs", "identity-mismatch");
  }
  if (document.file.content_sha256 !== context.currentSourceDigest ||
      (context.currentGeneration !== undefined &&
       document.generation.sequence !== context.currentGeneration)) {
    return emptyIndex(document, projection, context, limits, "stale", "source-or-generation-mismatch");
  }
  if (document.source_status === "cancelled") {
    return emptyIndex(document, projection, context, limits, "cancelled", "cancelled-input");
  }

  const nodesByIdentity = new Map();
  for (const node of document.nodes) {
    for (const identity of node.identities) {
      const key = identityKey(identity.kind, identity.value);
      if (!nodesByIdentity.has(key)) nodesByIdentity.set(key, []);
      nodesByIdentity.get(key).push(node);
    }
  }
  const entries = [];
  for (const fact of facts) {
    const matches = nodesByIdentity.get(identityKey(fact.identity_kind, fact.symbol_id)) ?? [];
    if (matches.length > 1) {
      fail("TDI03", "typed sidecar repeats a visible declaration identity", "ambiguous-sidecar-identity");
    }
    const node = matches[0];
    const valid = node !== undefined && node.status === "validated" &&
      node.kind === KIND_TO_NODE[fact.kind];
    if (!valid) {
      if (document.completeness === "complete") {
        fail("TDI02", "complete typed sidecar is missing an exact visible declaration", "incomplete-join");
      }
      continue;
    }
    entries.push(safeEntry(fact));
  }
  entries.sort((left, right) =>
    left.identity_kind.localeCompare(right.identity_kind) ||
    left.declaration_id.localeCompare(right.declaration_id) ||
    left.kind.localeCompare(right.kind));
  if (entries.length > limits.entries) {
    fail("TDI04", "documentation index entry limit exceeded", "entry-limit");
  }
  return {
    authoritative: false,
    current: true,
    entries,
    generation: { sequence: document.generation.sequence },
    limits: {
      document_bytes: limits.documentBytes,
      entries: limits.entries,
      profile: "documentation-index-v1",
    },
    module_id: projection.module_id,
    package_id: projection.package_id,
    reason: document.completeness === "complete" ?
      "complete-validated-join" : "validated-prefix-only",
    schema: "kofun.documentation-index/v1",
    source_sha256: document.file.content_sha256,
    source_status: document.source_status,
    status: document.completeness === "complete" ? "complete" : "partial",
    visibility_digest: context.view === "public" ?
      projection.public_semantic_digest : projection.package_internal_semantic_digest,
    visibility_scope: context.view,
  };
}

export function canonicalDocumentationIndexBytes(index) {
  return canonicalTypedSidecarBytes(index);
}

export function projectDocumentationIndex(sidecarInput, visibilityProjection, context = {}) {
  try {
    if (!validatedVisibilityProjections.has(visibilityProjection)) {
      fail("TDI03", "KIF visibility projection was not produced by the bounded reader", "unvalidated-visibility-projection");
    }
    const sidecar = readTypedSidecar(sidecarInput);
    if (!sidecar.ok) {
      fail("TDI03", "typed sidecar is invalid", "invalid-sidecar");
    }
    const limits = configuredLimits(context.limits);
    const index = buildIndex(sidecar.document, visibilityProjection, context, limits);
    const bytes = Buffer.byteLength(canonicalDocumentationIndexBytes(index), "utf8");
    if (bytes > limits.documentBytes) {
      fail("TDI04", "documentation index byte limit exceeded", "document-byte-limit");
    }
    return Object.freeze({ ok: true, index: deepFreeze(index) });
  } catch (error) {
    if (error instanceof TypeError) throw error;
    return errorResult(error);
  }
}

function validateIndexBytes(bytes, limits) {
  if (!Buffer.isBuffer(bytes) || bytes.length === 0 || bytes.length > limits.documentBytes) {
    fail("TDI04", "stored documentation index exceeds its byte limit", "document-byte-limit");
  }
  let value;
  try {
    value = JSON.parse(bytes.toString("utf8"));
  } catch {
    fail("TDI05", "stored documentation index is invalid", "invalid-old");
  }
  exactObject(value, "$index", [
    "authoritative", "current", "entries", "generation", "limits", "module_id",
    "package_id", "reason", "schema", "source_sha256", "source_status", "status",
    "visibility_digest", "visibility_scope",
  ]);
  if (value.schema !== "kofun.documentation-index/v1" || value.authoritative !== false ||
      typeof value.current !== "boolean" || !VISIBILITY_SCOPE.has(value.visibility_scope) ||
      !["cancelled", "complete", "partial", "stale"].includes(value.status) ||
      !Array.isArray(value.entries) || value.entries.length > limits.entries ||
      canonicalDocumentationIndexBytes(value) !== bytes.toString("utf8")) {
    fail("TDI05", "stored documentation index is invalid", "invalid-old");
  }
  requireHex(value.module_id, "$index.module_id");
  requireHex(value.package_id, "$index.package_id");
  requireHex(value.source_sha256, "$index.source_sha256");
  requireHex(value.visibility_digest, "$index.visibility_digest");
  requireInteger(value.generation?.sequence, "$index.generation.sequence", Number.MAX_SAFE_INTEGER);
  exactObject(value.generation, "$index.generation", ["sequence"]);
  exactObject(value.limits, "$index.limits", ["document_bytes", "entries", "profile"]);
  if (value.limits.document_bytes !== limits.documentBytes ||
      value.limits.entries !== limits.entries ||
      value.limits.profile !== "documentation-index-v1") {
    fail("TDI05", "stored documentation index has an unknown limit profile", "invalid-old");
  }
  if (typeof value.reason !== "string" || value.reason.length === 0 ||
      !["checked", "failed", "cancelled"].includes(value.source_status)) {
    fail("TDI05", "stored documentation index has invalid trust metadata", "invalid-old");
  }
  const expectedCurrent = value.status === "complete" || value.status === "partial";
  if (value.current !== expectedCurrent || (!value.current && value.entries.length !== 0)) {
    fail("TDI05", "stored documentation index has inconsistent current/status fields", "invalid-old");
  }
  const seen = new Set();
  let previous = "";
  for (let index = 0; index < value.entries.length; index += 1) {
    const where = `$index.entries[${index}]`;
    const entry = exactObject(value.entries[index], where, [
      "declaration_id", "identity_kind", "kind", "name", "namespace_id",
      "status", "visibility",
    ], ["signature"]);
    requireHex(entry.declaration_id, `${where}.declaration_id`);
    requireHex(entry.namespace_id, `${where}.namespace_id`);
    requireName(entry.name, `${where}.name`, limits);
    if (!(entry.kind in KIND_TO_IDENTITY) ||
        entry.identity_kind !== KIND_TO_IDENTITY[entry.kind] ||
        entry.status !== "validated" ||
        !["public", "package-internal"].includes(entry.visibility) ||
        (value.visibility_scope === "public" && entry.visibility !== "public")) {
      fail("TDI05", `${where} is not a safe visible declaration`, "invalid-old");
    }
    if ((entry.kind === "adt") !== !("signature" in entry)) {
      fail("TDI05", `${where}.signature does not match its declaration kind`, "invalid-old");
    }
    if (entry.kind === "function") {
      exactObject(entry.signature, `${where}.signature`, [
        "parameter_labels", "parameters", "result",
      ]);
      if (!Array.isArray(entry.signature.parameters) || entry.signature.parameters.length > 256) {
        fail("TDI05", `${where}.signature.parameters is invalid`, "invalid-old");
      }
      if (!Array.isArray(entry.signature.parameter_labels) ||
          entry.signature.parameter_labels.length !== entry.signature.parameters.length) {
        fail("TDI05", `${where}.signature.parameter_labels is invalid`, "invalid-old");
      }
      entry.signature.parameters.forEach((item, itemIndex) =>
        requireTypeReference(item, `${where}.signature.parameters[${itemIndex}]`));
      entry.signature.parameter_labels.forEach((item, itemIndex) =>
        requireParameterLabel(
          item,
          `${where}.signature.parameter_labels[${itemIndex}]`,
          limits,
        ));
      requireTypeReference(entry.signature.result, `${where}.signature.result`);
    } else if (entry.kind === "constructor") {
      exactObject(entry.signature, `${where}.signature`, ["ordinal", "owner_symbol_id", "payload"]);
      requireInteger(entry.signature.ordinal, `${where}.signature.ordinal`);
      requireHex(entry.signature.owner_symbol_id, `${where}.signature.owner_symbol_id`);
      if (entry.signature.payload !== null) {
        requireTypeReference(entry.signature.payload, `${where}.signature.payload`);
      }
    } else if (entry.kind === "export") {
      exactObject(entry.signature, `${where}.signature`, [
        "target_kind", "target_module_id", "target_symbol_id",
      ]);
      if (!["adt", "constructor", "function", "module"].includes(entry.signature.target_kind)) {
        fail("TDI05", `${where}.signature.target_kind is invalid`, "invalid-old");
      }
      requireHex(entry.signature.target_module_id, `${where}.signature.target_module_id`);
      requireHex(entry.signature.target_symbol_id, `${where}.signature.target_symbol_id`);
    }
    const key = identityKey(entry.identity_kind, entry.declaration_id);
    if (seen.has(key) || (previous !== "" && previous >= key)) {
      fail("TDI05", "stored documentation index entries are not unique and sorted", "invalid-old");
    }
    seen.add(key);
    previous = key;
  }
  return value;
}

function replacementDecision(oldIndex, newIndex) {
  if (oldIndex.package_id !== newIndex.package_id ||
      oldIndex.module_id !== newIndex.module_id ||
      oldIndex.visibility_scope !== newIndex.visibility_scope) {
    return Object.freeze({ allow: false, reason: "wrong-index" });
  }
  if (newIndex.generation.sequence <= oldIndex.generation.sequence) {
    return Object.freeze({ allow: false, reason: "stale-sequence" });
  }
  if (!newIndex.current) return Object.freeze({ allow: false, reason: "non-current" });
  if (oldIndex.current && oldIndex.status === "complete" && newIndex.status !== "complete") {
    return Object.freeze({ allow: false, reason: "trust-regression" });
  }
  return Object.freeze({ allow: true, reason: "allow" });
}

function ioFailure(message, reason = "io-failure") {
  return new DocumentationIndexFailure("TDI06", message, reason);
}

function assertNotCancelled(signal) {
  if (signal?.aborted) fail("TDI06", "documentation index write was cancelled", "cancelled");
}

async function openExclusive(filename) {
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL |
    (fs.constants.O_NOFOLLOW ?? 0);
  return fs.promises.open(filename, flags, 0o600);
}

async function acquireLock(filename, signal) {
  const attempts = Math.ceil(LOCK_WAIT_MILLISECONDS / LOCK_POLL_MILLISECONDS);
  for (let attempt = 0; ; attempt += 1) {
    assertNotCancelled(signal);
    try {
      return await openExclusive(filename);
    } catch (error) {
      if (error.code !== "EEXIST") throw ioFailure("cannot acquire documentation index lock");
      if (attempt >= attempts) throw ioFailure("documentation index destination is busy", "busy");
      await new Promise((resolve) => setTimeout(resolve, LOCK_POLL_MILLISECONDS));
    }
  }
}

async function readDestination(filename, limits) {
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0);
  let handle;
  try {
    handle = await fs.promises.open(filename, flags);
  } catch (error) {
    if (error.code === "ENOENT") return Object.freeze({ exists: false });
    throw ioFailure("cannot open documentation index destination safely");
  }
  try {
    const stat = await handle.stat();
    if (!stat.isFile()) throw ioFailure("documentation index destination must be a regular file");
    const bytes = await handle.readFile();
    return { exists: true, index: validateIndexBytes(bytes, limits) };
  } finally {
    await handle.close().catch(() => {});
  }
}

async function safeUnlinkOwned(filename, ownedStat) {
  if (!filename || !ownedStat) return;
  try {
    const current = await fs.promises.lstat(filename);
    if (current.dev === ownedStat.dev && current.ino === ownedStat.ino) {
      await fs.promises.unlink(filename);
    }
  } catch {
    // Cleanup is best effort and never widens the owned inode set.
  }
}

function serializeDestination(destination, action) {
  const previous = destinationQueues.get(destination) ?? Promise.resolve();
  const next = previous.catch(() => {}).then(action);
  destinationQueues.set(destination, next);
  return next.finally(() => {
    if (destinationQueues.get(destination) === next) destinationQueues.delete(destination);
  });
}

async function atomicWrite(destination, index, bytes, context, limits) {
  const directory = path.dirname(destination);
  const basename = path.basename(destination);
  const lockPath = path.join(directory, `.${basename}.documentation-index.lock`);
  let lockHandle;
  let lockStat;
  let temporaryHandle;
  let temporaryPath;
  let temporaryStat;
  let renamed = false;
  try {
    assertNotCancelled(context.signal);
    lockHandle = await acquireLock(lockPath, context.signal);
    lockStat = await lockHandle.stat();
    const before = await readDestination(destination, limits);
    if (before.exists) {
      const decision = replacementDecision(before.index, index);
      if (!decision.allow) fail("TDI05", "documentation index replacement denied", decision.reason);
    } else if (!index.current) {
      fail("TDI05", "documentation index replacement denied", "non-current");
    }

    temporaryCounter += 1;
    temporaryPath = path.join(directory, `.${basename}.tmp-${process.pid}-${temporaryCounter}`);
    temporaryHandle = await openExclusive(temporaryPath);
    temporaryStat = await temporaryHandle.stat();
    await temporaryHandle.writeFile(bytes);
    await temporaryHandle.sync();
    await temporaryHandle.close();
    temporaryHandle = undefined;

    assertNotCancelled(context.signal);
    const current = await readDestination(destination, limits);
    if (current.exists) {
      const decision = replacementDecision(current.index, index);
      if (!decision.allow) fail("TDI05", "documentation index replacement denied", decision.reason);
    } else if (!index.current) {
      fail("TDI05", "documentation index replacement denied", "non-current");
    }
    const currentTemporary = await fs.promises.lstat(temporaryPath);
    if (!currentTemporary.isFile() || currentTemporary.dev !== temporaryStat.dev ||
        currentTemporary.ino !== temporaryStat.ino) {
      throw ioFailure("documentation index temporary file identity changed");
    }
    await fs.promises.rename(temporaryPath, destination);
    renamed = true;
    return Object.freeze({
      ok: true,
      bytes: bytes.length,
      sequence: index.generation.sequence,
      status: index.status,
    });
  } finally {
    if (temporaryHandle) await temporaryHandle.close().catch(() => {});
    if (!renamed) await safeUnlinkOwned(temporaryPath, temporaryStat);
    if (lockHandle) await lockHandle.close().catch(() => {});
    await safeUnlinkOwned(lockPath, lockStat);
  }
}

export async function writeDocumentationIndexAtomic(destination, index, context = {}) {
  if (typeof destination !== "string" || destination.length === 0) {
    throw new TypeError("documentation index destination must be a non-empty path string");
  }
  const limits = configuredLimits(context.limits);
  let bytes;
  try {
    bytes = Buffer.from(canonicalDocumentationIndexBytes(index), "utf8");
    if (bytes.length > limits.documentBytes) {
      fail("TDI04", "documentation index byte limit exceeded", "document-byte-limit");
    }
    validateIndexBytes(bytes, limits);
  } catch (error) {
    if (error instanceof TypeError) throw error;
    return errorResult(error);
  }
  const resolved = path.resolve(destination);
  return serializeDestination(resolved, async () => {
    try {
      return await atomicWrite(resolved, index, bytes, context, limits);
    } catch (error) {
      return errorResult(error, "TDI06");
    }
  });
}

import fs from "node:fs";
import path from "node:path";

const HEX = /^[0-9a-f]{64}$/;
const NAME = /^[A-Za-z][A-Za-z0-9._-]*$/;
const STATUSES = new Set(["error", "provisional", "unavailable", "validated"]);
const IDENTITY_KINDS = new Set([
  "BindingId", "ExportBindingId", "FileId", "ImplementationId",
  "ImportBindingId", "LawEvidenceId", "ModuleId", "NamespaceId",
  "PackageId", "ScopeId", "SymbolId", "TypeId",
]);
export const TYPED_SIDECAR_LIMITS = Object.freeze({
  documentBytes: 16 * 1024 * 1024,
  maxDepth: 128,
  nodes: 65_536,
  references: 131_072,
  diagnostics: 65_536,
  identities: 262_144,
  edges: 262_144,
  attachedTextBytes: 1024 * 1024,
  edits: 4096,
  replacementTextBytes: 1024 * 1024,
});
const LIMITS = TYPED_SIDECAR_LIMITS;
const writeQueues = new Map();
let temporaryCounter = 0;
const LOCK_WAIT_MILLISECONDS = 2000;
const LOCK_POLL_MILLISECONDS = 10;

class CodecFailure extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "CodecFailure";
    this.code = code;
    this.details = details;
  }
}

function fail(message, code = "TS003", details = {}) {
  throw new CodecFailure(code, message, details);
}

class JsonParser {
  constructor(text) {
    this.text = text;
    this.index = 0;
  }

  parse() {
    this.skipSpace();
    const value = this.value("$", 1);
    this.skipSpace();
    if (this.index !== this.text.length) fail(`trailing JSON data at byte ${this.index}`, "TS001", { offset: this.index });
    return value;
  }

  skipSpace() {
    while (/\s/.test(this.text[this.index] ?? "") &&
           " \t\r\n".includes(this.text[this.index])) this.index += 1;
  }

  value(where, depth) {
    if (depth > LIMITS.maxDepth) fail("document exceeds default-v1 structural depth", "TS004", { path: where });
    this.skipSpace();
    const ch = this.text[this.index];
    if (ch === "{") return this.object(where, depth);
    if (ch === "[") return this.array(where, depth);
    if (ch === '"') return this.string();
    if (ch === "t" && this.take("true")) return true;
    if (ch === "f" && this.take("false")) return false;
    if (ch === "n" && this.take("null")) return null;
    if (ch === "-" || /[0-9]/.test(ch ?? "")) return this.number();
    fail(`invalid JSON value at byte ${this.index}`, "TS001", { offset: this.index });
  }

  take(token) {
    if (!this.text.startsWith(token, this.index)) return false;
    this.index += token.length;
    return true;
  }

  string() {
    const start = this.index;
    this.index += 1;
    let escaped = false;
    while (this.index < this.text.length) {
      const ch = this.text[this.index++];
      if (!escaped && ch === '"') {
        const raw = this.text.slice(start, this.index);
        try {
          return JSON.parse(raw);
        } catch {
          fail(`invalid JSON string at byte ${start}`, "TS001", { offset: start });
        }
      }
      if (!escaped && ch === "\\") escaped = true;
      else escaped = false;
    }
    fail(`unterminated JSON string at byte ${start}`, "TS001", { offset: start });
  }

  number() {
    const match = this.text.slice(this.index).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
    if (!match) fail(`invalid JSON number at byte ${this.index}`, "TS001", { offset: this.index });
    this.index += match[0].length;
    return Number(match[0]);
  }

  object(where, depth) {
    this.index += 1;
    const result = Object.create(null);
    const keys = new Set();
    this.skipSpace();
    if (this.text[this.index] === "}") {
      this.index += 1;
      return result;
    }
    while (true) {
      this.skipSpace();
      if (this.text[this.index] !== '"') fail(`object key expected at byte ${this.index}`, "TS001", { offset: this.index });
      const key = this.string();
      if (keys.has(key)) fail(`${where}: duplicate object key ${JSON.stringify(key)}`, "TS001", { path: where });
      keys.add(key);
      this.skipSpace();
      if (this.text[this.index++] !== ":") fail(`':' expected after ${where}.${key}`, "TS001", { path: `${where}.${key}` });
      result[key] = this.value(`${where}.${key}`, depth + 1);
      this.skipSpace();
      const separator = this.text[this.index++];
      if (separator === "}") return result;
      if (separator !== ",") fail(`',' or '}' expected at byte ${this.index - 1}`, "TS001", { offset: this.index - 1 });
    }
  }

  array(where, depth) {
    this.index += 1;
    const result = [];
    this.skipSpace();
    if (this.text[this.index] === "]") {
      this.index += 1;
      return result;
    }
    while (true) {
      result.push(this.value(`${where}[${result.length}]`, depth + 1));
      this.skipSpace();
      const separator = this.text[this.index++];
      if (separator === "]") return result;
      if (separator !== ",") fail(`',' or ']' expected at byte ${this.index - 1}`, "TS001", { offset: this.index - 1 });
    }
  }
}

function sortedValue(value) {
  if (Array.isArray(value)) return value.map(sortedValue);
  if (value !== null && typeof value === "object") {
    const result = Object.create(null);
    for (const key of Object.keys(value).sort()) result[key] = sortedValue(value[key]);
    return result;
  }
  return value;
}

export function canonicalTypedSidecarBytes(value) {
  return `${JSON.stringify(sortedValue(value), null, 2)}\n`;
}

function ensureDocumentBytes(length) {
  if (length > LIMITS.documentBytes) fail("document exceeds default-v1 byte limit", "TS004");
}

function asBuffer(bytes) {
  if (Buffer.isBuffer(bytes)) return Buffer.from(bytes);
  if (bytes instanceof Uint8Array) return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes instanceof ArrayBuffer) return Buffer.from(bytes);
  throw new TypeError("typed-sidecar bytes must be Buffer, Uint8Array, or ArrayBuffer");
}

function decodeJsonBytes(input) {
  const bytes = asBuffer(input);
  ensureDocumentBytes(bytes.length);
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    fail("UTF-8 BOM is forbidden", "TS001");
  }
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    fail("document is not valid UTF-8", "TS001");
  }
  const value = new JsonParser(text).parse();
  return { text, value };
}

export function parseJsonBytesStrict(input) {
  return decodeJsonBytes(input).value;
}

function decodeDocument(input, { canonical = true } = {}) {
  const { text, value } = decodeJsonBytes(input);
  if (canonical && canonicalTypedSidecarBytes(value) !== text) fail("document is not canonical JSON", "TS002");
  return value;
}

function object(value, where, required, optional = []) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) fail(`${where}: object required`, "TS002", { path: where });
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) fail(`${where}: plain data object required`, "TS002", { path: where });
  const allowed = new Set([...required, ...optional]);
  for (const key of required) if (!Object.hasOwn(value, key)) fail(`${where}: missing ${key}`, "TS002", { path: where });
  for (const key of Object.keys(value)) if (!allowed.has(key)) fail(`${where}: unknown field ${key}`, "TS002", { path: `${where}.${key}` });
  return value;
}

function array(value, where, maximum) {
  if (!Array.isArray(value)) fail(`${where}: array required`, "TS002", { path: where });
  if (value.length > maximum) fail(`${where}: item limit exceeded`, "TS004", { path: where });
  return value;
}

function string(value, where, maximum = Infinity) {
  if (typeof value !== "string") fail(`${where}: string required`, "TS002", { path: where });
  if (value.length > maximum) fail(`${where}: string limit exceeded`, "TS004", { path: where });
  if (value.normalize("NFC") !== value) fail(`${where}: string must be NFC`, "TS002", { path: where });
  return value;
}

function name(value, where) {
  string(value, where, 256);
  if (!NAME.test(value)) fail(`${where}: invalid name`);
  return value;
}

function hex(value, where) {
  if (typeof value !== "string" || !HEX.test(value)) fail(`${where}: lowercase 64-hex ID required`);
  return value;
}

function integer(value, where, minimum, maximum) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    fail(`${where}: integer outside ${minimum}..${maximum}`);
  }
  return value;
}

function status(value, where) {
  if (!STATUSES.has(value)) fail(`${where}: invalid fact status`);
  return value;
}

function sortedUniqueStrings(values, where) {
  for (let i = 0; i < values.length; i += 1) {
    string(values[i], `${where}[${i}]`);
    if (i > 0 && values[i - 1] >= values[i]) fail(`${where}: values must be unique and sorted`);
  }
}

function compareTuple(a, b) {
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] < b[i]) return -1;
    if (a[i] > b[i]) return 1;
  }
  return 0;
}

function assertSorted(items, tuple, where) {
  for (let i = 1; i < items.length; i += 1) {
    if (compareTuple(tuple(items[i - 1]), tuple(items[i])) >= 0) {
      fail(`${where}: records must be unique and canonically sorted`);
    }
  }
}

function validateSpan(value, where, byteLength) {
  object(value, where, ["end", "start"]);
  integer(value.start, `${where}.start`, 0, 0xffff_ffff);
  integer(value.end, `${where}.end`, value.start, 0xffff_ffff);
  if (byteLength !== null && value.end > byteLength) fail(`${where}: span exceeds source byte length`);
}

function validateIdentity(value, where) {
  object(value, where, ["kind", "value"]);
  if (!IDENTITY_KINDS.has(value.kind)) fail(`${where}.kind: unknown identity kind`);
  hex(value.value, `${where}.value`);
}

function validateFact(value, where, diagnosticIds) {
  object(value, where, ["status"], ["display", "reason"]);
  status(value.status, `${where}.status`);
  if (value.status === "unavailable") {
    if ("display" in value) fail(`${where}: unavailable fact must not carry display data`);
    name(value.reason, `${where}.reason`);
  } else {
    string(value.display, `${where}.display`, 4096);
    if ("reason" in value) name(value.reason, `${where}.reason`);
  }
  if (value.status === "error" && diagnosticIds.length === 0) {
    fail(`${where}: error fact requires a parent diagnostic link`);
  }
}

function validatePath(value, where) {
  string(value, where, 4096);
  if (value.length === 0 || value.startsWith("/") || value.includes("\\") ||
      /^[A-Za-z][A-Za-z0-9+.-]*:/.test(value)) fail(`${where}: relative logical POSIX path required`);
  const parts = value.split("/");
  if (parts.some((part) => part === "" || part === "." || part === "..")) {
    fail(`${where}: empty, '.' and '..' path components are forbidden`);
  }
}

function validateLocation(value, where, rootFileId, rootByteLength, requireRoot) {
  object(value, where, ["file_id", "span"]);
  hex(value.file_id, `${where}.file_id`);
  if (requireRoot && value.file_id !== rootFileId) fail(`${where}: primary location must use root FileId`);
  validateSpan(value.span, `${where}.span`, value.file_id === rootFileId ? rootByteLength : null);
}

function validateRemedy(value, where, byteLength, counters) {
  object(value, where, ["id"], ["replacement", "span"]);
  name(value.id, `${where}.id`);
  const hasEdit = "replacement" in value || "span" in value;
  if (hasEdit && !("replacement" in value && "span" in value)) fail(`${where}: edit needs both span and replacement`);
  if (hasEdit) {
    string(value.replacement, `${where}.replacement`, 65536);
    validateSpan(value.span, `${where}.span`, byteLength);
    counters.edits += 1;
    counters.replacementTextBytes += Buffer.byteLength(value.replacement);
  }
}

function structuralDepth(value, depth = 1, ancestors = new WeakSet()) {
  if (depth > LIMITS.maxDepth) return depth;
  if (value === null || typeof value !== "object") return depth;
  if (ancestors.has(value)) fail("document contains a cyclic object graph", "TS002");
  ancestors.add(value);
  let maximum = depth;
  for (const child of Array.isArray(value) ? value : Object.values(value)) {
    maximum = Math.max(maximum, structuralDepth(child, depth + 1, ancestors));
    if (maximum > LIMITS.maxDepth) break;
  }
  ancestors.delete(value);
  return maximum;
}

// A v2 document is a v1 document plus the two capture fields, and it is
// validated by this same function rather than a parallel one (#1224). The
// alternative — a second validator for v2 — is how the replacement decision,
// the byte limit, and the depth bound would come to differ between versions
// without anyone choosing that.
const V1_ROOT_FIELDS = Object.freeze([
  "authoritative", "compiler", "completeness", "diagnostics", "file",
  "generation", "limits", "nodes", "references", "schema", "source_status",
]);

const V2_ROOT_FIELDS = Object.freeze([...V1_ROOT_FIELDS, "capture_profile", "captures"]);

const CAPTURE_PROFILE = "kofun.stage2-analysis/scoped-captures/v1";
const CAPTURE_MODES = Object.freeze(["read", "edit", "take"]);
const UNKNOWN_REASONS = Object.freeze([
  "unresolved-call", "projection-depth-exceeded", "unnameable-place",
]);

function validateDocument(doc) {
  const isV2 = doc !== null && typeof doc === "object" &&
    doc.schema === "kofun.typed-sidecar/v2";
  object(doc, "$", isV2 ? V2_ROOT_FIELDS : V1_ROOT_FIELDS);
  if (doc.authoritative !== false) fail("$.authoritative: must be false");
  if (!isV2 && doc.schema !== "kofun.typed-sidecar/v1") fail("$.schema: unsupported schema");
  if (structuralDepth(doc) > LIMITS.maxDepth) fail("document exceeds default-v1 structural depth", "TS004");

  object(doc.compiler, "$.compiler", ["edition", "semantic_compatibility"]);
  name(doc.compiler.edition, "$.compiler.edition");
  name(doc.compiler.semantic_compatibility, "$.compiler.semantic_compatibility");

  object(doc.file, "$.file", [
    "byte_length", "content_sha256", "file_id", "logical_path", "module_id", "package_id",
  ], ["path_remap_root_id"]);
  integer(doc.file.byte_length, "$.file.byte_length", 0, 0xffff_ffff);
  hex(doc.file.content_sha256, "$.file.content_sha256");
  hex(doc.file.file_id, "$.file.file_id");
  hex(doc.file.module_id, "$.file.module_id");
  hex(doc.file.package_id, "$.file.package_id");
  if ("path_remap_root_id" in doc.file) hex(doc.file.path_remap_root_id, "$.file.path_remap_root_id");
  validatePath(doc.file.logical_path, "$.file.logical_path");

  object(doc.generation, "$.generation", ["sequence"]);
  integer(doc.generation.sequence, "$.generation.sequence", 0, Number.MAX_SAFE_INTEGER);
  object(doc.limits, "$.limits", ["document_bytes", "max_depth", "profile"]);
  if (doc.limits.document_bytes !== LIMITS.documentBytes ||
      doc.limits.max_depth !== LIMITS.maxDepth ||
      doc.limits.profile !== (isV2 ? "default-v2" : "default-v1")) {
    fail("$.limits: unknown or incorrect bounded profile");
  }
  if (isV2) validateCaptures(doc);

  const validPair = (doc.completeness === "complete" && doc.source_status === "checked") ||
    (doc.completeness === "partial" && ["failed", "cancelled"].includes(doc.source_status));
  if (!validPair) fail("completeness/source_status pairing is invalid");

  const nodes = array(doc.nodes, "$.nodes", LIMITS.nodes);
  const references = array(doc.references, "$.references", LIMITS.references);
  const diagnostics = array(doc.diagnostics, "$.diagnostics", LIMITS.diagnostics);
  const nodeIds = new Map();
  const referenceIds = new Set();
  const diagnosticIds = new Set();
  const allIds = new Set();
  const counters = { identities: 0, edges: 0, attachedTextBytes: 0, edits: 0, replacementTextBytes: 0 };

  for (let index = 0; index < nodes.length; index += 1) {
    const where = `$.nodes[${index}]`;
    const node = object(nodes[index], where, [
      "depends_on", "diagnostic_ids", "id", "identities", "kind", "span", "status",
    ], ["effect", "origin", "ownership", "type"]);
    hex(node.id, `${where}.id`);
    if (allIds.has(node.id)) fail(`${where}.id: duplicate sidecar-local ID`);
    allIds.add(node.id);
    nodeIds.set(node.id, node);
    name(node.kind, `${where}.kind`);
    validateSpan(node.span, `${where}.span`, doc.file.byte_length);
    status(node.status, `${where}.status`);
    array(node.depends_on, `${where}.depends_on`, LIMITS.nodes);
    array(node.diagnostic_ids, `${where}.diagnostic_ids`, 256);
    sortedUniqueStrings(node.depends_on, `${where}.depends_on`);
    sortedUniqueStrings(node.diagnostic_ids, `${where}.diagnostic_ids`);
    counters.edges += node.depends_on.length + node.diagnostic_ids.length;
    const identities = array(node.identities, `${where}.identities`, 64);
    for (let i = 0; i < identities.length; i += 1) validateIdentity(identities[i], `${where}.identities[${i}]`);
    assertSorted(identities, (identity) => [identity.kind, identity.value], `${where}.identities`);
    counters.identities += identities.length;
    for (const field of ["effect", "origin", "ownership", "type"]) {
      if (field in node) validateFact(node[field], `${where}.${field}`, node.diagnostic_ids);
    }
    if (node.status === "error" && node.diagnostic_ids.length === 0) fail(`${where}: error node needs a diagnostic`);
    if (node.status === "unavailable") {
      for (const field of ["effect", "origin", "ownership", "type"]) {
        if (field in node && node[field].status !== "unavailable") fail(`${where}: unavailable node cannot carry ${field} data`);
      }
    }
  }
  assertSorted(nodes, (node) => [node.span.start, node.span.end, node.kind, node.id], "$.nodes");

  for (let index = 0; index < references.length; index += 1) {
    const where = `$.references[${index}]`;
    const reference = object(references[index], where, [
      "diagnostic_ids", "from_node", "id", "namespace", "span", "status", "target",
    ]);
    hex(reference.id, `${where}.id`);
    if (allIds.has(reference.id)) fail(`${where}.id: duplicate sidecar-local ID`);
    allIds.add(reference.id);
    referenceIds.add(reference.id);
    hex(reference.from_node, `${where}.from_node`);
    validateSpan(reference.span, `${where}.span`, doc.file.byte_length);
    if (!["meta", "module", "type", "value"].includes(reference.namespace)) fail(`${where}.namespace: invalid namespace`);
    status(reference.status, `${where}.status`);
    array(reference.diagnostic_ids, `${where}.diagnostic_ids`, 256);
    sortedUniqueStrings(reference.diagnostic_ids, `${where}.diagnostic_ids`);
    counters.edges += reference.diagnostic_ids.length + 1;
    const target = object(reference.target, `${where}.target`, ["disclosure"], [
      "declaration_node", "identity", "identity_kind", "reason",
    ]);
    if (!["hidden", "provisional", "resolved", "unavailable"].includes(target.disclosure)) {
      fail(`${where}.target.disclosure: invalid disclosure`);
    }
    if (target.disclosure === "resolved") {
      if (!("identity" in target) || "identity_kind" in target || "reason" in target) fail(`${where}.target: malformed resolved target`);
      validateIdentity(target.identity, `${where}.target.identity`);
      counters.identities += 1;
    } else {
      if ("identity" in target || "declaration_node" in target) fail(`${where}.target: non-resolved target leaks identity or declaration`);
      if ("identity_kind" in target && !IDENTITY_KINDS.has(target.identity_kind)) fail(`${where}.target.identity_kind: unknown kind`);
      if (target.disclosure !== "hidden" && "identity_kind" in target) fail(`${where}.target: identity kind is permitted only for hidden disclosure`);
      if (target.disclosure !== "hidden" && !("reason" in target)) fail(`${where}.target: reason required`);
      if ("reason" in target) name(target.reason, `${where}.target.reason`);
    }
    const expectedDisclosure = {
      validated: "resolved", provisional: "provisional", error: "unavailable",
    }[reference.status];
    if (expectedDisclosure && target.disclosure !== expectedDisclosure) fail(`${where}: status and target disclosure disagree`);
    if (reference.status === "unavailable" && !["hidden", "unavailable"].includes(target.disclosure)) fail(`${where}: unavailable reference has unsafe target`);
    if (reference.status === "error" && reference.diagnostic_ids.length === 0) fail(`${where}: error reference needs a diagnostic`);
  }
  assertSorted(references, (reference) => [reference.span.start, reference.span.end, reference.id], "$.references");

  const severityRank = { error: 0, warning: 1, information: 2, hint: 3 };
  for (let index = 0; index < diagnostics.length; index += 1) {
    const where = `$.diagnostics[${index}]`;
    const diagnostic = object(diagnostics[index], where, [
      "affected_ids", "category", "code", "fallback_text", "id", "primary", "related",
      "remedies", "severity", "template_id", "truncated",
    ]);
    hex(diagnostic.id, `${where}.id`);
    if (allIds.has(diagnostic.id)) fail(`${where}.id: duplicate sidecar-local ID`);
    allIds.add(diagnostic.id);
    diagnosticIds.add(diagnostic.id);
    name(diagnostic.category, `${where}.category`);
    if (typeof diagnostic.code !== "string" || !/^[A-Z][A-Z0-9]{0,15}$/.test(diagnostic.code)) fail(`${where}.code: invalid diagnostic code`);
    string(diagnostic.fallback_text, `${where}.fallback_text`, 65536);
    counters.attachedTextBytes += Buffer.byteLength(diagnostic.fallback_text);
    if (!(diagnostic.severity in severityRank)) fail(`${where}.severity: invalid severity`);
    name(diagnostic.template_id, `${where}.template_id`);
    if (typeof diagnostic.truncated !== "boolean") fail(`${where}.truncated: boolean required`);
    validateLocation(diagnostic.primary, `${where}.primary`, doc.file.file_id, doc.file.byte_length, true);
    array(diagnostic.affected_ids, `${where}.affected_ids`, LIMITS.edges);
    sortedUniqueStrings(diagnostic.affected_ids, `${where}.affected_ids`);
    counters.edges += diagnostic.affected_ids.length;
    const related = array(diagnostic.related, `${where}.related`, 256);
    for (let i = 0; i < related.length; i += 1) {
      const itemWhere = `${where}.related[${i}]`;
      const item = object(related[i], itemWhere, ["relation"], ["identity", "location"]);
      name(item.relation, `${itemWhere}.relation`);
      if (!("identity" in item) && !("location" in item)) fail(`${itemWhere}: identity or location required`);
      if ("identity" in item) { validateIdentity(item.identity, `${itemWhere}.identity`); counters.identities += 1; }
      if ("location" in item) validateLocation(item.location, `${itemWhere}.location`, doc.file.file_id, doc.file.byte_length, false);
    }
    assertSorted(related, (item) => [
      item.relation, item.location?.file_id ?? "", item.location?.span.start ?? -1,
      item.location?.span.end ?? -1, item.identity?.kind ?? "", item.identity?.value ?? "",
    ], `${where}.related`);
    const remedies = array(diagnostic.remedies, `${where}.remedies`, 256);
    for (let i = 0; i < remedies.length; i += 1) validateRemedy(remedies[i], `${where}.remedies[${i}]`, doc.file.byte_length, counters);
    assertSorted(remedies, (remedy) => [remedy.id, remedy.span?.start ?? -1, remedy.span?.end ?? -1, remedy.replacement ?? ""], `${where}.remedies`);
  }
  assertSorted(diagnostics, (diagnostic) => [
    diagnostic.primary.file_id, diagnostic.primary.span.start, diagnostic.primary.span.end,
    severityRank[diagnostic.severity], diagnostic.code, diagnostic.id,
  ], "$.diagnostics");

  for (const [nodeId, node] of nodeIds) {
    for (const dependency of node.depends_on) {
      if (!nodeIds.has(dependency)) fail(`node ${nodeId}: dangling dependency ${dependency}`);
      if (node.status === "validated" && nodeIds.get(dependency).status !== "validated") {
        fail(`node ${nodeId}: validated node depends on non-validated node`);
      }
    }
    for (const diagnosticId of node.diagnostic_ids) if (!diagnosticIds.has(diagnosticId)) fail(`node ${nodeId}: dangling diagnostic ${diagnosticId}`);
  }
  for (const reference of references) {
    if (!nodeIds.has(reference.from_node)) fail(`reference ${reference.id}: dangling from_node`);
    if (reference.status === "validated" && nodeIds.get(reference.from_node).status !== "validated") fail(`reference ${reference.id}: validated reference has non-validated source node`);
    if (reference.target.declaration_node && !nodeIds.has(reference.target.declaration_node)) fail(`reference ${reference.id}: dangling declaration_node`);
    for (const diagnosticId of reference.diagnostic_ids) if (!diagnosticIds.has(diagnosticId)) fail(`reference ${reference.id}: dangling diagnostic ${diagnosticId}`);
  }
  for (const diagnostic of diagnostics) {
    for (const affected of diagnostic.affected_ids) {
      if (!nodeIds.has(affected) && !referenceIds.has(affected)) fail(`diagnostic ${diagnostic.id}: dangling affected ID`);
    }
  }

  if (doc.completeness === "complete") {
    if (diagnostics.some((item) => item.severity === "error")) fail("complete document contains an error diagnostic");
    if (nodes.some((item) => item.status !== "validated") || references.some((item) => item.status !== "validated")) fail("complete document contains a non-validated fact");
    for (const node of nodes) for (const field of ["effect", "origin", "ownership", "type"]) {
      if (field in node && node[field].status !== "validated") fail("complete document contains a non-validated nested fact");
    }
  }
  if (doc.source_status === "failed" && !diagnostics.some((item) => item.severity === "error")) fail("failed document requires an error diagnostic");
  if (counters.identities > LIMITS.identities) fail("stable identity record limit exceeded", "TS004");
  if (counters.edges > LIMITS.edges) fail("dependency/affected edge limit exceeded", "TS004");
  if (counters.attachedTextBytes > LIMITS.attachedTextBytes) fail("attached fallback text byte limit exceeded", "TS004");
  if (counters.edits > LIMITS.edits) fail("edit limit exceeded", "TS004");
  if (counters.replacementTextBytes > LIMITS.replacementTextBytes) fail("replacement text byte limit exceeded", "TS004");
  return doc;
}

function publicError(error, fallbackCode = "TS003") {
  const code = error instanceof CodecFailure ? error.code :
    error instanceof RangeError ? "TS004" : fallbackCode;
  const rawMessage = error instanceof CodecFailure ? error.message :
    code === "TS004" ? "typed-sidecar structural limit exceeded" :
      "typed-sidecar validation failed";
  const details = error instanceof CodecFailure ? error.details : {};
  const bounded = (value, maximum) => value.length <= maximum ? value : `${value.slice(0, maximum - 3)}...`;
  const result = { code, message: bounded(rawMessage, 512) };
  if (typeof details.path === "string") result.path = bounded(details.path, 512);
  if (Number.isSafeInteger(details.offset) && details.offset >= 0) result.offset = details.offset;
  if (typeof details.reason === "string") result.reason = bounded(details.reason, 64);
  if (typeof details.errno === "string") result.errno = bounded(details.errno, 32);
  return Object.freeze(result);
}

function errorResult(error, fallbackCode) {
  return Object.freeze({ ok: false, error: publicError(error, fallbackCode) });
}

function deepFreeze(root) {
  const pending = [root];
  const seen = new WeakSet();
  while (pending.length > 0) {
    const value = pending.pop();
    if (value === null || typeof value !== "object" || seen.has(value)) continue;
    seen.add(value);
    for (const child of Array.isArray(value) ? value : Object.values(value)) pending.push(child);
    Object.freeze(value);
  }
  return root;
}

// The capture section a v2 document publishes. This checks the shape a reader
// depends on — identities, the closed vocabularies, and the alignment between
// a target's kind and the payload it carries. What the captures *mean* is the
// scope-HIR's business and is checked against it by `task typed-sidecar-captures`;
// a document that arrives here has already been projected.
function validateCaptures(doc) {
  if (doc.capture_profile !== CAPTURE_PROFILE) {
    fail("$.capture_profile: unknown capture profile");
  }
  const captures = array(doc.captures, "$.captures", LIMITS.nodes);
  const seen = new Set();
  for (const [index, capture] of captures.entries()) {
    const at = `$.captures[${index}]`;
    object(capture, at, ["id", "mode", "origin_node_ids", "target", "task_id"]);
    hex(capture.id, `${at}.id`);
    hex(capture.task_id, `${at}.task_id`);
    if (seen.has(capture.id)) fail(`${at}.id: duplicate capture identity`);
    seen.add(capture.id);
    if (!CAPTURE_MODES.includes(capture.mode)) fail(`${at}.mode: unknown capture mode`);
    const origins = array(capture.origin_node_ids, `${at}.origin_node_ids`, LIMITS.nodes);
    if (origins.length === 0) fail(`${at}.origin_node_ids: a capture names at least one origin`);
    const originSet = new Set();
    for (const [originIndex, origin] of origins.entries()) {
      hex(origin, `${at}.origin_node_ids[${originIndex}]`);
      if (originSet.has(origin)) fail(`${at}.origin_node_ids: origins repeat`);
      originSet.add(origin);
    }
    const target = capture.target;
    if (target === null || typeof target !== "object") fail(`${at}.target: expected an object`);
    if (target.kind === "place") {
      object(target, `${at}.target`, ["kind", "place"]);
      object(target.place, `${at}.target.place`,
        ["base_binding_id", "canonical_bytes", "id", "projections"]);
      hex(target.place.base_binding_id, `${at}.target.place.base_binding_id`);
      hex(target.place.id, `${at}.target.place.id`);
      if (typeof target.place.canonical_bytes !== "string" ||
          !/^(?:[0-9a-f]{2})+$/.test(target.place.canonical_bytes)) {
        fail(`${at}.target.place.canonical_bytes: expected lowercase hexadecimal bytes`);
      }
      array(target.place.projections, `${at}.target.place.projections`, LIMITS.nodes);
    } else if (target.kind === "unknown") {
      object(target, `${at}.target`, ["kind", "unknown"]);
      object(target.unknown, `${at}.target.unknown`,
        ["canonical_bytes", "id", "reason", "witness_node_id"]);
      hex(target.unknown.id, `${at}.target.unknown.id`);
      hex(target.unknown.witness_node_id, `${at}.target.unknown.witness_node_id`);
      if (!UNKNOWN_REASONS.includes(target.unknown.reason)) {
        fail(`${at}.target.unknown.reason: unknown reason`);
      }
      // An unknown target is a place the analysis could not name, so it has
      // exactly one witness and one origin; more than one would be a claim
      // this document cannot support.
      if (origins.length !== 1) {
        fail(`${at}.origin_node_ids: an unknown target carries exactly one origin`);
      }
    } else {
      fail(`${at}.target.kind: expected place or unknown`);
    }
  }
}

function validatedClone(document) {
  let clone;
  try {
    clone = structuredClone(document);
  } catch {
    fail("document is not a cloneable data record", "TS002");
  }
  return validateDocument(clone);
}

export function readTypedSidecar(bytes) {
  try {
    const document = validateDocument(decodeDocument(bytes));
    return Object.freeze({ ok: true, document: deepFreeze(document) });
  } catch (error) {
    if (error instanceof TypeError) throw error;
    return errorResult(error);
  }
}

export function encodeTypedSidecar(document) {
  try {
    const validated = validatedClone(document);
    const encoded = Buffer.from(canonicalTypedSidecarBytes(validated), "utf8");
    ensureDocumentBytes(encoded.length);
    return Object.freeze({ ok: true, bytes: new Uint8Array(encoded) });
  } catch (error) {
    return errorResult(error, "TS002");
  }
}

function decision(allow, reason) {
  return Object.freeze({ allow, reason });
}

export function canReplaceTypedSidecar(oldDocument, newDocument, currentSourceDigest) {
  let oldValidated;
  let newValidated;
  try {
    oldValidated = validatedClone(oldDocument);
  } catch {
    return decision(false, "invalid-old");
  }
  try {
    newValidated = validatedClone(newDocument);
  } catch {
    return decision(false, "invalid-new");
  }
  if (typeof currentSourceDigest !== "string" || !HEX.test(currentSourceDigest) ||
      newValidated.file.content_sha256 !== currentSourceDigest) {
    return decision(false, "source-mismatch");
  }
  if (oldValidated.file.file_id !== newValidated.file.file_id) return decision(false, "wrong-file");
  if (newValidated.generation.sequence <= oldValidated.generation.sequence) return decision(false, "stale-sequence");
  return decision(true, "allow");
}

function ioFailure(reason, errno) {
  return new CodecFailure("TS006", reason, errno ? { errno } : {});
}

function assertNotCancelled(signal) {
  if (signal?.aborted) throw ioFailure("typed-sidecar write cancelled");
}

async function serializeDestination(key, operation) {
  const previous = writeQueues.get(key) ?? Promise.resolve();
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const tail = previous.catch(() => {}).then(() => gate);
  writeQueues.set(key, tail);
  await previous.catch(() => {});
  try {
    return await operation();
  } finally {
    release();
    if (writeQueues.get(key) === tail) writeQueues.delete(key);
  }
}

async function openExclusive(filename) {
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL |
    (fs.constants.O_NOFOLLOW ?? 0);
  return fs.promises.open(filename, flags, 0o600);
}

async function acquireDestinationLock(filename, signal) {
  const attempts = Math.ceil(
    LOCK_WAIT_MILLISECONDS / LOCK_POLL_MILLISECONDS,
  );
  for (let attempt = 0; ; attempt += 1) {
    assertNotCancelled(signal);
    try {
      return await openExclusive(filename);
    } catch (error) {
      if (error.code !== "EEXIST") {
        throw ioFailure("cannot acquire typed-sidecar destination lock", error.code);
      }
      if (attempt >= attempts) {
        throw ioFailure("typed-sidecar destination is busy", error.code);
      }
      await new Promise((resolve) => setTimeout(resolve, LOCK_POLL_MILLISECONDS));
    }
  }
}

async function readDestination(filename) {
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0);
  let handle;
  try {
    handle = await fs.promises.open(filename, flags);
  } catch (error) {
    if (error.code === "ENOENT") return Object.freeze({ exists: false });
    if (error.code === "ELOOP") throw ioFailure("typed-sidecar destination must not be a symlink", error.code);
    throw ioFailure("cannot open typed-sidecar destination safely", error.code);
  }
  try {
    const stat = await handle.stat();
    if (!stat.isFile()) throw ioFailure("typed-sidecar destination must be a regular file");
    const bytes = await handle.readFile();
    ensureDocumentBytes(bytes.length);
    return { exists: true, bytes };
  } catch (error) {
    if (error instanceof CodecFailure) throw error;
    throw ioFailure("cannot read typed-sidecar destination", error.code);
  } finally {
    await handle.close().catch(() => {});
  }
}

function replacementAgainst(destination, newDocument, currentSourceDigest) {
  if (!destination.exists) {
    return newDocument.file.content_sha256 === currentSourceDigest ?
      decision(true, "allow") : decision(false, "source-mismatch");
  }
  const oldResult = readTypedSidecar(destination.bytes);
  if (!oldResult.ok) return decision(false, "invalid-old");
  return canReplaceTypedSidecar(oldResult.document, newDocument, currentSourceDigest);
}

async function safeUnlinkOwned(filename, ownedStat) {
  if (!ownedStat) return;
  try {
    const current = await fs.promises.lstat(filename);
    if (current.dev === ownedStat.dev && current.ino === ownedStat.ino) await fs.promises.unlink(filename);
  } catch (error) {
    if (error.code !== "ENOENT") return;
  }
}

async function atomicWrite(destination, document, encodedBytes, context) {
  const directory = path.dirname(destination);
  const basename = path.basename(destination);
  const lockPath = path.join(directory, `.${basename}.typed-sidecar.lock`);
  let lockHandle;
  let lockStat;
  let temporaryPath;
  let temporaryStat;
  let temporaryHandle;
  let renamed = false;
  try {
    assertNotCancelled(context.signal);
    lockHandle = await acquireDestinationLock(lockPath, context.signal);
    lockStat = await lockHandle.stat();

    const initial = await readDestination(destination);
    let replacement = replacementAgainst(initial, document, context.currentSourceDigest);
    if (!replacement.allow) fail(`replacement denied: ${replacement.reason}`, "TS005", { reason: replacement.reason });

    temporaryCounter += 1;
    temporaryPath = path.join(directory, `.${basename}.tmp-${process.pid}-${temporaryCounter}`);
    try {
      temporaryHandle = await openExclusive(temporaryPath);
      temporaryStat = await temporaryHandle.stat();
      await temporaryHandle.writeFile(Buffer.from(encodedBytes));
      await temporaryHandle.sync();
      await temporaryHandle.close();
      temporaryHandle = undefined;
    } catch (error) {
      if (error instanceof CodecFailure) throw error;
      throw ioFailure("cannot write typed-sidecar temporary file", error.code);
    }

    assertNotCancelled(context.signal);
    const current = await readDestination(destination);
    const currentTemporary = await fs.promises.lstat(temporaryPath);
    if (currentTemporary.dev !== temporaryStat.dev || currentTemporary.ino !== temporaryStat.ino ||
        !currentTemporary.isFile()) throw ioFailure("typed-sidecar temporary file identity changed");
    assertNotCancelled(context.signal);
    let commitSourceDigest = context.currentSourceDigest;
    if (context.refreshCurrentSourceDigest) {
      try {
        commitSourceDigest = await context.refreshCurrentSourceDigest();
      } catch {
        fail("replacement denied: source-mismatch", "TS005", {
          reason: "source-mismatch",
        });
      }
      if (typeof commitSourceDigest !== "string" || !HEX.test(commitSourceDigest)) {
        fail("replacement denied: source-mismatch", "TS005", {
          reason: "source-mismatch",
        });
      }
    }
    replacement = replacementAgainst(current, document, commitSourceDigest);
    if (!replacement.allow) fail(`replacement denied: ${replacement.reason}`, "TS005", { reason: replacement.reason });
    assertNotCancelled(context.signal);
    try {
      await fs.promises.rename(temporaryPath, destination);
      renamed = true;
    } catch (error) {
      throw ioFailure("cannot atomically replace typed-sidecar destination", error.code);
    }
    return Object.freeze({ ok: true, bytes: encodedBytes.byteLength, sequence: document.generation.sequence });
  } finally {
    if (temporaryHandle) await temporaryHandle.close().catch(() => {});
    if (!renamed) await safeUnlinkOwned(temporaryPath, temporaryStat);
    if (lockHandle) await lockHandle.close().catch(() => {});
    await safeUnlinkOwned(lockPath, lockStat);
  }
}

export async function writeTypedSidecarAtomic(destination, document, replacementContext) {
  if (typeof destination !== "string" || destination.length === 0) {
    throw new TypeError("typed-sidecar destination must be a non-empty path string");
  }
  if (replacementContext === null || typeof replacementContext !== "object" ||
      typeof replacementContext.currentSourceDigest !== "string") {
    throw new TypeError("typed-sidecar replacement context needs currentSourceDigest");
  }
  if ("refreshCurrentSourceDigest" in replacementContext &&
      typeof replacementContext.refreshCurrentSourceDigest !== "function") {
    throw new TypeError("typed-sidecar source digest refresh must be a function");
  }
  const encoded = encodeTypedSidecar(document);
  if (!encoded.ok) return encoded;
  const stableDocument = readTypedSidecar(encoded.bytes);
  if (!stableDocument.ok) return stableDocument;
  const resolved = path.resolve(destination);
  return serializeDestination(resolved, async () => {
    try {
      return await atomicWrite(resolved, stableDocument.document, encoded.bytes, replacementContext);
    } catch (error) {
      return errorResult(error, "TS006");
    }
  });
}

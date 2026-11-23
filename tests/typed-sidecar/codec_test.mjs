import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  TYPED_SIDECAR_LIMITS,
  canReplaceTypedSidecar,
  encodeTypedSidecar,
  readTypedSidecar,
} from "../../tooling/typed-sidecar/codec.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const EXAMPLES = path.join(ROOT, "spec/typed-sidecar/examples");

function bytes(name) {
  return fs.readFileSync(path.join(EXAMPLES, `${name}.json`));
}

function document(name) {
  const result = readTypedSidecar(bytes(name));
  assert.equal(result.ok, true, `${name}: ${result.error?.message ?? "read failed"}`);
  return result.document;
}

function assertDeepFrozen(root) {
  const pending = [root];
  const seen = new WeakSet();
  while (pending.length > 0) {
    const value = pending.pop();
    if (value === null || typeof value !== "object" || seen.has(value)) continue;
    seen.add(value);
    assert.equal(Object.isFrozen(value), true);
    pending.push(...(Array.isArray(value) ? value : Object.values(value)));
  }
}

function reverseInsertionOrder(value) {
  if (Array.isArray(value)) return value.map(reverseInsertionOrder);
  if (value !== null && typeof value === "object") {
    const result = {};
    for (const key of Object.keys(value).reverse()) result[key] = reverseInsertionOrder(value[key]);
    return result;
  }
  return value;
}

for (const name of ["complete", "partial", "cancelled"]) {
  const original = bytes(name);
  const decoded = document(name);
  assertDeepFrozen(decoded);
  const encoded = encodeTypedSidecar(decoded);
  assert.equal(encoded.ok, true);
  assert.deepEqual(Buffer.from(encoded.bytes), original);
  const reordered = encodeTypedSidecar(reverseInsertionOrder(decoded));
  assert.equal(reordered.ok, true);
  assert.deepEqual(Buffer.from(reordered.bytes), original);
}

const complete = document("complete");
const partial = document("partial");
const cancelled = document("cancelled");

assert.throws(() => { complete.nodes.push({}); }, TypeError);
assert.throws(() => { complete.file.logical_path = "changed"; }, TypeError);

assert.deepEqual(
  canReplaceTypedSidecar(complete, partial, partial.file.content_sha256),
  { allow: true, reason: "allow" },
);
assert.deepEqual(
  canReplaceTypedSidecar(partial, complete, complete.file.content_sha256),
  { allow: false, reason: "stale-sequence" },
);
assert.deepEqual(
  canReplaceTypedSidecar(complete, complete, complete.file.content_sha256),
  { allow: false, reason: "stale-sequence" },
);
assert.deepEqual(
  canReplaceTypedSidecar(complete, partial, complete.file.content_sha256),
  { allow: false, reason: "source-mismatch" },
);
const wrongFile = structuredClone(cancelled);
wrongFile.file.file_id = "0000000000000000000000000000000000000000000000000000000000000000";
assert.deepEqual(
  canReplaceTypedSidecar(partial, wrongFile, wrongFile.file.content_sha256),
  { allow: false, reason: "wrong-file" },
);

const malformed = [
  [Buffer.from([0xc3, 0x28]), "TS001"],
  [Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), bytes("complete")]), "TS001"],
  [Buffer.from(`${bytes("complete").toString("utf8")}x`), "TS001"],
  [Buffer.from('{"authoritative":false,"authoritative":true}\n'), "TS001"],
  [Buffer.from('{"__proto__":{"authoritative":false}}\n'), "TS002"],
  [Buffer.from(JSON.stringify(JSON.parse(bytes("complete"))) + "\n"), "TS002"],
  [Buffer.from(`${"[".repeat(129)}0${"]".repeat(129)}\n`), "TS004"],
  [Buffer.alloc(TYPED_SIDECAR_LIMITS.documentBytes + 1, 0x20), "TS004"],
];
for (const [input, code] of malformed) {
  const result = readTypedSidecar(input);
  assert.equal(result.ok, false);
  assert.equal(result.error.code, code);
}

const authoritative = structuredClone(complete);
authoritative.authoritative = true;
assert.equal(encodeTypedSidecar(authoritative).ok, false);

const hiddenLeak = structuredClone(partial);
hiddenLeak.references[1].target.identity = {
  kind: "SymbolId",
  value: "8888888888888888888888888888888888888888888888888888888888888888",
};
assert.equal(encodeTypedSidecar(hiddenLeak).ok, false);

const wrongSchema = structuredClone(complete);
wrongSchema.schema = "kofun.typed-sidecar/v2";
assert.equal(encodeTypedSidecar(wrongSchema).ok, false);

const v3 = structuredClone(complete);
v3.schema = "kofun.typed-sidecar/v3";
v3.limits.profile = "default-v3";
const fn = v3.nodes.find(node => node.kind === "function.declaration");
fn.effect = { display: "pure", status: "validated" };
v3.declared_pure_functions = [fn.id];
const v3Bytes = encodeTypedSidecar(v3);
assert.equal(v3Bytes.ok, true, v3Bytes.error?.message);
assert.deepEqual(structuredClone(readTypedSidecar(v3Bytes.bytes).document), v3);
for (const ids of [
  ["invalid-id"], ["0".repeat(64)], [fn.id, fn.id],
  [v3.nodes.find(node => node.kind === "parameter.binding").id],
]) {
  assert.equal(encodeTypedSidecar({ ...v3, declared_pure_functions: ids }).ok, false);
}
const tooManyDeclarations = encodeTypedSidecar({
  ...v3, declared_pure_functions: Array(4097).fill(fn.id),
});
assert.equal(tooManyDeclarations.error.code, "TS004");
assert.equal(encodeTypedSidecar({ ...v3, schema: "kofun.typed-sidecar/v4" }).ok, false);
assert.equal(encodeTypedSidecar({ ...v3, captures: [] }).ok, false);
fn.effect.display = "io";
assert.equal(encodeTypedSidecar(v3).ok, false, "an IO function cannot attest declared purity");

const invalidId = structuredClone(complete);
invalidId.file.file_id = "NOT-A-LOWERCASE-HEX-ID";
assert.equal(encodeTypedSidecar(invalidId).ok, false);

const countOverflow = structuredClone(complete);
countOverflow.nodes = Array(TYPED_SIDECAR_LIMITS.nodes + 1).fill(null);
const countResult = encodeTypedSidecar(countOverflow);
assert.equal(countResult.ok, false);
assert.equal(countResult.error.code, "TS004");

const textOverflow = structuredClone(partial);
textOverflow.diagnostics[0].fallback_text = "x".repeat(65_537);
const textResult = encodeTypedSidecar(textOverflow);
assert.equal(textResult.ok, false);
assert.equal(textResult.error.code, "TS004");

const decomposed = structuredClone(complete);
decomposed.file.logical_path = "src/cafe\u0301.kofun";
assert.equal(encodeTypedSidecar(decomposed).ok, false);

const hugeUnknownKey = `unknown-${"x".repeat(4096)}`;
const boundedError = readTypedSidecar(Buffer.from(`{"${hugeUnknownKey}":0}\n`));
assert.equal(boundedError.ok, false);
assert.ok(boundedError.error.message.length <= 512);
assert.ok((boundedError.error.path?.length ?? 0) <= 512);

const cyclic = structuredClone(complete);
cyclic.file.loop = cyclic;
const cyclicResult = encodeTypedSidecar(cyclic);
assert.equal(cyclicResult.ok, false);
assert.equal(cyclicResult.error.code, "TS002");

console.log("PASS: typed-sidecar production codec validation and canonical encoding");

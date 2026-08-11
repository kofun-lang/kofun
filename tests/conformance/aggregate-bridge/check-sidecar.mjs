#!/usr/bin/env node

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";

import { readTypedSidecar } from "../../../tooling/typed-sidecar/codec.mjs";

const [sidecarPath, sourcePath] = process.argv.slice(2);
if (sidecarPath === undefined || sourcePath === undefined) {
  throw new Error("usage: check-sidecar.mjs SIDECAR SOURCE");
}

function exactOne(values, label) {
  assert.equal(values.length, 1, `${label}: expected exactly one, got ${values.length}`);
  return values[0];
}

try {
  const encoded = fs.readFileSync(sidecarPath);
  const decoded = readTypedSidecar(encoded);
  assert.equal(decoded.ok, true, decoded.error?.message);
  const document = decoded.document;
  const sourceBytes = fs.readFileSync(sourcePath);

  assert.equal(document.authoritative, false);
  assert.equal(document.completeness, "complete");
  assert.equal(document.source_status, "checked");
  assert.equal(document.generation.sequence, 1);
  assert.deepEqual(document.diagnostics, []);
  assert.equal(
    document.file.content_sha256,
    crypto.createHash("sha256").update(sourceBytes).digest("hex"),
  );
  assert.equal(
    document.file.logical_path,
    "tests/conformance/aggregate-bridge/bridge.kofun",
  );
  assert.ok(document.nodes.every((node) => node.status === "validated"));
  assert.ok(document.references.every((reference) =>
    reference.status === "validated" &&
    reference.target.disclosure === "resolved"));

  const nodesById = new Map(document.nodes.map((node) => [node.id, node]));
  const declaration = exactOne(
    document.nodes.filter((node) => node.kind === "adt.declaration"),
    "nominal record declaration",
  );
  assert.deepEqual(declaration.identities.map((identity) => identity.kind), ["TypeId"]);

  const functionWithType = (display) => exactOne(
    document.nodes.filter((node) =>
      node.kind === "function.declaration" && node.type?.display === display),
    `function fact ${display}`,
  );

  functionWithType("BridgeReport -> BridgeReport");
  const resultTypedFunctions = [
    "BridgeReport -> Text",
    "BridgeReport -> List[Int]",
    "BridgeReport -> Int",
  ];
  for (const signature of resultTypedFunctions) {
    const fn = functionWithType(signature);
    const parameter = exactOne(
      fn.depends_on.map((id) => nodesById.get(id)).filter((node) =>
        node?.kind === "parameter.binding" &&
        node.type?.display === "BridgeReport" &&
        node.ownership?.display === "copy"),
      `${signature} BridgeReport parameter fact`,
    );
    const use = exactOne(
      document.nodes.filter((node) =>
        node.kind === "name.reference" &&
        node.type?.display === "BridgeReport" &&
        node.depends_on.includes(parameter.id)),
      `${signature} resolved base-reference fact`,
    );
    const reference = exactOne(
      document.references.filter((candidate) => candidate.from_node === use.id),
      `${signature} reference edge`,
    );
    assert.equal(reference.namespace, "value");
    assert.equal(reference.target.declaration_node, parameter.id);
    assert.equal(reference.target.identity.kind, "BindingId");
  }

  for (const display of ["BridgeReport", "Text", "List[Int]", "Int"]) {
    assert.ok(
      document.nodes.some((node) => node.type?.display === display),
      `complete sidecar omitted an exact ${display} type fact`,
    );
  }
  assert.ok(
    document.nodes.filter((node) =>
      node.kind === "local.binding" && node.type?.display === "BridgeReport").length >= 2,
    "sidecar omitted the constructed/returned nominal record bindings",
  );
  assert.ok(
    document.nodes.filter((node) =>
      node.kind === "local.binding" && node.type?.display === "List[Int]").length >= 3,
    "sidecar omitted the source/observed/copied List[Int] bindings",
  );

  console.log(
    "PASS: complete typed sidecar carries nominal, function, resolved base-reference, and concrete-type facts",
  );
} catch (error) {
  console.error(`aggregate-bridge sidecar: ${error.message}`);
  process.exitCode = 1;
}

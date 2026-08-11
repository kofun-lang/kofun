#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";

const [layoutPath, emittedCPath] = process.argv.slice(2);
if (layoutPath === undefined || emittedCPath === undefined) {
  throw new Error("usage: check-layout.mjs AGGREGATE_LAYOUT_JSON EMITTED_C");
}

function asserted(source, expression) {
  const escaped = expression.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = source.match(new RegExp(`${escaped}\\s*==\\s*([0-9]+)`));
  assert.notEqual(match, null, `emitted C omitted an assertion for ${expression}`);
  return match[1];
}

try {
  const document = JSON.parse(fs.readFileSync(layoutPath, "utf8"));
  const emitted = fs.readFileSync(emittedCPath, "utf8");
  assert.equal(document.schema, "kofun.aggregate-layout/v1");

  const byId = new Map(document.layouts.map((layout) => [layout.id, layout]));
  const text = byId.get("Text");
  const bounded = byId.get("BoundedList[Int, 64]");
  const report = byId.get("BridgeReport");

  assert.equal(text?.kind, "text");
  assert.deepEqual(text?.pointers, ["0"]);
  assert.equal(text?.drop, "managed");
  assert.equal(bounded?.kind, "bounded_list");
  assert.equal(bounded?.element, "Int");
  assert.equal(bounded?.capacity, "64");
  assert.deepEqual(bounded?.pointers, []);
  assert.equal(bounded?.drop, "trivial");

  assert.equal(report?.kind, "record");
  assert.deepEqual(
    report?.fields.map(({ name, type }) => ({ name, type })),
    [
      { name: "identity", type: "Text" },
      { name: "samples", type: "BoundedList[Int, 64]" },
      { name: "count", type: "Int" },
    ],
  );

  for (const field of report.fields) {
    assert.equal(
      asserted(
        emitted,
        `offsetof(KofunRecord_BridgeReport, f_${field.name})`,
      ),
      field.offset,
      `${field.name} offset disagrees with AggregateLayout v1`,
    );
  }
  assert.equal(
    asserted(emitted, "sizeof(KofunRecord_BridgeReport)"),
    report.size,
    "BridgeReport size disagrees with AggregateLayout v1",
  );
  assert.equal(
    report.fields.find(({ name }) => name === "samples")?.size,
    bounded.size,
    "BridgeReport samples field does not use the bounded-list carrier",
  );
  assert.deepEqual(report.pointers, ["0"]);

  console.log(
    "PASS: AggregateLayout v1 independently matches every BridgeReport field offset and its record size",
  );
} catch (error) {
  console.error(`aggregate-bridge layout: ${error.message}`);
  process.exitCode = 1;
}

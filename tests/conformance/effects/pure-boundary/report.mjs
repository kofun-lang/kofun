#!/usr/bin/env node

// One line per function: name and the inferred `effect` summary, from the
// typed sidecar of a program the boundary accepted.
//
// There is no column for the annotation. #1245 asks for a published boundary
// fact and typed-sidecar v1 cannot carry one: every route to it — a fact kind,
// a public reason, a node kind — passes through a file
// `spec/concurrency/scoped-captures-v1/v1.sha256` freezes, and §10 of that
// contract says no v1 file is extended in place. So what this report proves is
// the criterion that does hold: an accepted annotated function keeps exactly
// one `pure` effect fact, and an unannotated function that reaches the root is
// still inferred `io` rather than refused.

import fs from "node:fs";

function fail(message) {
  process.stderr.write(`pure boundary report: ${message}\n`);
  process.exit(1);
}

if (process.argv.length !== 4) fail("usage: report.mjs SIDECAR SOURCE");

const sidecar = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const source = fs.readFileSync(process.argv[3], "utf8");
const functions = sidecar.nodes.filter((node) =>
  node.kind === "function.declaration");
if (functions.length === 0) fail("sidecar declares no functions");

function functionName(node) {
  const declaration = source.slice(node.span.start, node.span.end);
  const match = /\bfn\s+([\p{L}_][\p{L}\p{N}_]*)/u.exec(declaration);
  if (!match) {
    fail(`function span ${node.span.start}..${node.span.end} has no name`);
  }
  return match[1];
}

const rows = functions.map((node) => {
  const name = functionName(node);
  if (!node.effect || node.effect.status !== "validated" ||
      !["pure", "io"].includes(node.effect.display)) {
    fail(`function ${name} has no unique validated effect`);
  }
  // The v1 node object is closed, so an extra fact slot cannot appear without
  // the schema admitting it. Asserting that here keeps this report honest if
  // one ever does: the expected file below would stop describing the document.
  const slots = Object.keys(node).filter((key) => key.startsWith("effect"));
  if (slots.length !== 1 || slots[0] !== "effect") {
    fail(`function ${name} carries unexpected effect slots: ${slots.join(",")}`);
  }
  return { effect: node.effect.display, name };
}).sort((left, right) => left.name.localeCompare(right.name, "en"));

if (new Set(rows.map((row) => row.name)).size !== rows.length) {
  fail("function names are not unique");
}

process.stdout.write(
  rows.map((row) => `${row.name}|${row.effect}`).join("\n") + "\n",
);

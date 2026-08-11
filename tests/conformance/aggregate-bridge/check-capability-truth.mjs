#!/usr/bin/env node

import fs from "node:fs";

const [manifestPath] = process.argv.slice(2);
if (manifestPath === undefined) {
  throw new Error("usage: check-capability-truth.mjs CAPABILITIES_TSV");
}

const expectedReasons = new Map([
  [
    "list",
    "The Stage 2 C11 Core supports capacity-64 List[Int] locals, direct signatures, and nominal record fields and field reads; general List[T], List[Text], growth, heap-backed lists, and nested aggregate lowering remain unsupported",
  ],
  [
    "text",
    "The Stage 2 C11 Core supports Text literals, direct parameters and results, UTF-8 output, and Text fields and field reads in the bounded nominal-record bridge; the general Text corpus remains unsupported",
  ],
]);

const oldFalseWording = new Map([
  ["list", "general lists and record fields remain unsupported"],
  ["text", "does not lower Text values in this backend profile"],
]);

function fail(message) {
  throw new Error(message);
}

try {
  const lines = fs.readFileSync(manifestPath, "utf8").split("\n");
  const rows = lines.slice(1).filter((line) => line !== "" && !line.startsWith("#"))
    .map((line, index) => {
      const fields = line.split("\t");
      if (fields.length !== 5) fail(`row ${index + 2} is not five tab-separated fields`);
      const [backend, corpus, state, evidence, reason] = fields;
      return { backend, corpus, state, evidence, reason };
    });

  for (const [corpus, expectedReason] of expectedReasons) {
    const matches = rows.filter((row) =>
      row.backend === "c11-stage2" && row.corpus === corpus);
    if (matches.length !== 1) {
      fail(`c11-stage2 ${corpus} must have exactly one capability row`);
    }
    const row = matches[0];
    const falseWording = oldFalseWording.get(corpus);
    if (row.reason.includes(falseWording)) {
      fail(`c11-stage2 ${corpus} repeats the old false wording: ${falseWording}`);
    }
    if (row.state !== "unsupported") {
      fail(`c11-stage2 ${corpus} must remain unsupported for the general profile, got ${row.state}`);
    }
    if (row.evidence !== "-") {
      fail(`c11-stage2 ${corpus} unsupported row must retain '-' evidence`);
    }
    if (row.reason !== expectedReason) {
      fail(`c11-stage2 ${corpus} bounded-slice note drifted: ${row.reason}`);
    }
  }

  console.log(
    "PASS: c11-stage2 list/Text notes enumerate the bounded bridge while both general profiles remain unsupported",
  );
} catch (error) {
  console.error(`aggregate-bridge capability truth: ${error.message}`);
  process.exitCode = 1;
}

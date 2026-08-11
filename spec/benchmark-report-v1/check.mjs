#!/usr/bin/env node

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { validateAgainstSchema } from "../../tests/lib/json-schema.mjs";
import {
  COMPARISON_VECTOR_SCHEMA,
  ERROR_CODES,
  ERROR_VOCABULARY,
  LIMITS,
  NEGATIVE_VECTOR_SCHEMA,
  REPORT_SCHEMA,
  STAGE2_REPORT_FIELDS,
  STAGE2_STATUS_TAGS,
  STAGE2_VALUE_TAGS,
} from "./contract.mjs";
import {
  applyReportBytePlan,
  ReportError,
  compareReports,
  decodeReport,
  encodeReport,
  fromStage2Outcome,
  joinSegmentedSeries,
  outlierFlags,
  reportBytePlan,
  segmentSeries,
  stage2ErrorOutcome,
  summarize,
  toStage2Outcome,
  validateReport,
} from "./model.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");
const POSITIVE = path.join(HERE, "vectors", "positive");
const NEGATIVE = path.join(HERE, "vectors", "negative.json");
const COMPARISON = path.join(HERE, "vectors", "comparison.json");
const SCHEMA = path.join(HERE, "kofun.bench-report.v1.schema.json");

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function expectReportError(label, code, operation) {
  try {
    operation();
  } catch (error) {
    assert.ok(error instanceof ReportError, `${label}: expected ReportError, got ${error}`);
    assert.equal(error.code, code, `${label}: wrong error code`);
    return error;
  }
  assert.fail(`${label}: expected ${code}`);
}

function replaceOnce(bytes, search, replacement, label) {
  const needle = Buffer.from(search, "utf8");
  const first = bytes.indexOf(needle);
  assert.notEqual(first, -1, `${label}: search bytes are absent`);
  assert.equal(bytes.indexOf(needle, first + needle.length), -1, `${label}: search bytes are not unique`);
  return Buffer.concat([bytes.subarray(0, first), replacement, bytes.subarray(first + needle.length)]);
}

function materializeNegative(vector) {
  const basePath = path.join(POSITIVE, vector.base);
  const bytes = fs.readFileSync(basePath);
  if (vector.operation === "prepend-hex") {
    return Buffer.concat([Buffer.from(vector.hex, "hex"), bytes]);
  }
  if (vector.operation === "append-hex") {
    return Buffer.concat([bytes, Buffer.from(vector.hex, "hex")]);
  }
  if (vector.operation === "replace-hex") {
    return replaceOnce(bytes, vector.search, Buffer.from(vector.hex, "hex"), vector.name);
  }
  if (vector.operation === "replace") {
    return replaceOnce(bytes, vector.search, Buffer.from(vector.replacement, "utf8"), vector.name);
  }
  if (vector.operation === "truncate") {
    assert.ok(vector.count > 0 && vector.count < bytes.length, `${vector.name}: invalid truncation`);
    return bytes.subarray(0, bytes.length - vector.count);
  }
  if (vector.operation === "insert-before-root-close") {
    assert.ok(bytes.subarray(-2).equals(Buffer.from("}\n")), `${vector.name}: base has no canonical root close`);
    return Buffer.concat([
      bytes.subarray(0, -2),
      Buffer.from(vector.replacement, "utf8"),
      Buffer.from("}\n"),
    ]);
  }
  if (vector.operation === "repeat-replacement") {
    const replacement = `${vector.prefix}${vector.unit.repeat(vector.count)}${vector.suffix}`;
    return replaceOnce(bytes, vector.search, Buffer.from(replacement, "utf8"), vector.name);
  }
  if (vector.operation === "insert-nested-unknown") {
    assert.ok(Number.isInteger(vector.depth) && vector.depth > 0, `${vector.name}: invalid depth`);
    assert.ok(bytes.subarray(-2).equals(Buffer.from("}\n")), `${vector.name}: base has no canonical root close`);
    const nested = `${"[".repeat(vector.depth)}0${"]".repeat(vector.depth)}`;
    return Buffer.concat([
      bytes.subarray(0, -2),
      Buffer.from(`,"future":${nested}}\n`, "utf8"),
    ]);
  }
  assert.fail(`${vector.name}: unknown operation ${vector.operation}`);
}

function oneSample(base, sample, direction) {
  const report = structuredClone(base);
  report.identity.direction = direction;
  report.budget.sample_cap = 1;
  report.measurement.sample_count = 1;
  report.measurement.sampling_stop = "sample-cap";
  report.samples = [sample];
  report.outliers = [false];
  report.summary = { ...summarize(report.samples) };
  return report;
}

function independentSummary(values) {
  const raw = values.map((value) => BigInt(value));
  const sorted = [...raw].sort((left, right) => left < right ? -1 : (left > right ? 1 : 0));
  const rank = (numerator, denominator) =>
    sorted[Math.ceil((numerator * sorted.length) / denominator) - 1];
  const median = rank(1, 2);
  const deviations = raw
    .map((value) => value < median ? median - value : value - median)
    .sort((left, right) => left < right ? -1 : (left > right ? 1 : 0));
  const p25 = rank(1, 4);
  const p75 = rank(3, 4);
  const threeIqr = 3n * (p75 - p25);
  return {
    summary: {
      minimum: Number(sorted[0]),
      maximum: Number(sorted.at(-1)),
      median: Number(median),
      p25: Number(p25),
      p75: Number(p75),
      median_absolute_deviation: Number(deviations[Math.ceil(deviations.length / 2) - 1]),
    },
    outliers: raw.map((value) =>
      (value < p25 && 2n * (p25 - value) > threeIqr) ||
      (value > p75 && 2n * (value - p75) > threeIqr)),
  };
}

const positiveNames = fs.readdirSync(POSITIVE).filter((name) => name.endsWith(".json")).sort();
assert.deepEqual(positiveNames, ["maximum.json", "minimal.json", "typical.json"]);
const schema = JSON.parse(fs.readFileSync(SCHEMA, "utf8"));
assert.equal(schema.properties.schema.const, REPORT_SCHEMA);
assert.equal(schema.properties.samples.maxItems, LIMITS.samples);
assert.equal(schema.$defs.nonnegativeInteger.maximum, LIMITS.integer);
assert.equal(LIMITS.jsonDepth, 16);

const positives = new Map();
for (const name of positiveNames) {
  const bytes = fs.readFileSync(path.join(POSITIVE, name));
  assert.ok(bytes.length <= LIMITS.wireBytes, `${name}: positive vector exceeds the wire limit`);
  const report = decodeReport(bytes);
  assert.ok(encodeReport(report).equals(bytes), `${name}: decode/encode changed canonical bytes`);
  const parsed = JSON.parse(bytes.toString("utf8"));
  const schemaErrors = [];
  validateAgainstSchema(schema, schema, parsed, "$", schemaErrors);
  assert.deepEqual(schemaErrors, [], `${name}: JSON Schema disagreement`);
  positives.set(name, report);
}

const minimal = positives.get("minimal.json");
const typical = positives.get("typical.json");
const maximum = positives.get("maximum.json");
assert.equal(Object.hasOwn(minimal.identity, "parameter"), false, "minimal optional parameter must be omitted");
assert.equal(typical.identity.parameter, "café-サイズ大", "present optional parameter drifted");
assert.deepEqual(typical.samples, [41, 7, 19, 3, 23, 11, 29, 17], "raw order was repaired");
assert.deepEqual(typical.outliers, outlierFlags(typical.samples));
assert.deepEqual(typical.summary, {
  minimum: 3,
  maximum: 41,
  median: 17,
  p25: 7,
  p75: 23,
  median_absolute_deviation: 6,
});
assert.deepEqual(outlierFlags([0, 2, 4, 6, 12]), [false, false, false, false, false]);
assert.deepEqual(outlierFlags([0, 2, 4, 6, 13]), [false, false, false, false, true]);
assert.deepEqual(outlierFlags([2, 8, 10, 12, 14]), [false, false, false, false, false]);
assert.deepEqual(outlierFlags([1, 8, 10, 12, 14]), [true, false, false, false, false]);
assert.deepEqual(typical.counters.allocated_bytes, { state: "available", value: 0 });
assert.deepEqual(typical.counters.gc_collections, { state: "unavailable" });
assert.equal(maximum.samples.length, 100);
assert.equal(maximum.samples[99], LIMITS.integer);
assert.ok(
  fs.statSync(path.join(POSITIVE, "maximum.json")).size > 4096,
  "maximum positive vector no longer crosses the 4-KiB implementation trap",
);
assert.equal(maximum.outliers.filter(Boolean).length, 1, "maximum vector lost its strict outlier boundary");
assert.equal(Buffer.byteLength(maximum.identity.suite, "utf8"), LIMITS.identityBytes);
assert.equal(Buffer.byteLength(maximum.host.os, "utf8"), LIMITS.hostTextBytes);
assert.equal(Buffer.byteLength(maximum.host.affinity.value, "utf8"), LIMITS.hostTextBytes);

let deterministicState = 0x6d2b79f5;
const deterministicWord = () => {
  deterministicState ^= deterministicState << 13;
  deterministicState ^= deterministicState >>> 17;
  deterministicState ^= deterministicState << 5;
  return deterministicState >>> 0;
};
for (let count = 1; count <= LIMITS.samples; count += 1) {
  const values = Array.from({ length: count }, (_, index) => {
    if (index === 0 && count % 3 === 0) return 0;
    if (index === count - 1 && count % 5 === 0) return LIMITS.integer;
    return deterministicWord();
  });
  const expected = independentSummary(values);
  assert.deepEqual(summarize(values), expected.summary, `independent summary mismatch at n=${count}`);
  assert.deepEqual(outlierFlags(values), expected.outliers, `independent outliers mismatch at n=${count}`);
}

function schemaErrorsFor(value) {
  const errors = [];
  validateAgainstSchema(schema, schema, value, "$", errors);
  return errors;
}

function expectSchemaAndModelReject(label, mutate) {
  const value = structuredClone(typical);
  mutate(value);
  assert.notEqual(schemaErrorsFor(value).length, 0, `${label}: JSON Schema accepted mutation`);
  assert.throws(
    () => validateReport(value),
    (error) => error instanceof ReportError,
    `${label}: executable model accepted mutation`,
  );
}

for (const [label, mutate] of [
  ["missing root field", (value) => { delete value.clock; }],
  ["unknown root field", (value) => { value.future = 0; }],
  ["unknown clock enum", (value) => { value.clock = "realtime"; }],
  ["missing identity field", (value) => { delete value.identity.case; }],
  ["unknown identity field", (value) => { value.identity.future = 0; }],
  ["wrong identity primitive", (value) => { value.identity.suite = 1; }],
  ["empty identity minimum", (value) => { value.identity.suite = ""; }],
  ["identity maximum one-over", (value) => { value.identity.suite = "x".repeat(LIMITS.identityBytes + 1); }],
  ["unknown direction enum", (value) => { value.identity.direction = "neutral"; }],
  ["unknown budget field", (value) => { value.budget.future = 0; }],
  ["wrong budget object", (value) => { value.budget = []; }],
  ["budget one-over", (value) => { value.budget.warmup_cap_ns = LIMITS.warmupCapNs + 1; }],
  ["budget minimum one-under", (value) => { value.budget.sampling_cap_ns = 0; }],
  ["missing measurement field", (value) => { delete value.measurement.sample_count; }],
  ["wrong measurement primitive", (value) => { value.measurement.sample_count = "8"; }],
  ["positive integer minimum", (value) => { value.measurement.iterations_per_sample = 0; }],
  ["wrong samples container", (value) => { value.samples = {}; }],
  ["wrong sample primitive", (value) => { value.samples[0] = "41"; }],
  ["nonnegative integer maximum", (value) => { value.samples[0] = LIMITS.integer + 1; }],
  ["empty samples minimum", (value) => { value.samples = []; }],
  ["sample count one-over", (value) => { value.samples = Array(LIMITS.samples + 1).fill(0); }],
  ["wrong outlier primitive", (value) => { value.outliers[0] = 0; }],
  ["missing summary field", (value) => { delete value.summary.median; }],
  ["unknown summary field", (value) => { value.summary.future = 0; }],
  ["missing counter", (value) => { delete value.counters.cpu_cycles; }],
  ["unknown counter", (value) => { value.counters.future = { state: "unavailable" }; }],
  ["unavailable counter payload", (value) => {
    value.counters.gc_collections = { state: "unavailable", value: 0 };
  }],
  ["available counter missing payload", (value) => {
    value.counters.allocated_bytes = { state: "available" };
  }],
  ["unknown availability state", (value) => {
    value.counters.allocated_bytes = { state: "unknown" };
  }],
  ["missing digest", (value) => { delete value.digests.source_sha256; }],
  ["wrong digest primitive", (value) => { value.digests.source_sha256 = 0; }],
  ["short digest pattern", (value) => { value.digests.source_sha256 = "b".repeat(63); }],
  ["uppercase digest pattern", (value) => { value.digests.source_sha256 = "B".repeat(64); }],
  ["missing host field", (value) => { delete value.host.cpu; }],
  ["unknown host field", (value) => { value.host.future = 0; }],
  ["wrong host object", (value) => { value.host = "host"; }],
  ["host Text maximum one-over", (value) => { value.host.cpu = "x".repeat(LIMITS.hostTextBytes + 1); }],
  ["noise maximum one-over", (value) => { value.host.noise = "x".repeat(LIMITS.noteBytes + 1); }],
  ["unavailable affinity payload", (value) => {
    value.host.affinity = { state: "unavailable", value: "0" };
  }],
  ["available affinity empty payload", (value) => {
    value.host.affinity = { state: "available", value: "" };
  }],
]) expectSchemaAndModelReject(label, mutate);

const segmented = segmentSeries(maximum.samples, maximum.outliers);
assert.equal(segmented.sample_segment0.length, 64);
assert.equal(segmented.sample_segment1.length, 36);
assert.deepEqual(joinSegmentedSeries(segmented), {
  samples: maximum.samples,
  outliers: maximum.outliers,
});
expectReportError("noncanonical segment split", ERROR_CODES.invalidInvariant, () =>
  joinSegmentedSeries({
    ...segmented,
    sample_segment0: segmented.sample_segment0.slice(0, 63),
    sample_segment1: [segmented.sample_segment0[63], ...segmented.sample_segment1],
  }),
);
expectReportError("non-Boolean flag carrier", ERROR_CODES.invalidInvariant, () =>
  joinSegmentedSeries({ ...segmented, flag_segment1: [...segmented.flag_segment1.slice(0, -1), 2] }),
);

assert.equal(STAGE2_REPORT_FIELDS.length, 49, "flat Stage 2 outcome field count drifted");
assert.equal(new Set(STAGE2_REPORT_FIELDS.map(({ name }) => name)).size, STAGE2_REPORT_FIELDS.length);
assert.deepEqual(
  [...new Set(STAGE2_REPORT_FIELDS.map(({ type }) => type))].sort(),
  ["Bool", "Int", "List[Int]", "Text"],
  "Stage 2 outcome escaped the current flat record field slice",
);
assert.deepEqual(
  STAGE2_REPORT_FIELDS.filter(({ type }) => type === "List[Int]").map(({ name }) => name),
  ["sample_segment0", "sample_segment1", "outlier_segment0", "outlier_segment1"],
);
for (const [family, tags] of Object.entries(STAGE2_VALUE_TAGS)) {
  assert.equal(new Set(Object.values(tags)).size, Object.keys(tags).length, `${family}: duplicate physical tag`);
}
for (const report of positives.values()) {
  assert.deepEqual(fromStage2Outcome(toStage2Outcome(report)), { kind: "report", report });
}
for (const code of ERROR_VOCABULARY) {
  assert.equal(STAGE2_STATUS_TAGS[code], Number(code.slice(2)), `${code}: physical status tag drifted`);
  assert.deepEqual(fromStage2Outcome(stage2ErrorOutcome(code)), { kind: "error", code });
}
const partialError = { ...stage2ErrorOutcome(ERROR_CODES.cancelled), suite: "partial" };
expectReportError("partial Stage 2 error outcome", ERROR_CODES.invalidInvariant, () =>
  fromStage2Outcome(partialError),
);
for (const [type, field, value] of [
  ["Int", "warmup_cap_ns", 1],
  ["Bool", "parameter_present", true],
  ["List[Int]", "sample_segment0", [0]],
]) {
  const partial = { ...stage2ErrorOutcome(ERROR_CODES.cancelled), [field]: value };
  expectReportError(`partial Stage 2 ${type} error outcome`, ERROR_CODES.invalidInvariant, () =>
    fromStage2Outcome(partial),
  );
}
const unknownStage2Status = { ...stage2ErrorOutcome(ERROR_CODES.cancelled), status_tag: 13 };
expectReportError("unknown Stage 2 status", ERROR_CODES.invalidInvariant, () =>
  fromStage2Outcome(unknownStage2Status),
);

const absentParameterPayload = { ...toStage2Outcome(minimal), parameter: "ghost" };
expectReportError("absent Stage 2 parameter with payload", ERROR_CODES.invalidInvariant, () =>
  fromStage2Outcome(absentParameterPayload),
);
for (const [label, available, payload, value] of [
  ["Text availability", "host_affinity_available", "host_affinity", "0"],
  ["Int availability", "host_frequency_hz_available", "host_frequency_hz", 1],
  ["counter availability", "gc_collections_available", "gc_collections_value", 1],
]) {
  const physical = { ...toStage2Outcome(minimal), [available]: false, [payload]: value };
  expectReportError(`non-neutral unavailable Stage 2 ${label}`, ERROR_CODES.invalidInvariant, () =>
    fromStage2Outcome(physical),
  );
}

const nestedAtLimit = materializeNegative({
  name: "json-depth-16-boundary",
  base: "minimal.json",
  operation: "insert-nested-unknown",
  depth: LIMITS.jsonDepth,
});
expectReportError("JSON container depth 16 reaches schema validation", ERROR_CODES.schemaShape, () =>
  decodeReport(nestedAtLimit),
);
const nestedOneOver = materializeNegative({
  name: "json-depth-17-boundary",
  base: "minimal.json",
  operation: "insert-nested-unknown",
  depth: LIMITS.jsonDepth + 1,
});
expectReportError("JSON container depth 17", ERROR_CODES.limitExceeded, () =>
  decodeReport(nestedOneOver),
);
const deeplyNestedWithinWire = materializeNegative({
  name: "json-depth-near-wire-boundary",
  base: "minimal.json",
  operation: "insert-nested-unknown",
  depth: 7000,
});
assert.ok(deeplyNestedWithinWire.length <= LIMITS.wireBytes, "deep nesting probe escaped the wire bound");
expectReportError("deep JSON nesting terminates with the typed limit", ERROR_CODES.limitExceeded, () =>
  decodeReport(deeplyNestedWithinWire),
);
const duplicateAndTooDeep = replaceOnce(
  nestedOneOver,
  "\"schema\":\"kofun.bench-report/v1\",\"identity\"",
  Buffer.from(
    "\"schema\":\"kofun.bench-report/v1\",\"schema\":\"kofun.bench-report/v1\",\"identity\"",
    "utf8",
  ),
  "duplicate plus excessive depth",
);
expectReportError("depth precedes decoded duplicate", ERROR_CODES.limitExceeded, () =>
  decodeReport(duplicateAndTooDeep),
);
const unknownRoot = materializeNegative({
  name: "unknown-root-precedence",
  base: "minimal.json",
  operation: "insert-before-root-close",
  replacement: ",\"future\":0",
});
const noncanonicalUnknownRoot = replaceOnce(
  unknownRoot,
  "{\"schema\"",
  Buffer.from("{ \"schema\"", "utf8"),
  "noncanonical unknown root",
);
expectReportError("semantic validation precedes canonical mismatch", ERROR_CODES.schemaShape, () =>
  decodeReport(noncanonicalUnknownRoot),
);

const negativeManifest = JSON.parse(fs.readFileSync(NEGATIVE, "utf8"));
assert.equal(negativeManifest.schema, NEGATIVE_VECTOR_SCHEMA);
assert.equal(negativeManifest.vectors.length, 44, "negative corpus count drifted");
assert.equal(new Set(negativeManifest.vectors.map(({ name }) => name)).size, negativeManifest.vectors.length);
assert.deepEqual(
  [...new Set(negativeManifest.vectors.map(({ error }) => error))].sort(),
  ERROR_VOCABULARY.slice(0, 6),
  "byte/schema/invariant negative error families drifted",
);
const printDigests = process.argv.includes("--print-negative-digests");
for (const vector of negativeManifest.vectors) {
  assert.ok(ERROR_VOCABULARY.includes(vector.error), `${vector.name}: unknown error ${vector.error}`);
  const bytes = materializeNegative(vector);
  const digest = sha256(bytes);
  if (printDigests) process.stdout.write(`${vector.name}\t${digest}\n`);
  else assert.equal(digest, vector.sha256, `${vector.name}: derived bytes drifted`);
  expectReportError(vector.name, vector.error, () => decodeReport(bytes));
}

const comparisonManifest = JSON.parse(fs.readFileSync(COMPARISON, "utf8"));
assert.equal(comparisonManifest.schema, COMPARISON_VECTOR_SCHEMA);
assert.equal(comparisonManifest.vectors.length, 13, "comparison boundary count drifted");
assert.equal(new Set(comparisonManifest.vectors.map(({ name }) => name)).size, comparisonManifest.vectors.length);
assert.deepEqual(
  [...new Set(comparisonManifest.vectors.flatMap(({ error }) => error === undefined ? [] : [error]))],
  [ERROR_CODES.arithmeticOverflow],
);
for (const vector of comparisonManifest.vectors) {
  const baseline = oneSample(minimal, vector.baseline, vector.direction);
  const candidate = oneSample(minimal, vector.candidate, vector.direction);
  if (vector.error !== undefined) {
    expectReportError(vector.name, vector.error, () =>
      compareReports(baseline, candidate, vector.threshold_bps),
    );
  } else {
    assert.deepEqual(
      compareReports(baseline, candidate, vector.threshold_bps),
      vector.expected,
      `${vector.name}: comparison drifted`,
    );
  }
}

const availableCandidate = structuredClone(typical);
availableCandidate.counters.gc_collections = { state: "available", value: 9 };
assert.deepEqual(
  compareReports(typical, availableCandidate, 0),
  { kind: "comparable", verdict: "equivalent", change_bps: 0, threshold_bps: 0 },
  "counter availability must not enter duration comparison",
);
const environmentCandidate = structuredClone(typical);
environmentCandidate.digests.artifact_sha256 = "9".repeat(64);
environmentCandidate.host.host_id_sha256 = "8".repeat(64);
environmentCandidate.host.cpu = "different fixture CPU";
assert.deepEqual(
  compareReports(typical, environmentCandidate, 0),
  { kind: "comparable", verdict: "equivalent", change_bps: 0, threshold_bps: 0 },
  "digests and host metadata must not make duration reports incompatible",
);
const incompatible = structuredClone(typical);
incompatible.identity.parameter = "different";
expectReportError("comparison identity mismatch", ERROR_CODES.incompatibleComparison, () =>
  compareReports(typical, incompatible, 0),
);
for (const [label, mutate] of [
  ["suite", (report) => { report.identity.suite = "another-suite"; }],
  ["case", (report) => { report.identity.case = "another-case"; }],
  ["parameter value", (report) => { report.identity.parameter = "another-parameter"; }],
  ["parameter presence", (report) => { delete report.identity.parameter; }],
  ["metric", (report) => { report.identity.metric = "latency"; }],
  ["direction", (report) => { report.identity.direction = "higher-is-better"; }],
  ["clock", (report) => { report.clock = "wall"; }],
  ["iterations per sample", (report) => { report.measurement.iterations_per_sample += 1; }],
]) {
  const candidate = structuredClone(typical);
  mutate(candidate);
  expectReportError(`comparison ${label} mismatch`, ERROR_CODES.incompatibleComparison, () =>
    compareReports(typical, candidate, 0),
  );
}
const wrongUnit = structuredClone(typical);
wrongUnit.identity.unit = "us";
expectReportError("comparison validates unit before compatibility", ERROR_CODES.schemaShape, () =>
  compareReports(typical, wrongUnit, 0),
);

const allowedBudgetDifference = structuredClone(typical);
allowedBudgetDifference.budget.sampling_cap_ns -= 1;
assert.equal(compareReports(typical, allowedBudgetDifference, 0).kind, "comparable");
const allowedMeasurementDifference = structuredClone(typical);
allowedMeasurementDifference.measurement.harness_overhead_ns += 1;
assert.equal(compareReports(typical, allowedMeasurementDifference, 0).kind, "comparable");
const allowedRawOrderDifference = structuredClone(typical);
allowedRawOrderDifference.samples.reverse();
allowedRawOrderDifference.outliers.reverse();
assert.equal(compareReports(typical, allowedRawOrderDifference, 0).kind, "comparable");
const allowedSeriesDifference = oneSample(typical, 17, typical.identity.direction);
assert.equal(compareReports(typical, allowedSeriesDifference, 0).kind, "comparable");
expectReportError("negative threshold", ERROR_CODES.invalidThreshold, () =>
  compareReports(typical, typical, -1),
);
for (const [label, threshold] of [
  ["threshold one-over", LIMITS.thresholdBps + 1],
  ["fractional threshold", 0.5],
  ["NaN threshold", Number.NaN],
]) {
  expectReportError(label, ERROR_CODES.invalidThreshold, () =>
    compareReports(typical, typical, threshold),
  );
}
const invalidComparisonCandidate = structuredClone(typical);
invalidComparisonCandidate.samples = [];
expectReportError("candidate validation precedes invalid threshold", ERROR_CODES.invalidInvariant, () =>
  compareReports(typical, invalidComparisonCandidate, -1),
);
expectReportError("invalid threshold precedes compatibility", ERROR_CODES.invalidThreshold, () =>
  compareReports(typical, incompatible, -1),
);

const success = reportBytePlan("success", typical);
assert.equal(success.kind, "complete");
assert.ok(success.bytes.equals(encodeReport(typical)), "success did not expose the complete canonical buffer");
assert.deepEqual(reportBytePlan("failed"), { kind: "no-bytes", code: ERROR_CODES.measurementFailed });
assert.deepEqual(reportBytePlan("cancelled"), { kind: "no-bytes", code: ERROR_CODES.cancelled });
assert.deepEqual(
  reportBytePlan("output-failed"),
  { kind: "no-bytes", code: ERROR_CODES.outputFailed },
);
const previousDestination = Buffer.from("previous destination\n", "utf8");
assert.ok(applyReportBytePlan(previousDestination, success).equals(success.bytes));
for (const outcome of ["failed", "cancelled", "output-failed"]) {
  const plan = reportBytePlan(outcome);
  assert.equal("bytes" in plan, false, `${outcome}: typed non-success exposed report bytes`);
  assert.ok(
    applyReportBytePlan(previousDestination, plan).equals(previousDestination),
    `${outcome}: typed non-success changed the destination`,
  );
}

const oversizedIdentity = structuredClone(typical);
oversizedIdentity.identity.suite = "x".repeat(LIMITS.identityBytes + 1);
expectReportError("identity byte one-over", ERROR_CODES.limitExceeded, () => encodeReport(oversizedIdentity));
const oversizedNote = structuredClone(typical);
oversizedNote.host.noise = "x".repeat(LIMITS.noteBytes + 1);
expectReportError("note byte one-over", ERROR_CODES.limitExceeded, () => encodeReport(oversizedNote));
const boundaryNote = structuredClone(typical);
boundaryNote.host.noise = "x".repeat(LIMITS.noteBytes);
assert.equal(decodeReport(encodeReport(boundaryNote)).host.noise.length, LIMITS.noteBytes);
const inconsistentWarmup = structuredClone(typical);
inconsistentWarmup.measurement.warmup_iterations = 0;
expectReportError("non-disabled zero warmup", ERROR_CODES.invalidInvariant, () => encodeReport(inconsistentWarmup));
const disabledWithBudget = structuredClone(minimal);
disabledWithBudget.budget.warmup_cap_ns = 1;
expectReportError("disabled warmup with nonzero cap", ERROR_CODES.invalidInvariant, () =>
  encodeReport(disabledWithBudget),
);
const decomposedIdentity = structuredClone(typical);
decomposedIdentity.identity.parameter = "cafe\u0301-サイズ大";
assert.equal(
  decodeReport(encodeReport(decomposedIdentity)).identity.parameter,
  decomposedIdentity.identity.parameter,
  "Text normalization changed scalar-exact report identity",
);

const spec = fs.readFileSync(path.join(ROOT, "spec", "benchmark-report-v1.md"), "utf8");
for (const phrase of [
  "64+36",
  "16,384",
  "one trailing LF",
  "away from zero",
  "Generic `stdlib/json` is not a dependency",
  "No live runner",
]) {
  assert.ok(spec.includes(phrase), `normative profile omitted ${phrase}`);
}

if (!printDigests) {
  process.stdout.write(
    "PASS: benchmark-report v1 canonical schema, bounds, summaries, and 100-sample segmentation\n" +
    "PASS: positive/negative bytes, availability states, typed non-success output outcomes, and comparison boundaries\n",
  );
}

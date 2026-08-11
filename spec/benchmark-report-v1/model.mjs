#!/usr/bin/env node

import fs from "node:fs";
import { pathToFileURL } from "node:url";

import {
  BUDGET_FIELDS,
  CLOCKS,
  COUNTER_NAMES,
  DIGEST_FIELDS,
  DIRECTIONS,
  ERROR_CODES,
  ERROR_VOCABULARY,
  HOST_FIELDS,
  IDENTITY_FIELDS,
  LIMITS,
  MEASUREMENT_FIELDS,
  REPORT_SCHEMA,
  ROOT_FIELDS,
  SAMPLING_STOPS,
  STAGE2_REPORT_FIELDS,
  STAGE2_STATUS_TAGS,
  STAGE2_VALUE_TAGS,
  SUMMARY_FIELDS,
  WARMUP_STOPS,
} from "./contract.mjs";

const UTF8 = new TextDecoder("utf-8", { fatal: true });
const HEX_64 = /^[0-9a-f]{64}$/u;

export class ReportError extends Error {
  constructor(code, path, detail) {
    super(`${code} at ${path}: ${detail}`);
    this.code = code;
    this.path = path;
    this.detail = detail;
  }
}

function reject(code, path, detail) {
  throw new ReportError(code, path, detail);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function object(value, path) {
  if (!isObject(value)) reject(ERROR_CODES.schemaShape, path, "expected object");
  return value;
}

function exactKeys(value, fields, path, optional = new Set()) {
  const allowed = new Set(fields);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) reject(ERROR_CODES.schemaShape, `${path}.${key}`, "unknown field");
  }
  for (const key of fields) {
    if (!optional.has(key) && !Object.hasOwn(value, key)) {
      reject(ERROR_CODES.schemaShape, path, `missing field ${key}`);
    }
  }
}

function hasDuplicateJsonKey(text) {
  let at = 0;
  let duplicate = false;
  const whitespace = () => {
    while (/\s/u.test(text[at] ?? "")) at += 1;
  };
  const string = () => {
    const start = at;
    at += 1;
    while (at < text.length) {
      if (text[at] === "\\") at += 2;
      else if (text[at] === "\"") {
        at += 1;
        return JSON.parse(text.slice(start, at));
      } else at += 1;
    }
    return "";
  };
  const value = (depth = 0) => {
    whitespace();
    if ((text[at] === "{" || text[at] === "[") && depth > LIMITS.jsonDepth) {
      reject(ERROR_CODES.limitExceeded, "$bytes", `JSON nesting exceeds ${LIMITS.jsonDepth}`);
    }
    if (text[at] === "{") {
      at += 1;
      whitespace();
      const keys = new Set();
      if (text[at] === "}") {
        at += 1;
        return;
      }
      while (at < text.length) {
        const key = string();
        if (keys.has(key)) duplicate = true;
        keys.add(key);
        whitespace();
        at += 1;
        value(depth + 1);
        whitespace();
        if (text[at] === "}") {
          at += 1;
          return;
        }
        at += 1;
        whitespace();
      }
      return;
    }
    if (text[at] === "[") {
      at += 1;
      whitespace();
      if (text[at] === "]") {
        at += 1;
        return;
      }
      while (at < text.length) {
        value(depth + 1);
        whitespace();
        if (text[at] === "]") {
          at += 1;
          return;
        }
        at += 1;
      }
      return;
    }
    if (text[at] === "\"") {
      string();
      return;
    }
    while (at < text.length && !/[\s,}\]]/u.test(text[at])) at += 1;
  };
  value();
  return duplicate;
}

function integer(
  value,
  path,
  minimum = 0,
  maximum = LIMITS.integer,
  upperError = ERROR_CODES.limitExceeded,
) {
  if (typeof value !== "number") reject(ERROR_CODES.schemaShape, path, "expected integer");
  if (!Number.isFinite(value)) {
    reject(ERROR_CODES.limitExceeded, path, "expected a finite exactly representable integer");
  }
  if (!Number.isInteger(value)) reject(ERROR_CODES.schemaShape, path, "expected integer");
  if (!Number.isSafeInteger(value)) {
    reject(ERROR_CODES.limitExceeded, path, "expected an exactly representable integer");
  }
  if (value < minimum) {
    reject(ERROR_CODES.invalidInvariant, path, `expected ${minimum}..${maximum}`);
  }
  if (value > maximum) reject(upperError, path, `expected ${minimum}..${maximum}`);
  return value;
}

function unicodeScalarText(value, path) {
  if (typeof value !== "string") reject(ERROR_CODES.schemaShape, path, "expected Text");
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) {
        reject(ERROR_CODES.invalidIdentity, path, "contains an unpaired surrogate");
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      reject(ERROR_CODES.invalidIdentity, path, "contains an unpaired surrogate");
    }
  }
  return value;
}

function boundedText(value, path, maximumBytes, { empty = false, note = false } = {}) {
  unicodeScalarText(value, path);
  const bytes = Buffer.byteLength(value, "utf8");
  if ((!empty && bytes === 0) || bytes > maximumBytes) {
    reject(ERROR_CODES.limitExceeded, path, `UTF-8 length must be ${empty ? 0 : 1}..${maximumBytes}`);
  }
  for (const character of value) {
    const code = character.codePointAt(0);
    const allowedNoteControl = note && (code === 0x09 || code === 0x0a || code === 0x0d);
    if ((code <= 0x1f || code === 0x7f) && !allowedNoteControl) {
      reject(ERROR_CODES.invalidIdentity, path, "contains a forbidden control character");
    }
  }
  return value;
}

function digest(value, path) {
  if (typeof value !== "string" || !HEX_64.test(value)) {
    reject(ERROR_CODES.invalidIdentity, path, "expected 64 lowercase hexadecimal SHA-256 digits");
  }
  return value;
}

function oneOf(value, values, path) {
  if (!values.includes(value)) {
    reject(ERROR_CODES.schemaShape, path, `expected one of ${values.join(", ")}`);
  }
  return value;
}

function availabilityCounter(value, path) {
  const source = object(value, path);
  if (source.state === "unavailable") {
    exactKeys(source, ["state"], path);
    return Object.freeze({ state: "unavailable" });
  }
  if (source.state === "available") {
    exactKeys(source, ["state", "value"], path);
    return Object.freeze({ state: "available", value: integer(source.value, `${path}.value`) });
  }
  reject(ERROR_CODES.schemaShape, `${path}.state`, "expected available or unavailable");
}

function availabilityText(value, path) {
  const source = object(value, path);
  if (source.state === "unavailable") {
    exactKeys(source, ["state"], path);
    return Object.freeze({ state: "unavailable" });
  }
  if (source.state === "available") {
    exactKeys(source, ["state", "value"], path);
    return Object.freeze({
      state: "available",
      value: boundedText(source.value, `${path}.value`, LIMITS.hostTextBytes),
    });
  }
  reject(ERROR_CODES.schemaShape, `${path}.state`, "expected available or unavailable");
}

export function summarize(samples) {
  if (!Array.isArray(samples) || samples.length < 1 || samples.length > LIMITS.samples) {
    reject(ERROR_CODES.invalidInvariant, "$.samples", `expected 1..${LIMITS.samples} samples`);
  }
  const checked = samples.map((sample, index) => integer(sample, `$.samples[${index}]`));
  const sorted = [...checked].sort((left, right) => left - right);
  const nearestRank = (numerator, denominator) =>
    sorted[Math.ceil((numerator * sorted.length) / denominator) - 1];
  const median = nearestRank(1, 2);
  const deviations = sorted.map((sample) => Math.abs(sample - median)).sort((left, right) => left - right);
  const mad = deviations[Math.ceil(deviations.length / 2) - 1];
  return Object.freeze({
    minimum: sorted[0],
    maximum: sorted.at(-1),
    median,
    p25: nearestRank(1, 4),
    p75: nearestRank(3, 4),
    median_absolute_deviation: mad,
  });
}

export function outlierFlags(samples) {
  const summary = summarize(samples);
  const lower = BigInt(summary.p25);
  const upper = BigInt(summary.p75);
  const threeIqr = 3n * (upper - lower);
  return Object.freeze(samples.map((sample, index) => {
    const value = BigInt(integer(sample, `$.samples[${index}]`));
    return (value < lower && 2n * (lower - value) > threeIqr) ||
      (value > upper && 2n * (value - upper) > threeIqr);
  }));
}

export function segmentSeries(samplesValue, outliersValue) {
  if (!Array.isArray(samplesValue) || !Array.isArray(outliersValue)) {
    reject(ERROR_CODES.schemaShape, "$series", "samples and outliers must be arrays");
  }
  if (samplesValue.length < 1 || samplesValue.length > LIMITS.samples) {
    reject(ERROR_CODES.invalidInvariant, "$series.samples", `expected 1..${LIMITS.samples} values`);
  }
  if (samplesValue.length !== outliersValue.length) {
    reject(ERROR_CODES.invalidInvariant, "$series.outliers", "flags must align one-for-one with samples");
  }
  const samples = samplesValue.map((value, index) => integer(value, `$series.samples[${index}]`));
  const flags = outliersValue.map((value, index) => {
    if (typeof value !== "boolean") reject(ERROR_CODES.schemaShape, `$series.outliers[${index}]`, "expected Boolean");
    return value ? 1 : 0;
  });
  return Object.freeze({
    count: samples.length,
    sample_segment0: Object.freeze(samples.slice(0, LIMITS.segment0Samples)),
    sample_segment1: Object.freeze(samples.slice(LIMITS.segment0Samples)),
    flag_segment0: Object.freeze(flags.slice(0, LIMITS.segment0Samples)),
    flag_segment1: Object.freeze(flags.slice(LIMITS.segment0Samples)),
  });
}

export function joinSegmentedSeries(value) {
  const source = object(value, "$series");
  exactKeys(source, ["count", "sample_segment0", "sample_segment1", "flag_segment0", "flag_segment1"], "$series");
  const count = integer(source.count, "$series.count", 1, LIMITS.samples);
  const checkedSegment = (input, path, maximum, flag = false) => {
    if (!Array.isArray(input)) reject(ERROR_CODES.schemaShape, path, "expected array");
    if (input.length > maximum) reject(ERROR_CODES.invalidInvariant, path, `segment exceeds ${maximum}`);
    return input.map((item, index) => {
      const checked = integer(
        item,
        `${path}[${index}]`,
        0,
        flag ? 1 : LIMITS.integer,
        flag ? ERROR_CODES.invalidInvariant : ERROR_CODES.limitExceeded,
      );
      return checked;
    });
  };
  const sample0 = checkedSegment(source.sample_segment0, "$series.sample_segment0", LIMITS.segment0Samples);
  const sample1 = checkedSegment(source.sample_segment1, "$series.sample_segment1", LIMITS.segment1Samples);
  const flag0 = checkedSegment(source.flag_segment0, "$series.flag_segment0", LIMITS.segment0Samples, true);
  const flag1 = checkedSegment(source.flag_segment1, "$series.flag_segment1", LIMITS.segment1Samples, true);
  if (sample0.length !== flag0.length || sample1.length !== flag1.length) {
    reject(ERROR_CODES.invalidInvariant, "$series", "each flag segment must match its sample segment");
  }
  if (sample0.length + sample1.length !== count) {
    reject(ERROR_CODES.invalidInvariant, "$series.count", "does not equal the two segment lengths");
  }
  if (sample1.length !== 0 && sample0.length !== LIMITS.segment0Samples) {
    reject(ERROR_CODES.invalidInvariant, "$series.sample_segment1", "the second segment starts only after a full first segment");
  }
  return Object.freeze({
    samples: Object.freeze([...sample0, ...sample1]),
    outliers: Object.freeze([...flag0, ...flag1].map((flag) => flag === 1)),
  });
}

function stage2Neutral(type) {
  if (type === "Int") return 0;
  if (type === "Bool") return false;
  if (type === "Text") return "";
  if (type === "List[Int]") return Object.freeze([]);
  throw new Error(`unknown Stage 2 physical type ${type}`);
}

function orderedStage2(values) {
  return Object.freeze(Object.fromEntries(STAGE2_REPORT_FIELDS.map(({ name }) => {
    if (!Object.hasOwn(values, name)) throw new Error(`missing Stage 2 model field ${name}`);
    return [name, values[name]];
  })));
}

export function stage2ErrorOutcome(code) {
  const status = STAGE2_STATUS_TAGS[code];
  if (status === undefined || code === "valid") {
    reject(ERROR_CODES.schemaShape, "$stage2.status_tag", "expected BR001..BR012");
  }
  return orderedStage2(Object.fromEntries(STAGE2_REPORT_FIELDS.map(({ name, type }) => [
    name,
    name === "status_tag" ? status : stage2Neutral(type),
  ])));
}

function taggedName(value, tags, path) {
  const checked = integer(
    value,
    path,
    0,
    Math.max(...Object.values(tags)),
    ERROR_CODES.invalidInvariant,
  );
  const match = Object.entries(tags).find(([, tag]) => tag === checked);
  if (match === undefined) reject(ERROR_CODES.invalidInvariant, path, "unknown closed tag");
  return match[0];
}

function physicalBoolean(value, path) {
  if (typeof value !== "boolean") reject(ERROR_CODES.schemaShape, path, "expected Bool");
  return value;
}

function stage2Availability(availableValue, payload, path, neutral) {
  const available = physicalBoolean(availableValue, `${path}_available`);
  if (!available) {
    if (payload !== neutral) {
      reject(ERROR_CODES.invalidInvariant, path, "unavailable physical payload is not neutral");
    }
    return Object.freeze({ state: "unavailable" });
  }
  return Object.freeze({ state: "available", value: payload });
}

export function toStage2Outcome(value) {
  const report = validateReport(value);
  const segments = segmentSeries(report.samples, report.outliers);
  const values = {
    status_tag: STAGE2_STATUS_TAGS.valid,
    suite: report.identity.suite,
    case: report.identity.case,
    parameter_present: Object.hasOwn(report.identity, "parameter"),
    parameter: report.identity.parameter ?? "",
    metric: report.identity.metric,
    direction_tag: STAGE2_VALUE_TAGS.direction[report.identity.direction],
    clock_tag: STAGE2_VALUE_TAGS.clock[report.clock],
    warmup_cap_ns: report.budget.warmup_cap_ns,
    sampling_cap_ns: report.budget.sampling_cap_ns,
    sample_cap: report.budget.sample_cap,
    warmup_iterations: report.measurement.warmup_iterations,
    warmup_stop_tag: STAGE2_VALUE_TAGS.warmupStop[report.measurement.warmup_stop],
    iterations_per_sample: report.measurement.iterations_per_sample,
    sample_count: report.measurement.sample_count,
    sampling_stop_tag: STAGE2_VALUE_TAGS.samplingStop[report.measurement.sampling_stop],
    harness_overhead_ns: report.measurement.harness_overhead_ns,
    sample_segment0: segments.sample_segment0,
    sample_segment1: segments.sample_segment1,
    outlier_segment0: segments.flag_segment0,
    outlier_segment1: segments.flag_segment1,
    host_id_sha256: report.host.host_id_sha256,
    host_os: report.host.os,
    host_arch: report.host.arch,
    host_cpu: report.host.cpu,
    host_affinity_available: report.host.affinity.state === "available",
    host_affinity: report.host.affinity.value ?? "",
    host_frequency_hz_available: report.host.frequency_hz.state === "available",
    host_frequency_hz: report.host.frequency_hz.value ?? 0,
    host_noise: report.host.noise,
  };
  for (const name of SUMMARY_FIELDS) values[`summary_${name}`] = report.summary[name];
  for (const name of COUNTER_NAMES) {
    values[`${name}_available`] = report.counters[name].state === "available";
    values[`${name}_value`] = report.counters[name].value ?? 0;
  }
  for (const name of DIGEST_FIELDS) values[name] = report.digests[name];
  return orderedStage2(values);
}

export function fromStage2Outcome(value) {
  const source = object(value, "$stage2");
  exactKeys(source, STAGE2_REPORT_FIELDS.map(({ name }) => name), "$stage2");
  const status = integer(
    source.status_tag,
    "$stage2.status_tag",
    0,
    Math.max(...Object.values(STAGE2_STATUS_TAGS)),
    ERROR_CODES.invalidInvariant,
  );
  if (status !== STAGE2_STATUS_TAGS.valid) {
    for (const { name, type } of STAGE2_REPORT_FIELDS.slice(1)) {
      const expected = stage2Neutral(type);
      const actual = source[name];
      const neutral = type === "List[Int]"
        ? Array.isArray(actual) && actual.length === 0
        : actual === expected;
      if (!neutral) {
        reject(ERROR_CODES.invalidInvariant, `$stage2.${name}`, "error outcome carries partial report data");
      }
    }
    const code = Object.entries(STAGE2_STATUS_TAGS).find(([, tag]) => tag === status)?.[0];
    if (code === undefined) throw new Error("unreachable Stage 2 status tag");
    return Object.freeze({ kind: "error", code });
  }

  const parameterPresent = physicalBoolean(source.parameter_present, "$stage2.parameter_present");
  if (!parameterPresent && source.parameter !== "") {
    reject(ERROR_CODES.invalidInvariant, "$stage2.parameter", "absent parameter payload is not empty");
  }
  const series = joinSegmentedSeries({
    count: source.sample_count,
    sample_segment0: source.sample_segment0,
    sample_segment1: source.sample_segment1,
    flag_segment0: source.outlier_segment0,
    flag_segment1: source.outlier_segment1,
  });
  const identity = {
    suite: source.suite,
    case: source.case,
  };
  if (parameterPresent) identity.parameter = source.parameter;
  identity.metric = source.metric;
  identity.unit = "ns";
  identity.direction = taggedName(source.direction_tag, STAGE2_VALUE_TAGS.direction, "$stage2.direction_tag");

  const counters = Object.fromEntries(COUNTER_NAMES.map((name) => [
    name,
    stage2Availability(
      source[`${name}_available`],
      source[`${name}_value`],
      `$stage2.${name}`,
      0,
    ),
  ]));
  const report = validateReport({
    schema: REPORT_SCHEMA,
    identity,
    clock: taggedName(source.clock_tag, STAGE2_VALUE_TAGS.clock, "$stage2.clock_tag"),
    budget: {
      warmup_cap_ns: source.warmup_cap_ns,
      sampling_cap_ns: source.sampling_cap_ns,
      sample_cap: source.sample_cap,
    },
    measurement: {
      warmup_iterations: source.warmup_iterations,
      warmup_stop: taggedName(source.warmup_stop_tag, STAGE2_VALUE_TAGS.warmupStop, "$stage2.warmup_stop_tag"),
      iterations_per_sample: source.iterations_per_sample,
      sample_count: source.sample_count,
      sampling_stop: taggedName(source.sampling_stop_tag, STAGE2_VALUE_TAGS.samplingStop, "$stage2.sampling_stop_tag"),
      harness_overhead_ns: source.harness_overhead_ns,
    },
    samples: series.samples,
    outliers: series.outliers,
    summary: Object.fromEntries(SUMMARY_FIELDS.map((name) => [name, source[`summary_${name}`]])),
    counters,
    digests: Object.fromEntries(DIGEST_FIELDS.map((name) => [name, source[name]])),
    host: {
      host_id_sha256: source.host_id_sha256,
      os: source.host_os,
      arch: source.host_arch,
      cpu: source.host_cpu,
      affinity: stage2Availability(
        source.host_affinity_available,
        source.host_affinity,
        "$stage2.host_affinity",
        "",
      ),
      frequency_hz: stage2Availability(
        source.host_frequency_hz_available,
        source.host_frequency_hz,
        "$stage2.host_frequency_hz",
        0,
      ),
      noise: source.host_noise,
    },
  });
  return Object.freeze({ kind: "report", report });
}

function sameSummary(left, right) {
  return SUMMARY_FIELDS.every((field) => left[field] === right[field]);
}

export function validateReport(value) {
  const root = object(value, "$"), optionalParameter = new Set(["parameter"]);
  exactKeys(root, ROOT_FIELDS, "$");
  if (root.schema !== REPORT_SCHEMA) {
    reject(ERROR_CODES.schemaShape, "$.schema", `expected ${REPORT_SCHEMA}`);
  }

  const identity = object(root.identity, "$.identity");
  exactKeys(identity, IDENTITY_FIELDS, "$.identity", optionalParameter);
  const normalizedIdentity = {
    suite: boundedText(identity.suite, "$.identity.suite", LIMITS.identityBytes),
    case: boundedText(identity.case, "$.identity.case", LIMITS.identityBytes),
  };
  if (Object.hasOwn(identity, "parameter")) {
    normalizedIdentity.parameter = boundedText(
      identity.parameter,
      "$.identity.parameter",
      LIMITS.identityBytes,
    );
  }
  normalizedIdentity.metric = boundedText(identity.metric, "$.identity.metric", LIMITS.identityBytes);
  if (identity.unit !== "ns") reject(ERROR_CODES.schemaShape, "$.identity.unit", "v1 unit is ns");
  normalizedIdentity.unit = "ns";
  normalizedIdentity.direction = oneOf(identity.direction, DIRECTIONS, "$.identity.direction");

  const clock = oneOf(root.clock, CLOCKS, "$.clock");

  const budget = object(root.budget, "$.budget");
  exactKeys(budget, BUDGET_FIELDS, "$.budget");
  const normalizedBudget = Object.freeze({
    warmup_cap_ns: integer(budget.warmup_cap_ns, "$.budget.warmup_cap_ns", 0, LIMITS.warmupCapNs),
    sampling_cap_ns: integer(budget.sampling_cap_ns, "$.budget.sampling_cap_ns", 1, LIMITS.samplingCapNs),
    sample_cap: integer(budget.sample_cap, "$.budget.sample_cap", 1, LIMITS.samples),
  });

  const measurement = object(root.measurement, "$.measurement");
  exactKeys(measurement, MEASUREMENT_FIELDS, "$.measurement");
  const normalizedMeasurement = Object.freeze({
    warmup_iterations: integer(measurement.warmup_iterations, "$.measurement.warmup_iterations"),
    warmup_stop: oneOf(measurement.warmup_stop, WARMUP_STOPS, "$.measurement.warmup_stop"),
    iterations_per_sample: integer(measurement.iterations_per_sample, "$.measurement.iterations_per_sample", 1),
    sample_count: integer(measurement.sample_count, "$.measurement.sample_count", 1, LIMITS.samples),
    sampling_stop: oneOf(measurement.sampling_stop, SAMPLING_STOPS, "$.measurement.sampling_stop"),
    harness_overhead_ns: integer(measurement.harness_overhead_ns, "$.measurement.harness_overhead_ns"),
  });
  if ((normalizedBudget.warmup_cap_ns === 0) !== (normalizedMeasurement.warmup_stop === "disabled")) {
    reject(ERROR_CODES.invalidInvariant, "$.measurement.warmup_stop", "disabled iff warmup_cap_ns is zero");
  }
  if ((normalizedMeasurement.warmup_stop === "disabled") !== (normalizedMeasurement.warmup_iterations === 0)) {
    reject(ERROR_CODES.invalidInvariant, "$.measurement.warmup_iterations", "zero iff warmup is disabled");
  }

  if (!Array.isArray(root.samples)) reject(ERROR_CODES.schemaShape, "$.samples", "expected array");
  if (root.samples.length > LIMITS.samples) {
    reject(ERROR_CODES.limitExceeded, "$.samples", `more than ${LIMITS.samples} samples`);
  }
  const samples = Object.freeze(root.samples.map((sample, index) => integer(sample, `$.samples[${index}]`)));
  if (samples.length === 0) reject(ERROR_CODES.invalidInvariant, "$.samples", "a successful report needs a sample");
  if (samples.length !== normalizedMeasurement.sample_count) {
    reject(ERROR_CODES.invalidInvariant, "$.measurement.sample_count", "must equal samples.length");
  }
  if (samples.length > normalizedBudget.sample_cap) {
    reject(ERROR_CODES.invalidInvariant, "$.samples", "sample count exceeds the requested cap");
  }
  if (normalizedMeasurement.sampling_stop === "sample-cap" && samples.length !== normalizedBudget.sample_cap) {
    reject(ERROR_CODES.invalidInvariant, "$.measurement.sampling_stop", "sample-cap requires samples.length == sample_cap");
  }
  if (normalizedMeasurement.sampling_stop === "time-cap" && samples.length >= normalizedBudget.sample_cap) {
    reject(ERROR_CODES.invalidInvariant, "$.measurement.sampling_stop", "time-cap requires samples.length < sample_cap");
  }

  if (!Array.isArray(root.outliers)) reject(ERROR_CODES.schemaShape, "$.outliers", "expected array");
  if (root.outliers.length > LIMITS.samples) {
    reject(ERROR_CODES.limitExceeded, "$.outliers", `more than ${LIMITS.samples} flags`);
  }
  const outliers = Object.freeze(root.outliers.map((flag, index) => {
    if (typeof flag !== "boolean") reject(ERROR_CODES.schemaShape, `$.outliers[${index}]`, "expected Boolean");
    return flag;
  }));
  if (outliers.length !== samples.length) {
    reject(ERROR_CODES.invalidInvariant, "$.outliers", "flags must align one-for-one with raw samples");
  }
  const expectedOutliers = outlierFlags(samples);
  if (outliers.some((flag, index) => flag !== expectedOutliers[index])) {
    reject(ERROR_CODES.invalidInvariant, "$.outliers", "flags do not equal the strict 1.5-IQR v1 rule");
  }

  const summary = object(root.summary, "$.summary");
  exactKeys(summary, SUMMARY_FIELDS, "$.summary");
  const normalizedSummary = Object.freeze(Object.fromEntries(
    SUMMARY_FIELDS.map((field) => [field, integer(summary[field], `$.summary.${field}`)]),
  ));
  const expectedSummary = summarize(samples);
  if (!sameSummary(normalizedSummary, expectedSummary)) {
    reject(ERROR_CODES.invalidInvariant, "$.summary", "does not equal the v1 nearest-rank summary of raw samples");
  }

  const counters = object(root.counters, "$.counters");
  exactKeys(counters, COUNTER_NAMES, "$.counters");
  const normalizedCounters = Object.freeze(Object.fromEntries(
    COUNTER_NAMES.map((name) => [name, availabilityCounter(counters[name], `$.counters.${name}`)]),
  ));

  const digests = object(root.digests, "$.digests");
  exactKeys(digests, DIGEST_FIELDS, "$.digests");
  const normalizedDigests = Object.freeze(Object.fromEntries(
    DIGEST_FIELDS.map((field) => [field, digest(digests[field], `$.digests.${field}`)]),
  ));

  const host = object(root.host, "$.host");
  exactKeys(host, HOST_FIELDS, "$.host");
  const normalizedHost = Object.freeze({
    host_id_sha256: digest(host.host_id_sha256, "$.host.host_id_sha256"),
    os: boundedText(host.os, "$.host.os", LIMITS.hostTextBytes),
    arch: boundedText(host.arch, "$.host.arch", LIMITS.hostTextBytes),
    cpu: boundedText(host.cpu, "$.host.cpu", LIMITS.hostTextBytes),
    affinity: availabilityText(host.affinity, "$.host.affinity"),
    frequency_hz: availabilityCounter(host.frequency_hz, "$.host.frequency_hz"),
    noise: boundedText(host.noise, "$.host.noise", LIMITS.noteBytes, { empty: true, note: true }),
  });

  return Object.freeze({
    schema: REPORT_SCHEMA,
    identity: Object.freeze(normalizedIdentity),
    clock,
    budget: normalizedBudget,
    measurement: normalizedMeasurement,
    samples,
    outliers,
    summary: normalizedSummary,
    counters: normalizedCounters,
    digests: normalizedDigests,
    host: normalizedHost,
  });
}

function orderedAvailability(value) {
  return value.state === "unavailable"
    ? { state: "unavailable" }
    : { state: "available", value: value.value };
}

function orderedReport(report) {
  const identity = { suite: report.identity.suite, case: report.identity.case };
  if (Object.hasOwn(report.identity, "parameter")) identity.parameter = report.identity.parameter;
  identity.metric = report.identity.metric;
  identity.unit = report.identity.unit;
  identity.direction = report.identity.direction;
  return {
    schema: REPORT_SCHEMA,
    identity,
    clock: report.clock,
    budget: Object.fromEntries(BUDGET_FIELDS.map((field) => [field, report.budget[field]])),
    measurement: Object.fromEntries(MEASUREMENT_FIELDS.map((field) => [field, report.measurement[field]])),
    samples: [...report.samples],
    outliers: [...report.outliers],
    summary: Object.fromEntries(SUMMARY_FIELDS.map((field) => [field, report.summary[field]])),
    counters: Object.fromEntries(COUNTER_NAMES.map((name) => [name, orderedAvailability(report.counters[name])])),
    digests: Object.fromEntries(DIGEST_FIELDS.map((field) => [field, report.digests[field]])),
    host: {
      host_id_sha256: report.host.host_id_sha256,
      os: report.host.os,
      arch: report.host.arch,
      cpu: report.host.cpu,
      affinity: orderedAvailability(report.host.affinity),
      frequency_hz: orderedAvailability(report.host.frequency_hz),
      noise: report.host.noise,
    },
  };
}

export function encodeReport(value) {
  const report = validateReport(value);
  const bytes = Buffer.from(`${JSON.stringify(orderedReport(report))}\n`, "utf8");
  if (bytes.length > LIMITS.wireBytes) {
    reject(ERROR_CODES.limitExceeded, "$bytes", `report exceeds ${LIMITS.wireBytes} bytes`);
  }
  return bytes;
}

export function decodeReport(input) {
  const bytes = Buffer.from(input);
  if (bytes.length > LIMITS.wireBytes) {
    reject(ERROR_CODES.limitExceeded, "$bytes", `report exceeds ${LIMITS.wireBytes} bytes`);
  }
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    reject(ERROR_CODES.invalidEncoding, "$bytes", "UTF-8 BOM is forbidden");
  }
  let text;
  try {
    text = UTF8.decode(bytes);
  } catch {
    reject(ERROR_CODES.invalidEncoding, "$bytes", "invalid UTF-8");
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    reject(ERROR_CODES.invalidEncoding, "$bytes", "malformed JSON or trailing data");
  }
  if (hasDuplicateJsonKey(text)) {
    reject(ERROR_CODES.nonCanonicalBytes, "$bytes", "duplicate JSON object key");
  }
  const report = validateReport(parsed);
  const canonical = encodeReport(report);
  if (!canonical.equals(bytes)) {
    reject(ERROR_CODES.nonCanonicalBytes, "$bytes", "valid data is not in the canonical byte form");
  }
  return report;
}

function compatible(left, right) {
  return left.identity.suite === right.identity.suite &&
    left.identity.case === right.identity.case &&
    left.identity.parameter === right.identity.parameter &&
    left.identity.metric === right.identity.metric &&
    left.identity.unit === right.identity.unit &&
    left.identity.direction === right.identity.direction &&
    left.clock === right.clock &&
    left.measurement.iterations_per_sample === right.measurement.iterations_per_sample;
}

function roundedBasisPoints(numerator, denominator) {
  const scaled = BigInt(numerator) * 10_000n;
  const divisor = BigInt(denominator);
  const magnitude = scaled < 0n ? -scaled : scaled;
  let quotient = magnitude / divisor;
  const remainder = magnitude % divisor;
  if (remainder * 2n >= divisor) quotient += 1n;
  if (quotient > BigInt(LIMITS.integer)) {
    reject(ERROR_CODES.arithmeticOverflow, "$comparison", "rounded basis-point result exceeds the v1 integer carrier");
  }
  return Number(scaled < 0n ? -quotient : quotient);
}

export function compareReports(baselineValue, candidateValue, thresholdBps) {
  const baseline = validateReport(baselineValue);
  const candidate = validateReport(candidateValue);
  if (!Number.isSafeInteger(thresholdBps) || thresholdBps < 0 || thresholdBps > LIMITS.thresholdBps) {
    reject(ERROR_CODES.invalidThreshold, "$threshold_bps", `expected 0..${LIMITS.thresholdBps}`);
  }
  if (!compatible(baseline, candidate)) {
    reject(ERROR_CODES.incompatibleComparison, "$comparison", "identity, unit, clock, direction, or batch size differs");
  }
  const base = baseline.summary.median;
  const next = candidate.summary.median;
  if (base === 0) {
    if (next === 0) {
      return Object.freeze({
        kind: "comparable",
        verdict: "equivalent",
        change_bps: 0,
        threshold_bps: thresholdBps,
      });
    }
    return Object.freeze({
      kind: "indeterminate",
      reason: "zero-baseline",
      threshold_bps: thresholdBps,
    });
  }
  const rawDifference = baseline.identity.direction === "lower-is-better"
    ? next - base
    : base - next;
  const change = roundedBasisPoints(rawDifference, base);
  const verdict = change > thresholdBps
    ? "regressed"
    : (change < -thresholdBps ? "improved" : "equivalent");
  return Object.freeze({
    kind: "comparable",
    verdict,
    change_bps: change,
    threshold_bps: thresholdBps,
  });
}

export function reportBytePlan(outcome, report = undefined) {
  if (outcome === "success") {
    if (report === undefined) reject(ERROR_CODES.schemaShape, "$outcome", "success requires a report");
    return Object.freeze({ kind: "complete", bytes: encodeReport(report) });
  }
  if (outcome === "failed") {
    return Object.freeze({ kind: "no-bytes", code: ERROR_CODES.measurementFailed });
  }
  if (outcome === "cancelled") {
    return Object.freeze({ kind: "no-bytes", code: ERROR_CODES.cancelled });
  }
  if (outcome === "output-failed") {
    return Object.freeze({ kind: "no-bytes", code: ERROR_CODES.outputFailed });
  }
  reject(
    ERROR_CODES.schemaShape,
    "$outcome",
    "expected success, failed, cancelled, or output-failed",
  );
}

export function applyReportBytePlan(previousValue, planValue) {
  const previous = Buffer.from(previousValue);
  const plan = object(planValue, "$reportBytes");
  if (plan.kind === "complete") {
    exactKeys(plan, ["kind", "bytes"], "$reportBytes");
    const bytes = Buffer.from(plan.bytes);
    if (bytes.length > LIMITS.wireBytes) {
      reject(ERROR_CODES.limitExceeded, "$reportBytes.bytes", "report bytes exceed v1");
    }
    decodeReport(bytes);
    return bytes;
  }
  if (plan.kind === "no-bytes") {
    exactKeys(plan, ["kind", "code"], "$reportBytes");
    if (!ERROR_VOCABULARY.includes(plan.code)) {
      reject(ERROR_CODES.schemaShape, "$reportBytes.code", "unknown report error");
    }
    return previous;
  }
  reject(ERROR_CODES.schemaShape, "$reportBytes.kind", "unknown report-byte plan");
}

function cli() {
  const [command, ...arguments_] = process.argv.slice(2);
  if (command === "validate" && arguments_.length === 1) {
    const report = decodeReport(fs.readFileSync(arguments_[0]));
    process.stdout.write(encodeReport(report));
    return;
  }
  if (command === "compare" && arguments_.length === 3) {
    const baseline = decodeReport(fs.readFileSync(arguments_[0]));
    const candidate = decodeReport(fs.readFileSync(arguments_[1]));
    const threshold = Number(arguments_[2]);
    process.stdout.write(`${JSON.stringify(compareReports(baseline, candidate, threshold))}\n`);
    return;
  }
  process.stderr.write("usage: model.mjs validate REPORT | compare BASELINE CANDIDATE THRESHOLD_BPS\n");
  process.exitCode = 2;
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) cli();

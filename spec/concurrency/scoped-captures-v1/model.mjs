#!/usr/bin/env node

import crypto from "node:crypto";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const INPUT_SCHEMA = "kofun.scope-capture-observations/v1";
export const HIR_SCHEMA = "kofun-scope-hir/v2";
export const KSE_SCHEMA = "kofun-stage2-semantic-events/v2";
export const SIDECAR_SCHEMA = "kofun.typed-sidecar/v2";
export const PROFILE = "kofun.stage2-analysis/scoped-captures/v1";

export const LIMITS = Object.freeze({
  candidate_projection_depth: 64,
  capture_observations_per_task: 256,
  captures_per_task: 64,
  display_bytes: 128,
  document_bytes: 16 * 1024 * 1024,
  origins_per_capture: 256,
  pars: 64,
  projection_depth: 8,
  records: 8384,
  tasks: 64,
});

export const KSE2_LIMITS = Object.freeze({
  capture_events: 8384,
  event_bytes: 16 * 1024 * 1024,
  events: 16384,
  field_bytes: 16 * 1024,
  relations: 256,
});

export const SIDECAR_V2_LIMITS = Object.freeze({
  document_bytes: 16 * 1024 * 1024,
  max_depth: 128,
  profile: "default-v2",
});

const ID = /^[0-9a-f]{64}$/;
const I64 = /^(?:0|-?[1-9][0-9]*)$/;
const MODES = new Set(["read", "edit", "take"]);
const MODE_RANK = Object.freeze({ read: 0, edit: 1, take: 2 });
const UNKNOWN_REASONS = new Set([
  "unresolved-call",
  "projection-depth-exceeded",
  "unnameable-place",
]);
const UNKNOWN_REASON_TAG = Object.freeze({
  "unresolved-call": 1,
  "projection-depth-exceeded": 2,
  "unnameable-place": 3,
});
const RECORD_RANK = Object.freeze({
  par: 0,
  task: 1,
  join: 2,
  place: 3,
  unknown: 4,
  capture: 5,
});

export class CaptureContractError extends Error {
  constructor(path, detail) {
    super(`${path}: ${detail}`);
    this.name = "CaptureContractError";
    this.path = path;
    this.detail = detail;
  }
}

const fail = (path, detail) => {
  throw new CaptureContractError(path, detail);
};

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function object(value, path) {
  if (!isObject(value)) fail(path, "expected object");
  return value;
}

function exactKeys(value, wanted, path) {
  object(value, path);
  const actual = Object.keys(value).sort();
  const expected = [...wanted].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    fail(path, `expected exactly fields ${expected.join(",")}`);
  }
}

function array(value, path, maximum) {
  if (!Array.isArray(value)) fail(path, "expected array");
  if (value.length > maximum) {
    fail(path, `limit exceeded (${value.length} > ${maximum})`);
  }
  return value;
}

function integer(value, path, minimum, maximum) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    fail(path, `expected integer from ${minimum} through ${maximum}`);
  }
  return value;
}

function semanticId(value, path) {
  if (typeof value !== "string" || !ID.test(value) || /^0+$/.test(value)) {
    fail(path, "expected a nonzero 32-byte lowercase hexadecimal identity");
  }
  return value;
}

function validText(value, path) {
  if (typeof value !== "string" || value.length === 0) {
    fail(path, "expected non-empty display text");
  }
  if (value.normalize("NFC") !== value) fail(path, "display text must be NFC");
  if (/[\u0000-\u001f\u007f]/u.test(value)) {
    fail(path, "display text must not contain control characters");
  }
  const length = Buffer.byteLength(value, "utf8");
  if (length > LIMITS.display_bytes) {
    fail(path, `display text exceeds ${LIMITS.display_bytes} UTF-8 bytes`);
  }
  return value;
}

function normalizeDisplay(value, path) {
  exactKeys(value, ["disclosure", "text"], path);
  if (value.disclosure === "visible") {
    return Object.freeze({
      disclosure: "visible",
      text: validText(value.text, `${path}.text`),
    });
  }
  if (value.disclosure === "hidden") {
    if (value.text !== null) fail(`${path}.text`, "a hidden name must be null");
    return Object.freeze({ disclosure: "hidden", text: null });
  }
  fail(`${path}.disclosure`, "expected visible or hidden");
}

function normalizeSpan(value, path) {
  exactKeys(value, ["end", "start"], path);
  const start = integer(value.start, `${path}.start`, 0, 0xffffffff);
  const end = integer(value.end, `${path}.end`, 0, 0xffffffff);
  if (start >= end) fail(path, "span must be non-empty and half-open");
  return Object.freeze({ end, start });
}

function normalizeOrigin(value, path) {
  exactKeys(value, ["node_id", "span"], path);
  return Object.freeze({
    node_id: semanticId(value.node_id, `${path}.node_id`),
    span: normalizeSpan(value.span, `${path}.span`),
  });
}

function canonicalI64(value, path) {
  if (typeof value !== "string" || !I64.test(value)) {
    fail(path, "expected a canonical decimal i64 string");
  }
  const number = BigInt(value);
  if (number < -(1n << 63n) || number > (1n << 63n) - 1n) {
    fail(path, "constant is outside signed i64");
  }
  return value;
}

function normalizeBound(value, path) {
  object(value, path);
  if (value.kind === "constant") {
    exactKeys(value, ["kind", "value"], path);
    return Object.freeze({
      kind: "constant",
      value: canonicalI64(value.value, `${path}.value`),
    });
  }
  if (value.kind === "node") {
    exactKeys(value, ["kind", "node_id"], path);
    return Object.freeze({
      kind: "node",
      node_id: semanticId(value.node_id, `${path}.node_id`),
    });
  }
  fail(`${path}.kind`, "expected constant or node");
}

function normalizeProjection(value, path) {
  object(value, path);
  if (value.kind === "field") {
    exactKeys(value, ["display", "kind", "ordinal", "owner_type_id"], path);
    return Object.freeze({
      display: normalizeDisplay(value.display, `${path}.display`),
      kind: "field",
      ordinal: integer(value.ordinal, `${path}.ordinal`, 0, 0xffffffff),
      owner_type_id: semanticId(value.owner_type_id, `${path}.owner_type_id`),
    });
  }
  if (value.kind === "slice") {
    exactKeys(value, ["kind", "lower", "upper"], path);
    const lower = normalizeBound(value.lower, `${path}.lower`);
    const upper = normalizeBound(value.upper, `${path}.upper`);
    if (
      lower.kind === "constant" &&
      upper.kind === "constant" &&
      BigInt(lower.value) > BigInt(upper.value)
    ) {
      fail(path, "a constant half-open slice must not have lower greater than upper");
    }
    return Object.freeze({
      kind: "slice",
      lower,
      upper,
    });
  }
  fail(`${path}.kind`, "expected field or slice");
}

function normalizePlace(value, path, maximumDepth) {
  exactKeys(value, ["base_binding_id", "display", "kind", "projections"], path);
  if (value.kind !== "place") fail(`${path}.kind`, "expected place");
  return Object.freeze({
    base_binding_id: semanticId(value.base_binding_id, `${path}.base_binding_id`),
    display: normalizeDisplay(value.display, `${path}.display`),
    kind: "place",
    projections: Object.freeze(array(
      value.projections,
      `${path}.projections`,
      maximumDepth,
    ).map((projection, index) =>
      normalizeProjection(projection, `${path}.projections[${index}]`))),
  });
}

function normalizeUnknown(value, path) {
  exactKeys(value, ["kind", "reason"], path);
  if (value.kind !== "unknown") fail(`${path}.kind`, "expected unknown");
  if (!UNKNOWN_REASONS.has(value.reason)) {
    fail(`${path}.reason`, "unknown reason is outside the closed vocabulary");
  }
  return Object.freeze({ kind: "unknown", reason: value.reason });
}

function normalizeTarget(value, path) {
  object(value, path);
  if (value.kind === "place") {
    return normalizePlace(value, path, LIMITS.candidate_projection_depth);
  }
  if (value.kind === "unknown") return normalizeUnknown(value, path);
  fail(`${path}.kind`, "expected place or unknown");
}

function normalizeMode(value, path) {
  if (!MODES.has(value)) fail(path, "expected read, edit, or take");
  return value;
}

function compareText(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function originOrder(left, right) {
  return left.span.start - right.span.start ||
    left.span.end - right.span.end ||
    compareText(left.node_id, right.node_id);
}

function u16(value) {
  const bytes = Buffer.alloc(2);
  bytes.writeUInt16BE(value);
  return bytes;
}

function u32(value) {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(value);
  return bytes;
}

function i64(value) {
  let number = BigInt(value);
  if (number < 0) number += 1n << 64n;
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64BE(number);
  return bytes;
}

function idBytes(value, path = "identity") {
  semanticId(value, path);
  return Buffer.from(value, "hex");
}

function framedHash(domain, payload) {
  const domainBytes = Buffer.from(domain, "utf8");
  const frame = Buffer.concat([
    Buffer.from("KOFUN\0", "utf8"),
    u16(domainBytes.length),
    domainBytes,
    u32(payload.length),
    payload,
  ]);
  return crypto.createHash("sha256").update(frame).digest("hex");
}

function boundBytes(bound) {
  if (bound.kind === "constant") {
    return Buffer.concat([Buffer.from([1]), i64(bound.value)]);
  }
  return Buffer.concat([Buffer.from([2]), idBytes(bound.node_id)]);
}

export function canonicalPlaceBytes(place) {
  const normalized = normalizePlace(place, "$place", LIMITS.projection_depth);
  const chunks = [
    Buffer.from([0x4b, 0x50, 0x4c, 0x00, 0x02]),
    idBytes(normalized.base_binding_id),
    Buffer.from([normalized.projections.length]),
  ];
  for (const projection of normalized.projections) {
    if (projection.kind === "field") {
      chunks.push(
        Buffer.from([1]),
        idBytes(projection.owner_type_id),
        u32(projection.ordinal),
      );
    } else {
      chunks.push(Buffer.from([2]), boundBytes(projection.lower), boundBytes(projection.upper));
    }
  }
  return Buffer.concat(chunks);
}

function canonicalUnknownBytes(taskId, reason, witnessNodeId) {
  if (!UNKNOWN_REASONS.has(reason)) fail("$unknown.reason", "unknown reason is invalid");
  return Buffer.concat([
    Buffer.from([0x4b, 0x55, 0x4e, 0x00, 0x02]),
    idBytes(taskId),
    Buffer.from([UNKNOWN_REASON_TAG[reason]]),
    idBytes(witnessNodeId),
  ]);
}

function parId(fileId, record) {
  return framedHash("kofun.scope-hir.par/v2", Buffer.concat([
    idBytes(fileId),
    idBytes(record.scope_id),
    idBytes(record.node_id),
  ]));
}

function taskId(record) {
  return framedHash("kofun.scope-hir.task/v2", Buffer.concat([
    idBytes(record.par_id),
    u32(record.lexical_index),
    idBytes(record.spawn_node_id),
    idBytes(record.lambda_node_id),
    idBytes(record.handle_binding_id),
  ]));
}

function joinId(record) {
  const kind = record.join_kind === "explicit" ? 1 : 2;
  return framedHash("kofun.scope-hir.join/v2", Buffer.concat([
    idBytes(record.task_id),
    Buffer.from([kind]),
    ...(record.node_id === null ? [] : [idBytes(record.node_id)]),
  ]));
}

function placeId(bytes) {
  return framedHash("kofun.scope-hir.place/v2", bytes);
}

function unknownId(task, reason, witness) {
  return framedHash("kofun.scope-hir.unknown/v2", Buffer.concat([
    idBytes(task),
    Buffer.from([UNKNOWN_REASON_TAG[reason]]),
    idBytes(witness),
  ]));
}

function captureId(task, targetKind, targetId) {
  return framedHash("kofun.scope-hir.capture/v2", Buffer.concat([
    idBytes(task),
    Buffer.from([targetKind === "place" ? 1 : 2]),
    idBytes(targetId),
  ]));
}

function clone(value) {
  return structuredClone(value);
}

function deepFreeze(value) {
  if (value !== null && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const item of Object.values(value)) deepFreeze(item);
  }
  return value;
}

function structuralDepth(value) {
  if (value === null || typeof value !== "object") return 0;
  const nested = Array.isArray(value) ? value : Object.values(value);
  return 1 + nested.reduce((maximum, item) => Math.max(maximum, structuralDepth(item)), 0);
}

export function canonicalJson(value) {
  function encode(item) {
    if (item === null || typeof item === "boolean" || typeof item === "string") {
      return JSON.stringify(item);
    }
    if (Number.isSafeInteger(item)) return String(item);
    if (Array.isArray(item)) return `[${item.map(encode).join(",")}]`;
    if (!isObject(item)) fail("$canonical", "unsupported JSON value");
    return `{${Object.keys(item).sort().map((key) =>
      `${JSON.stringify(key)}:${encode(item[key])}`).join(",")}}`;
  }
  return `${encode(value)}\n`;
}

function normalizeObservation(value, path) {
  exactKeys(value, ["mode", "origin", "target"], path);
  return Object.freeze({
    mode: normalizeMode(value.mode, `${path}.mode`),
    origin: normalizeOrigin(value.origin, `${path}.origin`),
    target: normalizeTarget(value.target, `${path}.target`),
  });
}

function normalizeJoin(value, path) {
  exactKeys(value, ["kind", "node_id"], path);
  if (value.kind === "explicit") {
    return Object.freeze({
      kind: "explicit",
      node_id: semanticId(value.node_id, `${path}.node_id`),
    });
  }
  if (value.kind === "scope-exit") {
    if (value.node_id !== null) fail(`${path}.node_id`, "scope-exit join node must be null");
    return Object.freeze({ kind: "scope-exit", node_id: null });
  }
  fail(`${path}.kind`, "expected explicit or scope-exit");
}

function normalizeTaskInput(value, path) {
  exactKeys(value, [
    "display",
    "handle_binding_id",
    "join",
    "lambda_node_id",
    "lexical_index",
    "observations",
    "spawn_node_id",
  ], path);
  return Object.freeze({
    display: normalizeDisplay(value.display, `${path}.display`),
    handle_binding_id: semanticId(value.handle_binding_id, `${path}.handle_binding_id`),
    join: normalizeJoin(value.join, `${path}.join`),
    lambda_node_id: semanticId(value.lambda_node_id, `${path}.lambda_node_id`),
    lexical_index: integer(value.lexical_index, `${path}.lexical_index`, 0, 0xffffffff),
    observations: Object.freeze(array(
      value.observations,
      `${path}.observations`,
      LIMITS.capture_observations_per_task,
    ).map((observation, index) =>
      normalizeObservation(observation, `${path}.observations[${index}]`))),
    spawn_node_id: semanticId(value.spawn_node_id, `${path}.spawn_node_id`),
  });
}

function normalizeParInput(value, path) {
  exactKeys(value, [
    "display",
    "lexical_index",
    "node_id",
    "parent_scope_id",
    "scope_id",
    "scope_token_binding_id",
    "tasks",
  ], path);
  return Object.freeze({
    display: normalizeDisplay(value.display, `${path}.display`),
    lexical_index: integer(value.lexical_index, `${path}.lexical_index`, 0, 0xffffffff),
    node_id: semanticId(value.node_id, `${path}.node_id`),
    parent_scope_id: semanticId(value.parent_scope_id, `${path}.parent_scope_id`),
    scope_id: semanticId(value.scope_id, `${path}.scope_id`),
    scope_token_binding_id: semanticId(
      value.scope_token_binding_id,
      `${path}.scope_token_binding_id`,
    ),
    tasks: Object.freeze(array(value.tasks, `${path}.tasks`, LIMITS.tasks)
      .map((task, index) => normalizeTaskInput(task, `${path}.tasks[${index}]`))),
  });
}

function denseIndexes(values, path) {
  const sorted = [...values].sort((left, right) => left.lexical_index - right.lexical_index);
  sorted.forEach((value, index) => {
    if (value.lexical_index !== index) {
      fail(path, `lexical indexes must be dense from zero; expected ${index}`);
    }
  });
  return sorted;
}

function strippedPlace(place) {
  return {
    base_binding_id: place.base_binding_id,
    display: clone(place.display),
    kind: "place",
    projections: place.projections.map((projection) => clone(projection)),
  };
}

export function buildScopeHir(input) {
  exactKeys(input, ["file_id", "pars", "profile", "root_scope_id", "schema"], "$input");
  if (input.schema !== INPUT_SCHEMA) fail("$input.schema", `expected ${INPUT_SCHEMA}`);
  if (input.profile !== PROFILE) fail("$input.profile", `expected ${PROFILE}`);
  const fileId = semanticId(input.file_id, "$input.file_id");
  const rootScopeId = semanticId(input.root_scope_id, "$input.root_scope_id");
  const pars = denseIndexes(array(input.pars, "$input.pars", LIMITS.pars)
    .map((par, index) => normalizeParInput(par, `$input.pars[${index}]`)), "$input.pars");
  if (Buffer.byteLength(canonicalJson(input), "utf8") > LIMITS.document_bytes) {
    fail("$input", "canonical model input byte limit exceeded");
  }

  const parRecords = [];
  const parByScope = new Map();
  for (const par of pars) {
    if (par.scope_id === rootScopeId) {
      fail("$input.pars", "a par scope must not alias the root scope");
    }
    if (parByScope.has(par.scope_id)) fail("$input.pars", "duplicate par scope identity");
    if (
      par.parent_scope_id !== rootScopeId &&
      !parByScope.has(par.parent_scope_id)
    ) {
      fail("$input.pars", "par parent must be the root or an earlier par scope");
    }
    const partial = {
      display: clone(par.display),
      lexical_index: par.lexical_index,
      node_id: par.node_id,
      parent_scope_id: par.parent_scope_id,
      record: "par",
      scope_id: par.scope_id,
      scope_token_binding_id: par.scope_token_binding_id,
    };
    const record = { id: parId(fileId, partial), ...partial };
    parRecords.push(record);
    parByScope.set(par.scope_id, record);
  }

  const taskRecords = [];
  const joinRecords = [];
  const work = [];
  let taskCount = 0;
  for (const par of pars) {
    const parent = parByScope.get(par.scope_id);
    const tasks = denseIndexes(par.tasks, `$input.pars[${par.lexical_index}].tasks`);
    taskCount += tasks.length;
    if (taskCount > LIMITS.tasks) fail("$input.pars", `task limit exceeded (${taskCount} > ${LIMITS.tasks})`);
    for (const task of tasks) {
      const partial = {
        display: clone(task.display),
        handle_binding_id: task.handle_binding_id,
        lambda_node_id: task.lambda_node_id,
        lexical_index: task.lexical_index,
        par_id: parent.id,
        record: "task",
        spawn_node_id: task.spawn_node_id,
      };
      const taskRecord = { id: taskId(partial), ...partial };
      taskRecords.push(taskRecord);
      const joinPartial = {
        join_kind: task.join.kind,
        node_id: task.join.node_id,
        record: "join",
        task_id: taskRecord.id,
      };
      joinRecords.push({ id: joinId(joinPartial), ...joinPartial });
      work.push({ input: task, par, record: taskRecord });
    }
  }

  const taskOrder = new Map(taskRecords.map((record, index) => [record.id, index]));
  const places = new Map();
  const unknowns = new Map();
  const captures = new Map();
  const originSpans = new Map();

  function addCapture(task, observation, targetKind, targetId, targetBytes) {
    const key = `${task.id}:${targetKind}:${targetId}`;
    let capture = captures.get(key);
    if (capture === undefined) {
      capture = {
        mode: observation.mode,
        origins: new Map(),
        target_bytes: targetBytes.toString("hex"),
        target_id: targetId,
        target_kind: targetKind,
        task_id: task.id,
      };
      captures.set(key, capture);
    } else if (MODE_RANK[observation.mode] > MODE_RANK[capture.mode]) {
      capture.mode = observation.mode;
    }
    const existingOrigin = capture.origins.get(observation.origin.node_id);
    if (
      existingOrigin !== undefined &&
      (existingOrigin.span.start !== observation.origin.span.start ||
        existingOrigin.span.end !== observation.origin.span.end)
    ) {
      fail("$input", "one origin NodeId must not carry two source spans");
    }
    capture.origins.set(observation.origin.node_id, clone(observation.origin));
  }

  for (const { input: taskInput, record: task } of work) {
    for (const observation of taskInput.observations) {
      const committedSpan = originSpans.get(observation.origin.node_id);
      if (
        committedSpan !== undefined &&
        (committedSpan.start !== observation.origin.span.start ||
          committedSpan.end !== observation.origin.span.end)
      ) {
        fail("$input", "one origin NodeId must not carry two source spans");
      }
      originSpans.set(observation.origin.node_id, observation.origin.span);
      if (
        observation.target.kind === "place" &&
        observation.target.projections.length <= LIMITS.projection_depth
      ) {
        const bytes = canonicalPlaceBytes(observation.target);
        const bytesHex = bytes.toString("hex");
        const id = placeId(bytes);
        const existing = places.get(id);
        if (existing !== undefined && existing.canonical_bytes !== bytesHex) {
          fail("$input", "PlaceId collision");
        }
        const presentation = strippedPlace(observation.target);
        const comparison = existing === undefined
          ? -1
          : originOrder(observation.origin, existing.first_origin);
        if (existing === undefined || comparison < 0) {
          places.set(id, {
            base_binding_id: observation.target.base_binding_id,
            canonical_bytes: bytesHex,
            display: clone(observation.target.display),
            first_origin: observation.origin,
            id,
            projections: observation.target.projections.map((projection) => clone(projection)),
            record: "place",
          });
        } else if (
          comparison === 0 &&
          canonicalJson(strippedPlace(existing)) !== canonicalJson(presentation)
        ) {
          fail("$input", "one place and origin must not carry conflicting display metadata");
        }
        addCapture(task, observation, "place", id, bytes);
        continue;
      }

      const reason = observation.target.kind === "place"
        ? "projection-depth-exceeded"
        : observation.target.reason;
      const bytes = canonicalUnknownBytes(task.id, reason, observation.origin.node_id);
      const id = unknownId(task.id, reason, observation.origin.node_id);
      if (unknowns.has(id)) {
        const existing = unknowns.get(id);
        if (existing.canonical_bytes !== bytes.toString("hex")) fail("$input", "UnknownId collision");
      } else {
        unknowns.set(id, {
          canonical_bytes: bytes.toString("hex"),
          id,
          reason,
          record: "unknown",
          task_id: task.id,
          witness_node_id: observation.origin.node_id,
        });
      }
      addCapture(task, observation, "unknown", id, bytes);
    }
  }

  const placeRecords = [...places.values()]
    .map(({ first_origin: _firstOrigin, ...record }) => record)
    .sort((left, right) => compareText(left.canonical_bytes, right.canonical_bytes));
  const unknownRecords = [...unknowns.values()]
    .sort((left, right) => compareText(left.canonical_bytes, right.canonical_bytes));
  const captureRecords = [...captures.values()].map((capture) => ({
    id: captureId(capture.task_id, capture.target_kind, capture.target_id),
    mode: capture.mode,
    origins: [...capture.origins.values()].sort(originOrder),
    record: "capture",
    target_id: capture.target_id,
    target_kind: capture.target_kind,
    task_id: capture.task_id,
    _target_bytes: capture.target_bytes,
  })).sort((left, right) =>
    taskOrder.get(left.task_id) - taskOrder.get(right.task_id) ||
    compareText(left._target_bytes, right._target_bytes) ||
    MODE_RANK[left.mode] - MODE_RANK[right.mode])
    .map(({ _target_bytes: _targetBytes, ...record }) => record);

  for (const task of taskRecords) {
    const count = captureRecords.filter((capture) => capture.task_id === task.id).length;
    if (count > LIMITS.captures_per_task) {
      fail("$input", `task capture limit exceeded (${count} > ${LIMITS.captures_per_task})`);
    }
  }
  for (const capture of captureRecords) {
    if (capture.origins.length > LIMITS.origins_per_capture) {
      fail("$input", "capture origin limit exceeded");
    }
  }

  const records = [
    ...parRecords,
    ...taskRecords,
    ...joinRecords,
    ...placeRecords,
    ...unknownRecords,
    ...captureRecords,
  ];
  if (records.length > LIMITS.records) fail("$input", "record limit exceeded");
  const document = {
    file_id: fileId,
    limits: { ...LIMITS },
    profile: PROFILE,
    records,
    root_scope_id: rootScopeId,
    schema: HIR_SCHEMA,
  };
  if (Buffer.byteLength(canonicalJson(document), "utf8") > LIMITS.document_bytes) {
    fail("$input", "canonical document byte limit exceeded");
  }
  validateScopeHir(document);
  return deepFreeze(document);
}

function validateLimits(value, path) {
  exactKeys(value, Object.keys(LIMITS), path);
  for (const [name, expected] of Object.entries(LIMITS)) {
    if (value[name] !== expected) fail(`${path}.${name}`, `expected ${expected}`);
  }
}

function validateRecordDisplay(value, path) {
  return normalizeDisplay(value, path);
}

export function validateScopeHir(document) {
  exactKeys(document, ["file_id", "limits", "profile", "records", "root_scope_id", "schema"], "$hir");
  if (document.schema !== HIR_SCHEMA) fail("$hir.schema", `expected ${HIR_SCHEMA}`);
  if (document.profile !== PROFILE) fail("$hir.profile", `expected ${PROFILE}`);
  const fileId = semanticId(document.file_id, "$hir.file_id");
  const rootScopeId = semanticId(document.root_scope_id, "$hir.root_scope_id");
  validateLimits(document.limits, "$hir.limits");
  const records = array(document.records, "$hir.records", LIMITS.records);
  const byId = new Map();
  const pars = [];
  const tasks = [];
  const joins = [];
  const places = [];
  const unknowns = [];
  const captures = [];
  const parScopeIds = new Set();
  const originSpans = new Map();
  let parCount = 0;
  let taskCount = 0;
  let previousRank = -1;

  records.forEach((record, index) => {
    const path = `$hir.records[${index}]`;
    object(record, path);
    if (!Object.hasOwn(RECORD_RANK, record.record)) fail(`${path}.record`, "unknown record kind");
    const rank = RECORD_RANK[record.record];
    if (rank < previousRank) fail(path, "record phase order is noncanonical");
    previousRank = rank;
    semanticId(record.id, `${path}.id`);
    if (byId.has(record.id)) fail(`${path}.id`, "duplicate record identity");
    byId.set(record.id, record);

    if (record.record === "par") {
      parCount += 1;
      if (parCount > LIMITS.pars) fail("$hir.records", "par limit exceeded");
      exactKeys(record, [
        "display", "id", "lexical_index", "node_id", "parent_scope_id", "record",
        "scope_id", "scope_token_binding_id",
      ], path);
      validateRecordDisplay(record.display, `${path}.display`);
      integer(record.lexical_index, `${path}.lexical_index`, 0, 0xffffffff);
      semanticId(record.node_id, `${path}.node_id`);
      semanticId(record.parent_scope_id, `${path}.parent_scope_id`);
      semanticId(record.scope_id, `${path}.scope_id`);
      if (record.scope_id === rootScopeId) {
        fail(`${path}.scope_id`, "a par scope must not alias the root scope");
      }
      if (parScopeIds.has(record.scope_id)) fail(`${path}.scope_id`, "duplicate par scope identity");
      parScopeIds.add(record.scope_id);
      semanticId(record.scope_token_binding_id, `${path}.scope_token_binding_id`);
      if (record.id !== parId(fileId, record)) fail(`${path}.id`, "ParId preimage mismatch");
      pars.push(record);
      return;
    }
    if (record.record === "task") {
      taskCount += 1;
      if (taskCount > LIMITS.tasks) fail("$hir.records", "task limit exceeded");
      exactKeys(record, [
        "display", "handle_binding_id", "id", "lambda_node_id", "lexical_index",
        "par_id", "record", "spawn_node_id",
      ], path);
      validateRecordDisplay(record.display, `${path}.display`);
      semanticId(record.handle_binding_id, `${path}.handle_binding_id`);
      semanticId(record.lambda_node_id, `${path}.lambda_node_id`);
      integer(record.lexical_index, `${path}.lexical_index`, 0, 0xffffffff);
      semanticId(record.par_id, `${path}.par_id`);
      semanticId(record.spawn_node_id, `${path}.spawn_node_id`);
      if (record.id !== taskId(record)) fail(`${path}.id`, "TaskId preimage mismatch");
      tasks.push(record);
      return;
    }
    if (record.record === "join") {
      exactKeys(record, ["id", "join_kind", "node_id", "record", "task_id"], path);
      if (!new Set(["explicit", "scope-exit"]).has(record.join_kind)) {
        fail(`${path}.join_kind`, "unknown join kind");
      }
      if (record.join_kind === "explicit") semanticId(record.node_id, `${path}.node_id`);
      else if (record.node_id !== null) fail(`${path}.node_id`, "scope-exit join node must be null");
      semanticId(record.task_id, `${path}.task_id`);
      if (record.id !== joinId(record)) fail(`${path}.id`, "JoinId preimage mismatch");
      joins.push(record);
      return;
    }
    if (record.record === "place") {
      exactKeys(record, [
        "base_binding_id", "canonical_bytes", "display", "id", "projections", "record",
      ], path);
      const normalized = normalizePlace({
        base_binding_id: record.base_binding_id,
        display: record.display,
        kind: "place",
        projections: record.projections,
      }, path, LIMITS.projection_depth);
      const bytes = canonicalPlaceBytes(normalized);
      if (record.canonical_bytes !== bytes.toString("hex")) {
        fail(`${path}.canonical_bytes`, "place bytes do not match the structured place");
      }
      if (record.id !== placeId(bytes)) fail(`${path}.id`, "PlaceId preimage mismatch");
      places.push(record);
      return;
    }
    if (record.record === "unknown") {
      exactKeys(record, [
        "canonical_bytes", "id", "reason", "record", "task_id", "witness_node_id",
      ], path);
      semanticId(record.task_id, `${path}.task_id`);
      semanticId(record.witness_node_id, `${path}.witness_node_id`);
      if (!UNKNOWN_REASONS.has(record.reason)) fail(`${path}.reason`, "unknown reason is invalid");
      const bytes = canonicalUnknownBytes(record.task_id, record.reason, record.witness_node_id);
      if (record.canonical_bytes !== bytes.toString("hex")) {
        fail(`${path}.canonical_bytes`, "unknown bytes do not match the structured unknown");
      }
      if (record.id !== unknownId(record.task_id, record.reason, record.witness_node_id)) {
        fail(`${path}.id`, "UnknownId preimage mismatch");
      }
      unknowns.push(record);
      return;
    }
    exactKeys(record, [
      "id", "mode", "origins", "record", "target_id", "target_kind", "task_id",
    ], path);
    normalizeMode(record.mode, `${path}.mode`);
    if (!new Set(["place", "unknown"]).has(record.target_kind)) {
      fail(`${path}.target_kind`, "expected place or unknown");
    }
    semanticId(record.target_id, `${path}.target_id`);
    semanticId(record.task_id, `${path}.task_id`);
    const origins = array(record.origins, `${path}.origins`, LIMITS.origins_per_capture)
      .map((origin, originIndex) => normalizeOrigin(origin, `${path}.origins[${originIndex}]`));
    if (origins.length === 0) fail(`${path}.origins`, "a capture must name at least one origin");
    const originNodeIds = new Set();
    for (const origin of origins) {
      const committedSpan = originSpans.get(origin.node_id);
      if (
        committedSpan !== undefined &&
        (committedSpan.start !== origin.span.start || committedSpan.end !== origin.span.end)
      ) {
        fail(`${path}.origins`, "one origin NodeId must not carry two source spans");
      }
      originSpans.set(origin.node_id, origin.span);
      if (originNodeIds.has(origin.node_id)) {
        fail(`${path}.origins`, "origin NodeIds must be unique");
      }
      originNodeIds.add(origin.node_id);
    }
    for (let originIndex = 1; originIndex < origins.length; originIndex += 1) {
      if (originOrder(origins[originIndex - 1], origins[originIndex]) >= 0) {
        fail(`${path}.origins`, "origins must be unique in source order");
      }
    }
    if (record.id !== captureId(record.task_id, record.target_kind, record.target_id)) {
      fail(`${path}.id`, "CaptureId preimage mismatch");
    }
    captures.push(record);
  });

  pars.forEach((record, index) => {
    if (record.lexical_index !== index) fail("$hir.records", "par order is noncanonical");
    const earlierScopes = new Set(pars.slice(0, index).map((par) => par.scope_id));
    if (record.parent_scope_id !== rootScopeId && !earlierScopes.has(record.parent_scope_id)) {
      fail("$hir.records", "par parent link is not closed to root or an earlier par");
    }
  });
  const parOrder = new Map(pars.map((record, index) => [record.id, index]));
  const tasksByPar = new Map();
  for (const task of tasks) {
    if (!parOrder.has(task.par_id)) fail("$hir.records", "task links to an unknown par");
    const group = tasksByPar.get(task.par_id) ?? [];
    group.push(task);
    tasksByPar.set(task.par_id, group);
  }
  for (const [par, group] of tasksByPar) {
    group.forEach((task, index) => {
      if (task.lexical_index !== index) fail("$hir.records", `task indexes for ${par} are not dense`);
    });
  }
  const expectedTasks = [...tasks].sort((left, right) =>
    parOrder.get(left.par_id) - parOrder.get(right.par_id) ||
    left.lexical_index - right.lexical_index);
  if (expectedTasks.some((task, index) => task.id !== tasks[index]?.id)) {
    fail("$hir.records", "task order is noncanonical");
  }
  const taskOrder = new Map(tasks.map((record, index) => [record.id, index]));
  if (joins.length !== tasks.length) fail("$hir.records", "every task must have exactly one join");
  const joined = new Set();
  joins.forEach((join, index) => {
    if (!taskOrder.has(join.task_id)) fail("$hir.records", "join links to an unknown task");
    if (joined.has(join.task_id)) fail("$hir.records", "task has duplicate joins");
    joined.add(join.task_id);
    if (join.task_id !== tasks[index].id) fail("$hir.records", "join order is noncanonical");
  });
  for (let index = 1; index < places.length; index += 1) {
    if (compareText(places[index - 1].canonical_bytes, places[index].canonical_bytes) >= 0) {
      fail("$hir.records", "place order is noncanonical or duplicated");
    }
  }
  for (let index = 1; index < unknowns.length; index += 1) {
    if (compareText(unknowns[index - 1].canonical_bytes, unknowns[index].canonical_bytes) >= 0) {
      fail("$hir.records", "unknown order is noncanonical or duplicated");
    }
  }
  const targetBytes = new Map([
    ...places.map((record) => [record.id, { kind: "place", bytes: record.canonical_bytes }]),
    ...unknowns.map((record) => [record.id, {
      kind: "unknown",
      bytes: record.canonical_bytes,
      task_id: record.task_id,
      witness_node_id: record.witness_node_id,
    }]),
  ]);
  const captureKeys = new Set();
  const captureCount = new Map();
  for (const capture of captures) {
    if (!taskOrder.has(capture.task_id)) fail("$hir.records", "capture links to an unknown task");
    const target = targetBytes.get(capture.target_id);
    if (target === undefined || target.kind !== capture.target_kind) {
      fail("$hir.records", "capture target link is not closed");
    }
    if (target.kind === "unknown" && target.task_id !== capture.task_id) {
      fail("$hir.records", "unknown capture belongs to another task");
    }
    if (
      target.kind === "unknown" &&
      (capture.origins.length !== 1 || capture.origins[0].node_id !== target.witness_node_id)
    ) {
      fail("$hir.records", "unknown capture must have exactly its witness NodeId as its origin");
    }
    const key = `${capture.task_id}:${capture.target_kind}:${capture.target_id}`;
    if (captureKeys.has(key)) fail("$hir.records", "duplicate exact capture was not merged");
    captureKeys.add(key);
    captureCount.set(capture.task_id, (captureCount.get(capture.task_id) ?? 0) + 1);
  }
  for (const count of captureCount.values()) {
    if (count > LIMITS.captures_per_task) fail("$hir.records", "capture limit exceeded");
  }
  const expectedCaptures = [...captures].sort((left, right) =>
    taskOrder.get(left.task_id) - taskOrder.get(right.task_id) ||
    compareText(targetBytes.get(left.target_id).bytes, targetBytes.get(right.target_id).bytes) ||
    MODE_RANK[left.mode] - MODE_RANK[right.mode]);
  if (expectedCaptures.some((capture, index) => capture.id !== captures[index]?.id)) {
    fail("$hir.records", "capture order is noncanonical");
  }
  if (Buffer.byteLength(canonicalJson(document), "utf8") > LIMITS.document_bytes) {
    fail("$hir", "canonical document byte limit exceeded");
  }
  return true;
}

const WIRE = Object.freeze({ bytes: 1, id: 3, u8: 4, u32: 5, "id-list": 8 });

function wireField(tag, wire, payload) {
  if (payload.length > KSE2_LIMITS.field_bytes) {
    fail("$kse.events", `field exceeds ${KSE2_LIMITS.field_bytes} bytes`);
  }
  return Buffer.concat([
    Buffer.from([tag, WIRE[wire]]),
    u16(0),
    u32(payload.length),
    payload,
  ]);
}

function eventFrame(kind, fields) {
  const payload = Buffer.concat(fields.map(([tag, wire, bytes]) => wireField(tag, wire, bytes)));
  return Buffer.concat([Buffer.from([kind, 0]), u16(fields.length), u32(payload.length), payload]);
}

function encodeEvent(event) {
  switch (event.event) {
    case "par":
      return eventFrame(8, [
        [1, "id", idBytes(event.par_id)],
        [2, "id", idBytes(event.node_id)],
        [3, "id", idBytes(event.scope_id)],
        [4, "id", idBytes(event.parent_scope_id)],
        [5, "id", idBytes(event.scope_token_binding_id)],
        [6, "u32", u32(event.lexical_index)],
      ]);
    case "task":
      return eventFrame(9, [
        [1, "id", idBytes(event.task_id)],
        [2, "id", idBytes(event.par_id)],
        [3, "id", idBytes(event.spawn_node_id)],
        [4, "id", idBytes(event.lambda_node_id)],
        [5, "id", idBytes(event.handle_binding_id)],
        [6, "u32", u32(event.lexical_index)],
      ]);
    case "join": {
      const fields = [
        [1, "id", idBytes(event.join_id)],
        [2, "id", idBytes(event.task_id)],
        [3, "u8", Buffer.from([event.join_kind === "explicit" ? 1 : 2])],
      ];
      if (event.node_id !== null) fields.push([4, "id", idBytes(event.node_id)]);
      return eventFrame(10, fields);
    }
    case "place":
      return eventFrame(11, [
        [1, "id", idBytes(event.place_id)],
        [2, "id", idBytes(event.base_binding_id)],
        [3, "bytes", Buffer.from(event.canonical_bytes, "hex")],
      ]);
    case "unknown":
      return eventFrame(12, [
        [1, "id", idBytes(event.unknown_id)],
        [2, "id", idBytes(event.task_id)],
        [3, "id", idBytes(event.witness_node_id)],
        [4, "u8", Buffer.from([UNKNOWN_REASON_TAG[event.reason]])],
        [5, "bytes", Buffer.from(event.canonical_bytes, "hex")],
      ]);
    case "capture":
      return eventFrame(13, [
        [1, "id", idBytes(event.capture_id)],
        [2, "id", idBytes(event.task_id)],
        [3, "u8", Buffer.from([event.target_kind === "place" ? 1 : 2])],
        [4, "id", idBytes(event.target_id)],
        [5, "u8", Buffer.from([MODE_RANK[event.mode] + 1])],
        [6, "id-list", Buffer.concat(event.origin_node_ids.map((id) => idBytes(id)))],
      ]);
    default:
      fail("$kse.events", "unknown capture event");
  }
}

function eventFromRecord(record) {
  if (record.record === "par") {
    return {
      event: "par",
      kind: 8,
      lexical_index: record.lexical_index,
      node_id: record.node_id,
      par_id: record.id,
      parent_scope_id: record.parent_scope_id,
      scope_id: record.scope_id,
      scope_token_binding_id: record.scope_token_binding_id,
    };
  }
  if (record.record === "task") {
    return {
      event: "task",
      handle_binding_id: record.handle_binding_id,
      kind: 9,
      lambda_node_id: record.lambda_node_id,
      lexical_index: record.lexical_index,
      par_id: record.par_id,
      spawn_node_id: record.spawn_node_id,
      task_id: record.id,
    };
  }
  if (record.record === "join") {
    return {
      event: "join",
      join_id: record.id,
      join_kind: record.join_kind,
      kind: 10,
      node_id: record.node_id,
      task_id: record.task_id,
    };
  }
  if (record.record === "place") {
    return {
      base_binding_id: record.base_binding_id,
      canonical_bytes: record.canonical_bytes,
      event: "place",
      kind: 11,
      place_id: record.id,
      projections: record.projections.map((projection) => {
        if (projection.kind === "field") {
          return {
            kind: "field",
            ordinal: projection.ordinal,
            owner_type_id: projection.owner_type_id,
          };
        }
        return clone(projection);
      }),
    };
  }
  if (record.record === "unknown") {
    return {
      canonical_bytes: record.canonical_bytes,
      event: "unknown",
      kind: 12,
      reason: record.reason,
      task_id: record.task_id,
      unknown_id: record.id,
      witness_node_id: record.witness_node_id,
    };
  }
  return {
    capture_id: record.id,
    event: "capture",
    kind: 13,
    mode: record.mode,
    origin_node_ids: record.origins.map((origin) => origin.node_id),
    target_id: record.target_id,
    target_kind: record.target_kind,
    task_id: record.task_id,
  };
}

export function projectKse2CaptureSection(hir) {
  validateScopeHir(hir);
  const events = hir.records.map(eventFromRecord).map((event) => ({
    ...event,
    wire_hex: encodeEvent(event).toString("hex"),
  }));
  const section = {
    capture_frames_hex: events.map((event) => event.wire_hex).join(""),
    events,
    file_id: hir.file_id,
    limits: { ...KSE2_LIMITS },
    profile: PROFILE,
    root_scope_id: hir.root_scope_id,
    schema: KSE_SCHEMA,
    section: "scoped-captures",
  };
  return deepFreeze(section);
}

export function validateKse2CaptureSection(section, hir) {
  if (hir === undefined) {
    fail("$kse", "matching scope-HIR is required for semantic KSE2 projection validation");
  }
  exactKeys(section, [
    "capture_frames_hex", "events", "file_id", "limits", "profile", "root_scope_id", "schema", "section",
  ], "$kse");
  if (section.schema !== KSE_SCHEMA) fail("$kse.schema", `expected ${KSE_SCHEMA}`);
  if (section.profile !== PROFILE) fail("$kse.profile", `expected ${PROFILE}`);
  if (section.section !== "scoped-captures") fail("$kse.section", "expected scoped-captures");
  semanticId(section.file_id, "$kse.file_id");
  semanticId(section.root_scope_id, "$kse.root_scope_id");
  exactKeys(section.limits, Object.keys(KSE2_LIMITS), "$kse.limits");
  for (const [name, expected] of Object.entries(KSE2_LIMITS)) {
    if (section.limits[name] !== expected) fail(`$kse.limits.${name}`, `expected ${expected}`);
  }
  array(section.events, "$kse.events", KSE2_LIMITS.capture_events);
  for (const [index, event] of section.events.entries()) {
    if (!Number.isSafeInteger(event.kind) || event.kind < 8 || event.kind > 13) {
      fail(`$kse.events[${index}].kind`, "capture event kind must be 8 through 13");
    }
    if (event.event === "capture") {
      const origins = array(
        event.origin_node_ids,
        `$kse.events[${index}].origin_node_ids`,
        KSE2_LIMITS.relations,
      );
      if (origins.length === 0) {
        fail(`$kse.events[${index}].origin_node_ids`, "a capture must name an origin");
      }
      const seen = new Set();
      for (const [originIndex, origin] of origins.entries()) {
        semanticId(origin, `$kse.events[${index}].origin_node_ids[${originIndex}]`);
        if (seen.has(origin)) {
          fail(`$kse.events[${index}].origin_node_ids`, "origin NodeIds must be unique");
        }
        seen.add(origin);
      }
    }
    const encoded = encodeEvent(event).toString("hex");
    if (event.wire_hex !== encoded) fail(`$kse.events[${index}].wire_hex`, "event wire bytes mismatch");
  }
  if (section.capture_frames_hex !== section.events.map((event) => event.wire_hex).join("")) {
    fail("$kse.capture_frames_hex", "capture frame concatenation mismatch");
  }
  if (Buffer.byteLength(section.capture_frames_hex, "hex") > KSE2_LIMITS.event_bytes) {
    fail("$kse.capture_frames_hex", "KSE2 event-byte limit exceeded");
  }
  const expected = projectKse2CaptureSection(hir);
  if (canonicalJson(section) !== canonicalJson(expected)) {
    fail("$kse", "capture section does not exactly project the scope-HIR document");
  }
  return true;
}

function projectedPlace(record) {
  return {
    base_binding_id: record.base_binding_id,
    canonical_bytes: record.canonical_bytes,
    id: record.id,
    projections: record.projections.map((projection) => {
      if (projection.kind === "field") {
        return {
          kind: "field",
          ordinal: projection.ordinal,
          owner_type_id: projection.owner_type_id,
        };
      }
      return clone(projection);
    }),
  };
}

export function projectTypedSidecarCaptures(hir) {
  validateScopeHir(hir);
  const places = new Map(hir.records.filter(({ record }) => record === "place")
    .map((record) => [record.id, record]));
  const unknowns = new Map(hir.records.filter(({ record }) => record === "unknown")
    .map((record) => [record.id, record]));
  return deepFreeze(hir.records.filter(({ record }) => record === "capture")
    .map((capture) => ({
      id: capture.id,
      mode: capture.mode,
      origin_node_ids: capture.origins.map((origin) => origin.node_id),
      target: capture.target_kind === "place"
        ? { kind: "place", place: projectedPlace(places.get(capture.target_id)) }
        : {
            kind: "unknown",
            unknown: {
              canonical_bytes: unknowns.get(capture.target_id).canonical_bytes,
              id: capture.target_id,
              reason: unknowns.get(capture.target_id).reason,
              witness_node_id: unknowns.get(capture.target_id).witness_node_id,
            },
          },
      task_id: capture.task_id,
    })));
}

const V1_ROOT_FIELDS = Object.freeze([
  "authoritative", "compiler", "completeness", "diagnostics", "file", "generation",
  "limits", "nodes", "references", "schema", "source_status",
]);

export function projectTypedSidecarV2(v1Document, hir) {
  exactKeys(v1Document, V1_ROOT_FIELDS, "$typed-v1");
  if (v1Document.schema !== "kofun.typed-sidecar/v1") {
    fail("$typed-v1.schema", "base document must be typed-sidecar v1");
  }
  if (v1Document.authoritative !== false) fail("$typed-v1.authoritative", "sidecar must be non-authoritative");
  if (v1Document.limits?.profile !== "default-v1") {
    fail("$typed-v1.limits.profile", "base document must use default-v1");
  }
  const sidecarFileId = semanticId(v1Document.file?.file_id, "$typed-v1.file.file_id");
  if (sidecarFileId !== hir.file_id) {
    fail("$typed-v1.file.file_id", "base sidecar and scope-HIR must name the same file");
  }
  const result = clone(v1Document);
  result.capture_profile = PROFILE;
  result.captures = clone(projectTypedSidecarCaptures(hir));
  result.limits.profile = SIDECAR_V2_LIMITS.profile;
  result.schema = SIDECAR_SCHEMA;
  validateTypedSidecarV2(result, hir);
  return deepFreeze(result);
}

function rejectDisplayLeak(value, path) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => rejectDisplayLeak(item, `${path}[${index}]`));
    return;
  }
  if (!isObject(value)) return;
  for (const [key, nested] of Object.entries(value)) {
    if (["display", "label", "name", "text"].includes(key)) {
      fail(`${path}.${key}`, "capture projection must not expose display names");
    }
    rejectDisplayLeak(nested, `${path}.${key}`);
  }
}

export function validateTypedSidecarV2(document, hir) {
  exactKeys(document, [...V1_ROOT_FIELDS, "capture_profile", "captures"], "$typed-v2");
  if (document.schema !== SIDECAR_SCHEMA) fail("$typed-v2.schema", `expected ${SIDECAR_SCHEMA}`);
  if (document.capture_profile !== PROFILE) fail("$typed-v2.capture_profile", `expected ${PROFILE}`);
  if (document.authoritative !== false) fail("$typed-v2.authoritative", "sidecar must be non-authoritative");
  exactKeys(document.limits, Object.keys(SIDECAR_V2_LIMITS), "$typed-v2.limits");
  for (const [name, expected] of Object.entries(SIDECAR_V2_LIMITS)) {
    if (document.limits[name] !== expected) {
      fail(`$typed-v2.limits.${name}`, `expected ${expected}`);
    }
  }
  const sidecarFileId = semanticId(document.file?.file_id, "$typed-v2.file.file_id");
  if (sidecarFileId !== hir.file_id) {
    fail("$typed-v2.file.file_id", "sidecar and scope-HIR must name the same file");
  }
  array(document.captures, "$typed-v2.captures", LIMITS.tasks * LIMITS.captures_per_task);
  rejectDisplayLeak(document.captures, "$typed-v2.captures");
  const expected = projectTypedSidecarCaptures(hir);
  if (canonicalJson(document.captures) !== canonicalJson(expected)) {
    fail("$typed-v2.captures", "capture projection does not exactly match scope-HIR");
  }
  if (Buffer.byteLength(canonicalJson(document), "utf8") > SIDECAR_V2_LIMITS.document_bytes) {
    fail("$typed-v2", "typed-sidecar v2 document byte limit exceeded");
  }
  if (structuralDepth(document) > SIDECAR_V2_LIMITS.max_depth) {
    fail("$typed-v2", "typed-sidecar v2 structural depth limit exceeded");
  }
  return true;
}

export function analyzeCaptureContract(input) {
  const scopeHir = buildScopeHir(input);
  return deepFreeze({
    kse2_capture_section: projectKse2CaptureSection(scopeHir),
    schema: "kofun.scoped-capture-contract-result/v1",
    scope_hir: scopeHir,
    typed_sidecar_captures: projectTypedSidecarCaptures(scopeHir),
  });
}

function main(argv) {
  if (argv.length !== 1) {
    process.stderr.write("usage: node model.mjs FIXTURE.json\n");
    return 2;
  }
  let bytes;
  try {
    bytes = readFileSync(argv[0]);
  } catch (error) {
    process.stderr.write(`scoped-capture contract: ${error.message}\n`);
    return 2;
  }
  if (bytes.length > LIMITS.document_bytes) {
    process.stderr.write("scoped-capture contract: input byte limit exceeded\n");
    return 2;
  }
  try {
    const input = JSON.parse(bytes.toString("utf8"));
    process.stdout.write(canonicalJson(analyzeCaptureContract(input)));
    return 0;
  } catch (error) {
    process.stderr.write(`scoped-capture contract: ${error.message}\n`);
    return 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = main(process.argv.slice(2));
}

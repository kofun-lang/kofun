import crypto from "node:crypto";
import fs from "node:fs";

import {
  TYPED_SIDECAR_LIMITS,
  encodeTypedSidecar,
  readTypedSidecar,
  writeTypedSidecarAtomic,
} from "./codec.mjs";
import {
  KSE2_LIMITS,
  decodeCaptureFrames,
  encodeCaptureEvent,
  projectSidecarV2,
  validateCaptureStream,
} from "./captures.mjs";

export const STAGE2_SEMANTIC_EVENT_LIMITS = Object.freeze({
  events: 4096,
  payloadBytes: 4 * 1024 * 1024,
  streamBytes: 4 * 1024 * 1024 + 48,
  textBytes: 4096,
  relations: 64,
});

const LIMITS = STAGE2_SEMANTIC_EVENT_LIMITS;
export const STAGE2_SEMANTIC_EVENT_V2_LIMITS = Object.freeze({
  events: KSE2_LIMITS.events,
  payloadBytes: KSE2_LIMITS.event_bytes,
  streamBytes: KSE2_LIMITS.event_bytes + 48,
  textBytes: KSE2_LIMITS.field_bytes,
  // Only capture origins use the successor's 256-ID relation bound.
  relations: LIMITS.relations,
});
const V1_PROFILE = Object.freeze({ major: 1, limits: LIMITS });
const V2_PROFILE = Object.freeze({ major: 2, limits: STAGE2_SEMANTIC_EVENT_V2_LIMITS });
const V2_PHASE = Object.freeze({
  1: 1, 2: 2, 3: 3, 8: 4, 9: 5, 10: 6, 11: 7, 12: 8, 13: 9,
  4: 10, 5: 11, 6: 12, 7: 13,
});
const MAX_SAFE_INTEGER = BigInt(Number.MAX_SAFE_INTEGER);
const ZERO_ID = "0".repeat(64);
const PUBLIC_REASONS = new Set([
  "cancelled-before-analysis",
  "effect-io-callee",
  "effect-io-root-print",
  "move-after-borrow",
  "type-not-available-in-current-subset",
  "unresolved-current-stage2-reference",
  "unsupported-current-stage2-feature",
  "visibility-restricted",
]);
const STATUS = Object.freeze({
  1: "validated",
  2: "provisional",
  3: "error",
  4: "unavailable",
});
const NODE_KIND = Object.freeze({
  1: "module.root",
  2: "function.declaration",
  3: "parameter.binding",
  4: "lexical.scope",
  5: "local.binding",
  6: "adt.declaration",
  7: "constructor.declaration",
  8: "call.expression",
  9: "name.reference",
  10: "if.expression",
  11: "match.expression",
  12: "parser.error-pattern",
});
const IDENTITY_KIND = Object.freeze({
  1: "PackageId",
  2: "ModuleId",
  3: "FileId",
  4: "ScopeId",
  5: "BindingId",
  6: "NamespaceId",
  7: "SymbolId",
  8: "TypeId",
  // typed-sidecar v1 models constructors in the value namespace as SymbolId.
  9: "SymbolId",
});
const FACT_KIND = Object.freeze({
  1: "type",
  2: "effect",
  3: "ownership",
  4: "origin",
});
const NAMESPACE = Object.freeze({
  1: "value",
  2: "type",
  // typed-sidecar v1 has no separate constructor namespace.
  3: "value",
});
const SEVERITY = Object.freeze({
  1: "error",
  2: "warning",
  3: "information",
});
const SOURCE_STATUS = Object.freeze({
  1: "checked",
  2: "failed",
  3: "cancelled",
});
const COMPLETENESS = Object.freeze({
  1: "complete",
  2: "partial",
});
const WIRE = Object.freeze({
  bytes: 1,
  utf8: 2,
  id: 3,
  u8: 4,
  u32: 5,
  u64: 6,
  span: 7,
  ids: 8,
  u32s: 9,
});
const EVENT_FIELDS = Object.freeze({
  1: Object.freeze([
    [1, WIRE.id], [2, WIRE.id], [3, WIRE.id], [4, WIRE.utf8],
    [5, WIRE.u64], [6, WIRE.id], [7, WIRE.utf8], [8, WIRE.utf8],
    [9, WIRE.u64], [10, WIRE.u8],
  ]),
  2: Object.freeze([
    [1, WIRE.id], [2, WIRE.u8], [3, WIRE.span], [4, WIRE.u8],
    [5, WIRE.ids], [6, WIRE.ids],
  ]),
  3: Object.freeze([
    [1, WIRE.id], [2, WIRE.u8], [3, WIRE.id], [4, WIRE.u8],
  ]),
  4: Object.freeze([
    [1, WIRE.id], [2, WIRE.id], [3, WIRE.u8], [4, WIRE.span],
    [5, WIRE.u8], [6, WIRE.u8], [7, WIRE.u8],
  ]),
  5: Object.freeze([
    [1, WIRE.id], [2, WIRE.u8], [3, WIRE.u8], [4, WIRE.utf8],
    [5, WIRE.utf8], [6, WIRE.ids], [7, WIRE.ids],
  ]),
  6: Object.freeze([
    [1, WIRE.id], [2, WIRE.utf8], [3, WIRE.utf8], [4, WIRE.u8],
    [5, WIRE.utf8], [6, WIRE.id], [7, WIRE.span], [8, WIRE.utf8],
    [9, WIRE.ids], [10, WIRE.u32s], [11, WIRE.u8],
    [12, WIRE.bytes], [13, WIRE.bytes],
  ]),
  7: Object.freeze([[1, WIRE.u8], [2, WIRE.u8]]),
});

class ProjectionFailure extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "ProjectionFailure";
    this.code = code;
    this.details = details;
  }
}

function fail(code, message, details = {}) {
  throw new ProjectionFailure(code, message, details);
}

function bounded(value, maximum) {
  const text = String(value);
  return text.length <= maximum ? text : `${text.slice(0, maximum - 3)}...`;
}

function errorResult(error, fallback = "ETS03") {
  const code = error instanceof ProjectionFailure ? error.code :
    error instanceof RangeError ? "ETS04" : fallback;
  const message = error instanceof ProjectionFailure ? error.message :
    code === "ETS04" ? "semantic event resource limit exceeded" :
      "semantic event projection failed";
  const result = { code, message: bounded(message, 256) };
  const details = error instanceof ProjectionFailure ? error.details : {};
  if (Number.isSafeInteger(details.record) && details.record >= 0) {
    result.record = details.record;
  }
  if (Number.isSafeInteger(details.eventKind) && details.eventKind >= 0) {
    result.event_kind = details.eventKind;
  }
  if (typeof details.reason === "string") {
    result.reason = bounded(details.reason, 64);
  }
  return Object.freeze({ ok: false, error: Object.freeze(result) });
}

function successResult(field, value) {
  return Object.freeze({ ok: true, [field]: value });
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

function byteView(bytes) {
  if (Buffer.isBuffer(bytes)) return bytes;
  if (bytes instanceof Uint8Array) {
    return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }
  if (bytes instanceof ArrayBuffer) return Buffer.from(bytes);
  throw new TypeError("Stage 2 semantic events must be Buffer, Uint8Array, or ArrayBuffer");
}

function checkedEnd(cursor, length, limit, code, message, details) {
  if (!Number.isSafeInteger(length) || length < 0 || cursor > limit ||
      length > limit - cursor) {
    fail(code, message, details);
  }
  return cursor + length;
}

function readU16(bytes, offset) {
  return bytes.readUInt16BE(offset);
}

function readU32(bytes, offset) {
  return bytes.readUInt32BE(offset);
}

function decodeText(bytes, record, eventKind, limits = LIMITS) {
  if (bytes.length > limits.textBytes) {
    fail("ETS04", `semantic event text exceeds the v${limits === LIMITS ? 1 : 2} byte limit`, {
      record, eventKind,
    });
  }
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: limits !== LIMITS }).decode(bytes);
  } catch {
    fail("ETS04", "semantic event text is not valid UTF-8", {
      record, eventKind,
    });
  }
  if (text.normalize("NFC") !== text) {
    fail("ETS04", "semantic event text is not NFC", { record, eventKind });
  }
  return text;
}

function decodeId(bytes) {
  return bytes.toString("hex");
}

function decodeU64(bytes, record, eventKind) {
  const value = bytes.readBigUInt64BE(0);
  if (value > MAX_SAFE_INTEGER) {
    fail("ETS03", "semantic event integer is not safely representable", {
      record, eventKind,
    });
  }
  return Number(value);
}

function decodeIds(bytes, record, eventKind) {
  if (bytes.length % 32 !== 0 || bytes.length / 32 > LIMITS.relations) {
    fail("ETS04", "semantic event relation list exceeds the v1 limit", {
      record, eventKind,
    });
  }
  const values = [];
  for (let offset = 0; offset < bytes.length; offset += 32) {
    values.push(decodeId(bytes.subarray(offset, offset + 32)));
  }
  return values;
}

function decodeU32s(bytes, record, eventKind) {
  if (bytes.length % 4 !== 0 || bytes.length / 4 > LIMITS.relations) {
    fail("ETS04", "semantic event remedy list exceeds the v1 limit", {
      record, eventKind,
    });
  }
  const values = [];
  for (let offset = 0; offset < bytes.length; offset += 4) {
    values.push(readU32(bytes, offset));
  }
  return values;
}

function decodeRelated(bytes, record, eventKind, limits = LIMITS) {
  if (bytes.length < 2) {
    fail("ETS03", "truncated diagnostic related-location list", {
      record, eventKind,
    });
  }
  const count = readU16(bytes, 0);
  if (count > LIMITS.relations) {
    fail("ETS04", "diagnostic related-location count exceeds the v1 limit", {
      record, eventKind,
    });
  }
  const values = [];
  let cursor = 2;
  for (let index = 0; index < count; index += 1) {
    let end = checkedEnd(
      cursor, 42, bytes.length, "ETS03",
      "truncated diagnostic related-location record", { record, eventKind },
    );
    const fileId = decodeId(bytes.subarray(cursor, cursor + 32));
    const span = Object.freeze({
      start: readU32(bytes, cursor + 32),
      end: readU32(bytes, cursor + 36),
    });
    const labelLength = readU16(bytes, cursor + 40);
    cursor = end;
    end = checkedEnd(
      cursor, labelLength, bytes.length, "ETS03",
      "truncated diagnostic related-location label", { record, eventKind },
    );
    const label = decodeText(bytes.subarray(cursor, end), record, eventKind, limits);
    values.push(Object.freeze({ file_id: fileId, span, label }));
    cursor = end;
  }
  if (cursor !== bytes.length) {
    fail("ETS03", "diagnostic related-location list has trailing bytes", {
      record, eventKind,
    });
  }
  return values;
}

function decodeEdits(bytes, record, eventKind, limits = LIMITS) {
  if (bytes.length < 2) {
    fail("ETS03", "truncated diagnostic edit list", { record, eventKind });
  }
  const count = readU16(bytes, 0);
  if (count > LIMITS.relations) {
    fail("ETS04", "diagnostic edit count exceeds the v1 limit", {
      record, eventKind,
    });
  }
  const values = [];
  let cursor = 2;
  for (let index = 0; index < count; index += 1) {
    let end = checkedEnd(
      cursor, 46, bytes.length, "ETS03",
      "truncated diagnostic edit record", { record, eventKind },
    );
    const remedy_id = readU32(bytes, cursor);
    const file_id = decodeId(bytes.subarray(cursor + 4, cursor + 36));
    const span = Object.freeze({
      start: readU32(bytes, cursor + 36),
      end: readU32(bytes, cursor + 40),
    });
    const replacementLength = readU16(bytes, cursor + 44);
    cursor = end;
    end = checkedEnd(
      cursor, replacementLength, bytes.length, "ETS03",
      "truncated diagnostic edit replacement", { record, eventKind },
    );
    const replacement = decodeText(
      bytes.subarray(cursor, end), record, eventKind, limits,
    );
    values.push(Object.freeze({ remedy_id, file_id, span, replacement }));
    cursor = end;
  }
  if (cursor !== bytes.length) {
    fail("ETS03", "diagnostic edit list has trailing bytes", {
      record, eventKind,
    });
  }
  return values;
}

function decodeField(field, record, eventKind, limits = LIMITS) {
  const { wire, bytes } = field;
  if ((wire === WIRE.bytes || wire === WIRE.utf8) &&
      bytes.length > limits.textBytes) {
    fail("ETS04", `semantic event field exceeds the v${limits === LIMITS ? 1 : 2} byte limit`, {
      record, eventKind,
    });
  }
  if (wire === WIRE.id && bytes.length !== 32) {
    fail("ETS04", "semantic event ID has the wrong length", {
      record, eventKind,
    });
  }
  if (wire === WIRE.u8 && bytes.length !== 1) {
    fail("ETS04", "semantic event u8 has the wrong length", {
      record, eventKind,
    });
  }
  if (wire === WIRE.u32 && bytes.length !== 4) {
    fail("ETS04", "semantic event u32 has the wrong length", {
      record, eventKind,
    });
  }
  if ((wire === WIRE.u64 || wire === WIRE.span) && bytes.length !== 8) {
    fail("ETS04", "semantic event fixed-width field has the wrong length", {
      record, eventKind,
    });
  }
  switch (wire) {
    case WIRE.bytes:
      return bytes;
    case WIRE.utf8:
      return decodeText(bytes, record, eventKind, limits);
    case WIRE.id:
      return decodeId(bytes);
    case WIRE.u8:
      return bytes[0];
    case WIRE.u32:
      return readU32(bytes, 0);
    case WIRE.u64:
      return decodeU64(bytes, record, eventKind);
    case WIRE.span:
      return Object.freeze({ start: readU32(bytes, 0), end: readU32(bytes, 4) });
    case WIRE.ids:
      return decodeIds(bytes, record, eventKind);
    case WIRE.u32s:
      return decodeU32s(bytes, record, eventKind);
    default:
      fail("ETS03", "unknown semantic event wire type", {
        record, eventKind,
      });
  }
}

function exactFieldSchema(kind, fields, record) {
  const prefix = EVENT_FIELDS[kind];
  if (!prefix) {
    fail("ETS03", "unknown semantic event kind", { record, eventKind: kind });
  }
  const expectedCount = kind === 4 ? 9 : prefix.length;
  if (fields.length !== expectedCount) {
    fail("ETS03", "semantic event field count does not match v1", {
      record, eventKind: kind,
    });
  }
  for (let index = 0; index < prefix.length; index += 1) {
    const expected = prefix[index];
    const actual = fields[index];
    if (!actual || actual.tag !== expected[0] || actual.wire !== expected[1]) {
      fail("ETS03", "unknown, missing, or out-of-order semantic event field", {
        record, eventKind: kind,
      });
    }
  }
  if (kind === 4) {
    const target = fields[7];
    if (!target || ![8, 9].includes(target.tag) ||
        target.wire !== (target.tag === 8 ? WIRE.id : WIRE.utf8)) {
      fail("ETS03", "reference target field does not match v1", {
        record, eventKind: kind,
      });
    }
    const diagnostics = fields[8];
    if (!diagnostics || diagnostics.tag !== 10 ||
        diagnostics.wire !== WIRE.ids) {
      fail("ETS03", "reference diagnostic field does not match v1", {
        record, eventKind: kind,
      });
    }
  }
}

function recordFromFields(kind, fields, record, limits = LIMITS) {
  const value = (index) => decodeField(fields[index], record, kind, limits);
  switch (kind) {
    case 1:
      return {
        kind: "source",
        package_id: value(0),
        module_id: value(1),
        file_id: value(2),
        logical_path: value(3),
        source_bytes: value(4),
        source_sha256: value(5),
        edition: value(6),
        semantic_compatibility: value(7),
        generation: value(8),
        compiler_exit_class: value(9),
      };
    case 2:
      return {
        kind: "node",
        id: value(0),
        node_kind: value(1),
        span: value(2),
        status: value(3),
        dependencies: value(4),
        diagnostic_ids: value(5),
      };
    case 3:
      return {
        kind: "identity",
        owner_node_id: value(0),
        identity_kind: value(1),
        value: value(2),
        status: value(3),
      };
    case 4:
      return {
        kind: "reference",
        id: value(0),
        source_node_id: value(1),
        namespace: value(2),
        span: value(3),
        status: value(4),
        target_shape: value(5),
        target_kind: value(6),
        target_value: fields[7].tag === 8 ? value(7) : ZERO_ID,
        reason: fields[7].tag === 9 ? value(7) : "",
        diagnostic_ids: value(8),
      };
    case 5:
      return {
        kind: "fact",
        owner_node_id: value(0),
        fact_kind: value(1),
        status: value(2),
        display: value(3),
        reason: value(4),
        dependencies: value(5),
        diagnostic_ids: value(6),
      };
    case 6:
      return {
        kind: "diagnostic",
        id: value(0),
        code: value(1),
        category: value(2),
        severity: value(3),
        template_id: value(4),
        primary_file_id: value(5),
        primary_span: value(6),
        fallback_text: value(7),
        affected_ids: value(8),
        remedy_ids: value(9),
        truncated: value(10),
        related: decodeRelated(fields[11].bytes, record, kind, limits),
        edits: decodeEdits(fields[12].bytes, record, kind, limits),
      };
    case 7:
      return {
        kind: "end",
        source_status: value(0),
        completeness: value(1),
      };
    default:
      fail("ETS03", "unsupported semantic event kind", {
        record, eventKind: kind,
      });
  }
}

function basicRecordValidation(event, record, eventKind) {
  const enumValue = (table, value, message) => {
    if (!Object.hasOwn(table, value)) {
      fail("ETS03", message, { record, eventKind });
    }
  };
  if (event.kind === "source") {
    for (const id of [event.package_id, event.module_id, event.file_id,
      event.source_sha256]) {
      if (id === ZERO_ID) {
        fail("ETS03", "source identity must not be zero", {
          record, eventKind,
        });
      }
    }
    if (event.source_bytes > 0xffff_ffff) {
      fail("ETS04", "source length exceeds the v1 span basis", {
        record, eventKind,
      });
    }
    if (event.compiler_exit_class > 3) {
      fail("ETS03", "compiler exit class is outside 0..3", {
        record, eventKind,
      });
    }
    validateLogicalPath(event.logical_path, record, eventKind);
  } else if (event.kind === "node") {
    enumValue(NODE_KIND, event.node_kind, "unknown node kind");
    enumValue(STATUS, event.status, "unknown node status");
  } else if (event.kind === "identity") {
    enumValue(IDENTITY_KIND, event.identity_kind, "unknown identity kind");
    enumValue(STATUS, event.status, "unknown identity status");
  } else if (event.kind === "reference") {
    enumValue(NAMESPACE, event.namespace, "unknown reference namespace");
    enumValue(STATUS, event.status, "unknown reference status");
    if (![1, 2, 3].includes(event.target_shape)) {
      fail("ETS03", "unknown reference target shape", {
        record, eventKind,
      });
    }
    if (event.target_kind !== 0) {
      enumValue(IDENTITY_KIND, event.target_kind, "unknown target identity kind");
    }
  } else if (event.kind === "fact") {
    enumValue(FACT_KIND, event.fact_kind, "unknown semantic fact kind");
    enumValue(STATUS, event.status, "unknown semantic fact status");
  } else if (event.kind === "diagnostic") {
    enumValue(SEVERITY, event.severity, "unknown diagnostic severity");
    if (event.truncated > 1) {
      fail("ETS03", "diagnostic truncation flag is not boolean", {
        record, eventKind,
      });
    }
  } else if (event.kind === "end") {
    enumValue(SOURCE_STATUS, event.source_status, "unknown source status");
    enumValue(COMPLETENESS, event.completeness, "unknown completeness");
  }
}

function validateLogicalPath(value, record, eventKind) {
  if (value.length === 0 || value.startsWith("/") || value.includes("\\") ||
      /^[A-Za-z][A-Za-z0-9+.-]*:/.test(value) ||
      /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(value)) {
    fail("ETS03", "source logical path is not a safe relative POSIX path", {
      record, eventKind,
    });
  }
  if (value.split("/").some((part) => part === "" || part === "." ||
      part === "..")) {
    fail("ETS03", "source logical path contains a forbidden component", {
      record, eventKind,
    });
  }
}

function readSemanticEventBytes(input, profile) {
  const limits = profile.limits;
  let bytes;
  try {
    bytes = byteView(input);
    if (bytes.length < 48) {
      fail("ETS04", "semantic event stream is truncated");
    }
    if (bytes.length > limits.streamBytes) {
      fail("ETS04", `semantic event stream exceeds the v${profile.major} byte cap`);
    }
    if (!bytes.subarray(0, 4).equals(Buffer.from([0x4b, 0x53, 0x45, 0x00])) ||
        readU16(bytes, 4) !== profile.major || readU16(bytes, 6) !== 0) {
      fail("ETS03", "unknown KSE magic or version");
    }
    const eventCount = readU32(bytes, 8);
    const payloadBytes = readU32(bytes, 12);
    if (eventCount < 2 || eventCount > limits.events ||
        payloadBytes > limits.payloadBytes ||
        payloadBytes + 48 !== bytes.length) {
      fail("ETS04", "semantic event count or payload size is invalid");
    }
    const payloadEnd = 16 + payloadBytes;
    const digest = crypto.createHash("sha256")
      .update(bytes.subarray(0, payloadEnd)).digest();
    if (!crypto.timingSafeEqual(digest, bytes.subarray(payloadEnd))) {
      fail("ETS03", "semantic event stream digest mismatch");
    }
    const events = [];
    let cursor = 16;
    let previousPhase = 0;
    let captureCount = 0;
    for (let record = 0; record < eventCount; record += 1) {
      if (payloadEnd - cursor < 8) {
        fail("ETS03", "truncated semantic event header", { record });
      }
      const frameStart = cursor;
      const kind = bytes[cursor];
      const flags = bytes[cursor + 1];
      const fieldCount = readU16(bytes, cursor + 2);
      const frameBytes = readU32(bytes, cursor + 4);
      cursor += 8;
      if (flags !== 0) {
        fail("ETS03", "unknown semantic event flags", {
          record, eventKind: kind,
        });
      }
      if (fieldCount > 16) {
        fail("ETS04", "semantic event field count exceeds the v1 limit", {
          record, eventKind: kind,
        });
      }
      const frameEnd = checkedEnd(
        cursor, frameBytes, payloadEnd, "ETS04",
        "semantic event frame exceeds the declared payload",
        { record, eventKind: kind },
      );
      let event;
      let fields;
      if (profile.major === 2 && kind >= 8 && kind <= 13) {
        captureCount += 1;
        if (captureCount > KSE2_LIMITS.capture_events) {
          fail("ETS04", "capture event count exceeds the v2 limit", { record, eventKind: kind });
        }
        checkCaptureFrameBounds(bytes, cursor, frameEnd, fieldCount, kind, record);
        event = decodeCaptureFrames(bytes.subarray(frameStart, frameEnd))[0];
        // The section codec is structural. Exact re-encoding additionally closes
        // unknown fields, reserved bytes, tag order and fixed-width padding.
        if (!encodeCaptureEvent(event).equals(bytes.subarray(frameStart, frameEnd))) {
          fail("ETS03", "capture frame is not canonical", { record, eventKind: kind });
        }
        cursor = frameEnd;
      } else {
        fields = [];
        let previousTag = 0;
        for (let field = 0; field < fieldCount; field += 1) {
          if (frameEnd - cursor < 8) {
            fail("ETS03", "truncated semantic event field header", {
              record, eventKind: kind,
            });
          }
          const tag = bytes[cursor];
          const wire = bytes[cursor + 1];
          const reserved = readU16(bytes, cursor + 2);
          const length = readU32(bytes, cursor + 4);
          cursor += 8;
          if (reserved !== 0 || tag <= previousTag || wire < 1 || wire > 9) {
            fail("ETS03", "unknown, duplicate, or out-of-order event field", {
              record, eventKind: kind,
            });
          }
          previousTag = tag;
          if (profile.major === 2 && length > limits.textBytes) {
            fail("ETS04", "semantic event field exceeds the v2 byte limit", { record, eventKind: kind });
          }
          const fieldEnd = checkedEnd(
            cursor, length, frameEnd, "ETS04",
            "semantic event field exceeds its frame",
            { record, eventKind: kind },
          );
          fields.push({ tag, wire, bytes: bytes.subarray(cursor, fieldEnd) });
          cursor = fieldEnd;
        }
        if (cursor !== frameEnd) {
          fail("ETS03", "semantic event frame has trailing bytes", {
            record, eventKind: kind,
          });
        }
        exactFieldSchema(kind, fields, record);
      }
      const phase = profile.major === 1 ? kind : V2_PHASE[kind];
      if (!phase || phase < previousPhase || (record === 0 && kind !== 1) ||
          (record === eventCount - 1 && kind !== 7) ||
          (record !== 0 && kind === 1) ||
          (record !== eventCount - 1 && kind === 7)) {
        fail("ETS03", "semantic event phase order is invalid", {
          record, eventKind: kind,
        });
      }
      previousPhase = phase;
      if (!event) {
        event = recordFromFields(kind, fields, record, limits);
        basicRecordValidation(event, record, kind);
        if (profile.major === 2 && !encodeCommonEvent(event).equals(bytes.subarray(frameStart, frameEnd))) {
          fail("ETS03", "common event frame is not canonical", { record, eventKind: kind });
        }
      }
      events.push(deepFreeze(event));
    }
    if (cursor !== payloadEnd) {
      fail("ETS03", "semantic event stream has trailing payload bytes", {
        record: eventCount,
      });
    }
    return successResult("events", deepFreeze(events));
  } catch (error) {
    if (error instanceof TypeError) throw error;
    return errorResult(error);
  }
}

export function readStage2SemanticEvents(input) {
  return readSemanticEventBytes(input, V1_PROFILE);
}

function assertSortedUnique(values, label) {
  if (!Array.isArray(values)) {
    fail("ETS03", `${label} is not an ID list`);
  }
  if (values.length > LIMITS.relations) {
    fail("ETS04", `${label} exceeds the KSE v1 relation limit`);
  }
  for (let index = 0; index < values.length; index += 1) {
    if (typeof values[index] !== "string" ||
        !/^[0-9a-f]{64}$/.test(values[index]) ||
        values[index] === ZERO_ID ||
        (index > 0 && values[index - 1] >= values[index])) {
      fail("ETS03", `${label} is not a unique canonical ID set`);
    }
  }
}

function validSpan(span, sourceBytes, label) {
  if (!span || !Number.isSafeInteger(span.start) ||
      !Number.isSafeInteger(span.end) || span.start < 0 ||
      span.start > span.end || span.end > sourceBytes) {
    fail("ETS03", `${label} is outside the committed source span basis`);
  }
}

function ensureId(id, label) {
  if (typeof id !== "string" || !/^[0-9a-f]{64}$/.test(id) ||
      id === ZERO_ID) {
    fail("ETS03", `${label} is not a non-zero semantic ID`);
  }
}

function ensureReason(reason, label) {
  if (!PUBLIC_REASONS.has(reason)) {
    fail("ETS03", `${label} is not a public v1 reason discriminator`);
  }
}

function schemaName(value, label) {
  if (typeof value !== "string" || value.normalize("NFC") !== value) {
    fail("ETS03", `${label} is not stable NFC text`);
  }
  let mapped = value.replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/-+/g, "-").replace(/^-|-$/g, "");
  if (!/^[A-Za-z]/.test(mapped)) mapped = `stage2-${mapped}`;
  if (!/^[A-Za-z][A-Za-z0-9._-]*$/.test(mapped) ||
      mapped.length === 0 || mapped.length > 256) {
    fail("ETS04", `${label} cannot fit the typed-sidecar name profile`);
  }
  return mapped;
}

function mapEdition(value) {
  if (value === "2026") return "kofun-2026";
  return schemaName(value, "compiler edition");
}

function tupleCompare(left, right) {
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] < right[index]) return -1;
    if (left[index] > right[index]) return 1;
  }
  return 0;
}

function addRelationSet(target, values) {
  for (const value of values) target.add(value);
}

function mapFact(event) {
  const status = STATUS[event.status];
  const fact = { status };
  if (status === "unavailable") {
    if (event.display !== "" || event.reason === "") {
      fail("ETS03", "unavailable semantic fact carries display or lacks reason");
    }
    ensureReason(event.reason, "semantic fact reason");
    fact.reason = event.reason;
  } else {
    if (event.display === "") {
      fail("ETS03", "available semantic fact has no display");
    }
    fact.display = event.display;
    if (event.reason !== "") {
      ensureReason(event.reason, "semantic fact reason");
      fact.reason = event.reason;
    }
  }
  return fact;
}

function validateReferenceTarget(event, identities) {
  const status = STATUS[event.status];
  const namespaceKinds = {
    1: new Set([5, 7]),
    2: new Set([8]),
    3: new Set([9]),
  };
  if (event.target_kind !== 0 &&
      !namespaceKinds[event.namespace].has(event.target_kind)) {
    fail("ETS03", "reference target kind disagrees with its namespace");
  }
  if (event.target_shape === 1) {
    if (event.target_kind === 0 || event.target_value === ZERO_ID ||
        event.reason !== "" || status !== "validated") {
      fail("ETS03", "visible reference target has unsafe shape or status");
    }
    const identity = identities.get(`${event.target_kind}:${event.target_value}`);
    if (!identity || identity.event.status !== 1) {
      fail("ETS03", "visible reference target identity is absent or unvalidated");
    }
    return {
      declaration_node: identity.event.owner_node_id,
      disclosure: "resolved",
      identity: {
        kind: IDENTITY_KIND[event.target_kind],
        value: event.target_value,
      },
    };
  }
  if (event.target_value !== ZERO_ID || event.reason === "" ||
      status === "validated") {
    fail("ETS03", "non-visible reference target leaks identity or has unsafe status");
  }
  ensureReason(event.reason, "reference target reason");
  if (event.target_shape === 2) {
    if (status !== "unavailable") {
      fail("ETS03", "hidden target requires unavailable reference status");
    }
    const target = { disclosure: "hidden", reason: event.reason };
    if (event.target_kind !== 0) {
      target.identity_kind = IDENTITY_KIND[event.target_kind];
    }
    return target;
  }
  if (event.target_kind !== 0) {
    // typed-sidecar v1 deliberately discloses a safe kind only for hidden
    // targets; unavailable/provisional targets omit it.
  }
  if (status === "provisional") {
    return { disclosure: "provisional", reason: event.reason };
  }
  if (status === "error" || status === "unavailable") {
    return { disclosure: "unavailable", reason: event.reason };
  }
  fail("ETS03", "unavailable target has an incompatible reference status");
}

function mapDiagnostic(event, source, allRecordIds) {
  ensureId(event.id, "diagnostic ID");
  if (!/^[A-Z][A-Z0-9]{0,15}$/.test(event.code)) {
    fail("ETS03", "diagnostic code is outside the typed-sidecar v1 profile");
  }
  validSpan(event.primary_span, source.source_bytes, "diagnostic primary span");
  if (event.primary_file_id !== source.file_id) {
    fail("ETS03", "diagnostic primary location names a different file");
  }
  assertSortedUnique(event.affected_ids, "diagnostic affected IDs");
  for (const affected of event.affected_ids) {
    if (!allRecordIds.has(affected)) {
      fail("ETS03", "diagnostic contains a dangling affected ID");
    }
  }
  for (let index = 1; index < event.remedy_ids.length; index += 1) {
    if (event.remedy_ids[index - 1] >= event.remedy_ids[index]) {
      fail("ETS03", "diagnostic remedy IDs are not unique canonical order");
    }
  }
  const related = event.related.map((item) => {
    if (item.file_id !== source.file_id || item.label === "") {
      fail("ETS03", "related diagnostic location is unsafe");
    }
    validSpan(item.span, source.source_bytes, "related diagnostic span");
    return {
      relation: schemaName(item.label, "diagnostic relation"),
      location: { file_id: item.file_id, span: { ...item.span } },
    };
  });
  for (let index = 1; index < event.related.length; index += 1) {
    const previous = event.related[index - 1];
    const current = event.related[index];
    if (tupleCompare([
      previous.file_id, previous.span.start, previous.span.end, previous.label,
    ], [
      current.file_id, current.span.start, current.span.end, current.label,
    ]) >= 0) {
      fail("ETS03", "diagnostic related locations are not canonical");
    }
  }
  related.sort((left, right) => tupleCompare([
    left.relation, left.location.file_id, left.location.span.start,
    left.location.span.end, "", "",
  ], [
    right.relation, right.location.file_id, right.location.span.start,
    right.location.span.end, "", "",
  ]));
  for (let index = 1; index < related.length; index += 1) {
    if (tupleCompare([
      related[index - 1].relation, related[index - 1].location.file_id,
      related[index - 1].location.span.start,
      related[index - 1].location.span.end,
    ], [
      related[index].relation, related[index].location.file_id,
      related[index].location.span.start, related[index].location.span.end,
    ]) === 0) {
      fail("ETS03", "diagnostic relations collide after schema mapping");
    }
  }
  const editByRemedy = new Map();
  for (let index = 0; index < event.edits.length; index += 1) {
    const edit = event.edits[index];
    if (!event.remedy_ids.includes(edit.remedy_id) ||
        edit.file_id !== source.file_id || editByRemedy.has(edit.remedy_id)) {
      fail("ETS03", "diagnostic edit has a dangling or duplicate remedy");
    }
    validSpan(edit.span, source.source_bytes, "diagnostic edit span");
    if (index > 0) {
      const previous = event.edits[index - 1];
      if (tupleCompare([
        previous.remedy_id, previous.file_id, previous.span.start,
        previous.span.end, previous.replacement,
      ], [
        edit.remedy_id, edit.file_id, edit.span.start, edit.span.end,
        edit.replacement,
      ]) >= 0) {
        fail("ETS03", "diagnostic edits are not canonical");
      }
    }
    editByRemedy.set(edit.remedy_id, edit);
  }
  const remedies = event.remedy_ids.map((id) => {
    const remedy = { id: `stage2-remedy-${id}` };
    const edit = editByRemedy.get(id);
    if (edit) {
      remedy.span = { ...edit.span };
      remedy.replacement = edit.replacement;
    }
    return remedy;
  });
  remedies.sort((left, right) => tupleCompare([
    left.id, left.span?.start ?? -1, left.span?.end ?? -1,
    left.replacement ?? "",
  ], [
    right.id, right.span?.start ?? -1, right.span?.end ?? -1,
    right.replacement ?? "",
  ]));
  return {
    affected_ids: [...event.affected_ids],
    category: schemaName(event.category, "diagnostic category"),
    code: event.code,
    fallback_text: event.fallback_text,
    id: event.id,
    primary: {
      file_id: event.primary_file_id,
      span: { ...event.primary_span },
    },
    related,
    remedies,
    severity: SEVERITY[event.severity],
    template_id: schemaName(event.template_id, "diagnostic template ID"),
    truncated: event.truncated === 1,
  };
}

function semanticProjection(events, limits = LIMITS) {
  if (!Array.isArray(events)) {
    throw new TypeError("Stage 2 semantic events must be an array");
  }
  if (events.length < 2 || events.length > limits.events) {
    fail("ETS04", `semantic event count is outside the v${limits === LIMITS ? 1 : 2} profile`);
  }
  const source = events[0];
  const end = events[events.length - 1];
  if (!source || source.kind !== "source" || !end || end.kind !== "end") {
    fail("ETS03", "semantic event transaction lacks source or end record");
  }
  const phase = {
    source: 1,
    node: 2,
    identity: 3,
    reference: 4,
    fact: 5,
    diagnostic: 6,
    end: 7,
  };
  let previousPhase = 0;
  let previousFactKind = 0;
  for (let index = 0; index < events.length; index += 1) {
    const eventPhase = phase[events[index]?.kind];
    if (!eventPhase || eventPhase < previousPhase ||
        (index === 0 && eventPhase !== 1) ||
        (index === events.length - 1 && eventPhase !== 7) ||
        (index !== 0 && eventPhase === 1) ||
        (index !== events.length - 1 && eventPhase === 7)) {
      fail("ETS03", "semantic event phase order is invalid", { record: index });
    }
    if (events[index].kind === "fact") {
      if (!Number.isSafeInteger(events[index].fact_kind) ||
          events[index].fact_kind < previousFactKind) {
        fail("ETS03", "semantic fact kinds are out of KSE v1 order", {
          record: index,
        });
      }
      previousFactKind = events[index].fact_kind;
    }
    previousPhase = eventPhase;
  }
  ensureId(source.package_id, "source PackageId");
  ensureId(source.module_id, "source ModuleId");
  ensureId(source.file_id, "source FileId");
  ensureId(source.source_sha256, "source SHA-256");
  validateLogicalPath(source.logical_path, 0, 1);
  if (!Number.isSafeInteger(source.source_bytes) || source.source_bytes < 0 ||
      source.source_bytes > 0xffff_ffff ||
      !Number.isSafeInteger(source.generation) || source.generation < 0 ||
      source.generation > Number.MAX_SAFE_INTEGER) {
    fail("ETS04", "source length or generation exceeds typed-sidecar v1");
  }
  if (!Number.isSafeInteger(source.compiler_exit_class) ||
      source.compiler_exit_class < 0 || source.compiler_exit_class > 3) {
    fail("ETS03", "compiler exit class is outside the v1 range");
  }
  const nodes = new Map();
  const identities = new Map();
  const mappedIdentityKeys = new Map();
  const references = new Map();
  const facts = new Map();
  const diagnosticEvents = [];
  const allIds = new Set();
  for (let index = 1; index < events.length - 1; index += 1) {
    const event = events[index];
    if (event === null || typeof event !== "object") {
      fail("ETS03", "semantic event record is not structured data", {
        record: index,
      });
    }
    if (event.kind === "node") {
      ensureId(event.id, "node ID");
      if (!NODE_KIND[event.node_kind] || !STATUS[event.status] ||
          nodes.has(event.id) || allIds.has(event.id)) {
        fail("ETS03", "duplicate or invalid semantic node", { record: index });
      }
      validSpan(event.span, source.source_bytes, "node span");
      assertSortedUnique(event.dependencies, "node dependencies");
      assertSortedUnique(event.diagnostic_ids, "node diagnostic IDs");
      if (event.status === 3 && event.diagnostic_ids.length === 0) {
        fail("ETS03", "error node has no direct diagnostic");
      }
      const mapped = {
        depends_on: new Set(event.dependencies),
        diagnostic_ids: new Set(event.diagnostic_ids),
        id: event.id,
        identities: [],
        kind: NODE_KIND[event.node_kind],
        span: { ...event.span },
        status: STATUS[event.status],
      };
      nodes.set(event.id, { event, mapped });
      allIds.add(event.id);
    } else if (event.kind === "identity") {
      ensureId(event.owner_node_id, "identity owner");
      ensureId(event.value, "identity value");
      if (!IDENTITY_KIND[event.identity_kind] || !STATUS[event.status] ||
          event.status !== 1 || !nodes.has(event.owner_node_id)) {
        fail("ETS03", "semantic identity is not safely representable", {
          record: index,
        });
      }
      const key = `${event.identity_kind}:${event.value}`;
      const ownerKind = `${event.owner_node_id}:${event.identity_kind}`;
      if (identities.has(key) ||
          [...identities.values()].some((item) =>
            `${item.event.owner_node_id}:${item.event.identity_kind}` === ownerKind)) {
        fail("ETS03", "duplicate semantic identity kind or owner", {
          record: index,
        });
      }
      const mappedKey = `${IDENTITY_KIND[event.identity_kind]}:${event.value}`;
      if (mappedIdentityKeys.has(mappedKey) &&
          mappedIdentityKeys.get(mappedKey) !== event.owner_node_id) {
        fail("ETS03", "semantic identities collide after v1 kind mapping", {
          record: index,
        });
      }
      const mapped = {
        kind: IDENTITY_KIND[event.identity_kind],
        value: event.value,
      };
      identities.set(key, { event, mapped });
      mappedIdentityKeys.set(mappedKey, event.owner_node_id);
      nodes.get(event.owner_node_id).mapped.identities.push(mapped);
    } else if (event.kind === "reference") {
      ensureId(event.id, "reference ID");
      ensureId(event.source_node_id, "reference source node");
      if (!NAMESPACE[event.namespace] || !STATUS[event.status] ||
          references.has(event.id) || allIds.has(event.id) ||
          !nodes.has(event.source_node_id)) {
        fail("ETS03", "duplicate or invalid semantic reference", {
          record: index,
        });
      }
      validSpan(event.span, source.source_bytes, "reference span");
      assertSortedUnique(event.diagnostic_ids, "reference diagnostic IDs");
      references.set(event.id, event);
      allIds.add(event.id);
    } else if (event.kind === "fact") {
      ensureId(event.owner_node_id, "fact owner");
      if (!FACT_KIND[event.fact_kind] || !STATUS[event.status] ||
          !nodes.has(event.owner_node_id)) {
        fail("ETS03", "invalid semantic fact", { record: index });
      }
      const key = `${event.owner_node_id}:${event.fact_kind}`;
      if (facts.has(key)) {
        fail("ETS03", "duplicate semantic fact kind for node", {
          record: index,
        });
      }
      assertSortedUnique(event.dependencies, "fact dependencies");
      assertSortedUnique(event.diagnostic_ids, "fact diagnostic IDs");
      if (event.status === 3 && event.diagnostic_ids.length === 0) {
        fail("ETS03", "error fact has no direct diagnostic");
      }
      facts.set(key, event);
    } else if (event.kind === "diagnostic") {
      ensureId(event.id, "diagnostic ID");
      if (allIds.has(event.id) ||
          diagnosticEvents.some((item) => item.id === event.id)) {
        fail("ETS03", "duplicate diagnostic or sidecar-local ID", {
          record: index,
        });
      }
      diagnosticEvents.push(event);
      allIds.add(event.id);
    } else {
      fail("ETS03", "unsupported semantic event in projection", {
        record: index,
      });
    }
  }

  for (const { event } of nodes.values()) {
    for (const dependency of event.dependencies) {
      const target = nodes.get(dependency);
      if (!target) fail("ETS03", "node dependency is dangling");
      if (event.status === 1 && target.event.status !== 1) {
        fail("ETS03", "validated node depends on non-validated node");
      }
    }
    if (event.status === 2 &&
        !event.dependencies.some((id) => nodes.get(id)?.event.status !== 1)) {
      fail("ETS03", "provisional node has no non-validated dependency");
    }
  }

  for (const event of facts.values()) {
    const owner = nodes.get(event.owner_node_id);
    for (const dependency of event.dependencies) {
      const target = nodes.get(dependency);
      if (!target) fail("ETS03", "fact dependency is dangling");
      if (event.status === 1 && target.event.status !== 1) {
        fail("ETS03", "validated fact depends on non-validated node");
      }
    }
    if (event.status === 2 &&
        !event.dependencies.some((id) => nodes.get(id)?.event.status !== 1)) {
      fail("ETS03", "provisional fact has no non-validated dependency");
    }
    addRelationSet(owner.mapped.depends_on, event.dependencies);
    addRelationSet(owner.mapped.diagnostic_ids, event.diagnostic_ids);
    owner.mapped[FACT_KIND[event.fact_kind]] = mapFact(event);
  }

  const diagnosticIds = new Set(diagnosticEvents.map((event) => event.id));
  for (const { event, mapped } of nodes.values()) {
    for (const diagnostic of event.diagnostic_ids) {
      if (!diagnosticIds.has(diagnostic)) {
        fail("ETS03", "node has a dangling diagnostic ID");
      }
    }
    if (event.status === 3 && event.diagnostic_ids.length === 0) {
      fail("ETS03", "error node has no direct diagnostic");
    }
    if (event.status === 4) {
      const nested = ["type", "effect", "ownership", "origin"]
        .filter((field) => mapped[field]);
      if (nested.some((field) => mapped[field].status !== "unavailable")) {
        fail("ETS03", "unavailable node carries available nested facts");
      }
    }
  }
  for (const event of facts.values()) {
    for (const diagnostic of event.diagnostic_ids) {
      if (!diagnosticIds.has(diagnostic)) {
        fail("ETS03", "fact has a dangling diagnostic ID");
      }
    }
    if (event.status === 3 && event.diagnostic_ids.length === 0) {
      fail("ETS03", "error fact has no direct diagnostic");
    }
  }

  const mappedReferences = [];
  for (const event of references.values()) {
    for (const diagnostic of event.diagnostic_ids) {
      if (!diagnosticIds.has(diagnostic)) {
        fail("ETS03", "reference has a dangling diagnostic ID");
      }
    }
    if (event.status === 3 && event.diagnostic_ids.length === 0) {
      fail("ETS03", "error reference has no diagnostic");
    }
    if (event.status === 1 &&
        nodes.get(event.source_node_id).event.status !== 1) {
      fail("ETS03", "validated reference has non-validated source node");
    }
    mappedReferences.push({
      diagnostic_ids: [...event.diagnostic_ids],
      from_node: event.source_node_id,
      id: event.id,
      namespace: NAMESPACE[event.namespace],
      span: { ...event.span },
      status: STATUS[event.status],
      target: validateReferenceTarget(event, identities),
    });
  }

  const mappedDiagnostics = diagnosticEvents.map((event) =>
    mapDiagnostic(event, source, new Set([...nodes.keys(), ...references.keys()])));
  const hasErrorDiagnostic = mappedDiagnostics.some((item) =>
    item.severity === "error");
  const sourceStatus = SOURCE_STATUS[end.source_status];
  const completeness = COMPLETENESS[end.completeness];
  if (!sourceStatus || !completeness ||
      (completeness === "complete" && sourceStatus !== "checked") ||
      (completeness === "partial" &&
        !["failed", "cancelled"].includes(sourceStatus)) ||
      ((sourceStatus === "checked" || sourceStatus === "cancelled") &&
        source.compiler_exit_class !== 0) ||
      (sourceStatus === "failed" &&
        (source.compiler_exit_class < 1 || source.compiler_exit_class > 3)) ||
      (sourceStatus === "failed" && !hasErrorDiagnostic)) {
    fail("ETS03", "source status, completeness, diagnostics, and exit class disagree");
  }

  const mappedNodes = [...nodes.values()].map(({ event, mapped }) => {
    const result = {
      ...mapped,
      depends_on: [...mapped.depends_on].sort(),
      diagnostic_ids: [...mapped.diagnostic_ids].sort(),
      identities: [...mapped.identities].sort((left, right) =>
        tupleCompare([left.kind, left.value], [right.kind, right.value])),
    };
    if (result.status === "error" && result.diagnostic_ids.length === 0) {
      fail("ETS03", "projected error node lacks a diagnostic");
    }
    return result;
  });
  mappedNodes.sort((left, right) => tupleCompare(
    [left.span.start, left.span.end, left.kind, left.id],
    [right.span.start, right.span.end, right.kind, right.id],
  ));
  mappedReferences.sort((left, right) => tupleCompare(
    [left.span.start, left.span.end, left.id],
    [right.span.start, right.span.end, right.id],
  ));
  const severityRank = { error: 0, warning: 1, information: 2, hint: 3 };
  mappedDiagnostics.sort((left, right) => tupleCompare([
    left.primary.file_id, left.primary.span.start, left.primary.span.end,
    severityRank[left.severity], left.code, left.id,
  ], [
    right.primary.file_id, right.primary.span.start, right.primary.span.end,
    severityRank[right.severity], right.code, right.id,
  ]));

  if (completeness === "complete") {
    if (hasErrorDiagnostic ||
        mappedNodes.some((item) => item.status !== "validated") ||
        mappedReferences.some((item) => item.status !== "validated") ||
        mappedNodes.some((item) => ["type", "effect", "ownership", "origin"]
          .some((field) => item[field] && item[field].status !== "validated"))) {
      fail("ETS03", "complete event stream contains non-validated facts");
    }
  }

  const document = {
    authoritative: false,
    compiler: {
      edition: mapEdition(source.edition),
      semantic_compatibility: schemaName(
        source.semantic_compatibility, "semantic compatibility",
      ),
    },
    completeness,
    diagnostics: mappedDiagnostics,
    file: {
      byte_length: source.source_bytes,
      content_sha256: source.source_sha256,
      file_id: source.file_id,
      logical_path: source.logical_path,
      module_id: source.module_id,
      package_id: source.package_id,
    },
    generation: { sequence: source.generation },
    limits: {
      document_bytes: TYPED_SIDECAR_LIMITS.documentBytes,
      max_depth: TYPED_SIDECAR_LIMITS.maxDepth,
      profile: "default-v1",
    },
    nodes: mappedNodes,
    references: mappedReferences,
    schema: "kofun.typed-sidecar/v1",
    source_status: sourceStatus,
  };
  const encoded = encodeTypedSidecar(document);
  if (!encoded.ok) {
    const code = encoded.error.code === "TS004" ? "ETS04" : "ETS03";
    fail(code, `typed-sidecar projection rejected: ${encoded.error.message}`);
  }
  const stable = readTypedSidecar(encoded.bytes);
  if (!stable.ok) {
    const code = stable.error.code === "TS004" ? "ETS04" : "ETS03";
    fail(code, `typed-sidecar projection replay rejected: ${stable.error.message}`);
  }
  return {
    document: stable.document,
    compiler_exit_class: source.compiler_exit_class,
  };
}

export function projectStage2SemanticEvents(events) {
  try {
    const projected = semanticProjection(events);
    return Object.freeze({
      ok: true,
      document: projected.document,
      compiler_exit_class: projected.compiler_exit_class,
    });
  } catch (error) {
    if (error instanceof TypeError) throw error;
    return errorResult(error);
  }
}

function mapCodecError(error) {
  if (error.code === "TS004") return "ETS04";
  if (error.code === "TS005") return "ETS05";
  if (error.code === "TS006") return "ETS06";
  return "ETS03";
}

async function currentSourceBytes(context) {
  if (Object.hasOwn(context, "currentSourceBytes")) {
    return byteView(context.currentSourceBytes);
  }
  if (typeof context.sourcePath !== "string" || context.sourcePath.length === 0) {
    throw new TypeError("Stage 2 sidecar emission needs sourcePath or currentSourceBytes");
  }
  try {
    const stat = await fs.promises.stat(context.sourcePath);
    if (!stat.isFile() || stat.size > 0xffff_ffff) {
      fail("ETS05", "current source is unavailable or outside the span profile", {
        reason: "source-mismatch",
      });
    }
    return await fs.promises.readFile(context.sourcePath);
  } catch (error) {
    if (error instanceof ProjectionFailure) throw error;
    fail("ETS05", "current source is unavailable or outside the span profile", {
      reason: "source-mismatch",
    });
  }
}

async function refreshedSourceDigest(context) {
  try {
    const bytes = await currentSourceBytes(context);
    return crypto.createHash("sha256").update(bytes).digest("hex");
  } catch {
    return ZERO_ID;
  }
}

async function emitSemanticSidecar(eventBytes, destination, context, readEvents, projectEvents) {
  if (typeof destination !== "string" || destination.length === 0) {
    throw new TypeError("typed-sidecar destination must be a non-empty path string");
  }
  if (context === null || typeof context !== "object") {
    throw new TypeError("Stage 2 sidecar emission context must be an object");
  }
  try {
    const read = readEvents(eventBytes);
    if (!read.ok) return read;
    const projected = projectEvents(read.events);
    if (!projected.ok) return projected;
    const sourceBytes = await currentSourceBytes(context);
    const digest = crypto.createHash("sha256").update(sourceBytes).digest("hex");
    if (sourceBytes.length !== projected.document.file.byte_length ||
        digest !== projected.document.file.content_sha256) {
      fail("ETS05", "current source does not match the committed event source", {
        reason: "source-mismatch",
      });
    }
    const written = await writeTypedSidecarAtomic(
      destination,
      projected.document,
      {
        currentSourceDigest: digest,
        refreshCurrentSourceDigest: () => refreshedSourceDigest(context),
        signal: context.signal,
      },
    );
    if (!written.ok) {
      return Object.freeze({
        ok: false,
        error: Object.freeze({
          code: mapCodecError(written.error),
          message: bounded(written.error.message, 256),
          ...(written.error.reason ?
            { reason: bounded(written.error.reason, 64) } : {}),
        }),
      });
    }
    return Object.freeze({
      ok: true,
      bytes: written.bytes,
      compiler_exit_class: projected.compiler_exit_class,
      sequence: written.sequence,
      source_status: projected.document.source_status,
    });
  } catch (error) {
    if (error instanceof TypeError) throw error;
    return errorResult(error, "ETS06");
  }
}

export async function emitStage2TypedSidecar(eventBytes, destination, context) {
  return emitSemanticSidecar(eventBytes, destination, context,
    readStage2SemanticEvents, projectStage2SemanticEvents);
}

// KSE2 is an explicit successor API. The old entrypoints above remain v1-only.
const COMMON_RECORD_FIELDS = Object.freeze({
  source: ["package_id", "module_id", "file_id", "logical_path", "source_bytes",
    "source_sha256", "edition", "semantic_compatibility", "generation", "compiler_exit_class"],
  node: ["id", "node_kind", "span", "status", "dependencies", "diagnostic_ids"],
  identity: ["owner_node_id", "identity_kind", "value", "status"],
  reference: ["id", "source_node_id", "namespace", "span", "status", "target_shape",
    "target_kind", "target_value", "reason", "diagnostic_ids"],
  fact: ["owner_node_id", "fact_kind", "status", "display", "reason", "dependencies", "diagnostic_ids"],
  diagnostic: ["id", "code", "category", "severity", "template_id", "primary_file_id",
    "primary_span", "fallback_text", "affected_ids", "remedy_ids", "truncated", "related", "edits"],
  end: ["source_status", "completeness"],
});
const COMMON_RECORD_KIND = Object.freeze(Object.fromEntries(
  Object.keys(COMMON_RECORD_FIELDS).map((kind, index) => [kind, index + 1]),
));
const CAPTURE_RECORD_FIELDS = Object.freeze({
  par: ["par_id", "node_id", "scope_id", "parent_scope_id", "scope_token_binding_id", "lexical_index"],
  task: ["task_id", "par_id", "spawn_node_id", "lambda_node_id", "handle_binding_id", "lexical_index"],
  join: ["join_id", "task_id", "join_kind", "node_id"],
  place: ["place_id", "base_binding_id", "canonical_bytes", "projections"],
  unknown: ["unknown_id", "task_id", "witness_node_id", "reason", "canonical_bytes"],
  capture: ["capture_id", "task_id", "target_kind", "target_id", "mode", "origin_node_ids"],
});

function exactRecord(value, keys) {
  if (value === null || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).length !== keys.length ||
      keys.some((key) => !Object.hasOwn(value, key))) {
    fail("ETS03", "semantic record has unknown or missing fields");
  }
}

function unsignedBytes(value, width) {
  const maximum = width === 8 ? Number.MAX_SAFE_INTEGER : 2 ** (width * 8) - 1;
  if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
    fail("ETS03", "semantic integer is outside its wire range");
  }
  const bytes = Buffer.alloc(width);
  if (width === 8) bytes.writeBigUInt64BE(BigInt(value));
  else bytes.writeUIntBE(value, 0, width);
  return bytes;
}

function idBytes(value) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    fail("ETS03", "semantic identity is not 32-byte lowercase hexadecimal");
  }
  return Buffer.from(value, "hex");
}

function textBytes(value) {
  if (typeof value !== "string") fail("ETS03", "semantic text must be a string");
  if (Buffer.byteLength(value, "utf8") > V2_PROFILE.limits.textBytes) {
    fail("ETS04", "semantic event text exceeds the v2 byte limit");
  }
  const bytes = Buffer.from(value, "utf8");
  if (decodeText(bytes, undefined, undefined, V2_PROFILE.limits) !== value) {
    fail("ETS04", "semantic text contains an unpaired surrogate");
  }
  return bytes;
}

function spanBytes(value) {
  exactRecord(value, ["start", "end"]);
  return Buffer.concat([unsignedBytes(value.start, 4), unsignedBytes(value.end, 4)]);
}

function commonList(value) {
  if (!Array.isArray(value)) fail("ETS03", "semantic relation must be an array");
  if (value.length > LIMITS.relations) fail("ETS04", "common event relation exceeds 64 entries");
  return value;
}

function nestedDiagnosticBytes(values, edits) {
  const parts = [unsignedBytes(commonList(values).length, 2)];
  let length = 2;
  for (const item of values) {
    exactRecord(item, edits ? ["remedy_id", "file_id", "span", "replacement"] :
      ["file_id", "span", "label"]);
    const text = textBytes(edits ? item.replacement : item.label);
    const row = Buffer.concat([
      ...(edits ? [unsignedBytes(item.remedy_id, 4)] : []),
      idBytes(item.file_id), spanBytes(item.span), unsignedBytes(text.length, 2), text,
    ]);
    length += row.length;
    if (length > V2_PROFILE.limits.textBytes) fail("ETS04", "nested diagnostic field exceeds v2 limit");
    parts.push(row);
  }
  return Buffer.concat(parts, length);
}

function encodedField(tag, wire, value) {
  let bytes;
  switch (wire) {
    case WIRE.bytes: bytes = value; break;
    case WIRE.utf8: bytes = textBytes(value); break;
    case WIRE.id: bytes = idBytes(value); break;
    case WIRE.u8: bytes = unsignedBytes(value, 1); break;
    case WIRE.u32: bytes = unsignedBytes(value, 4); break;
    case WIRE.u64: bytes = unsignedBytes(value, 8); break;
    case WIRE.span: bytes = spanBytes(value); break;
    case WIRE.ids: bytes = Buffer.concat(commonList(value).map(idBytes)); break;
    case WIRE.u32s:
      bytes = Buffer.concat(commonList(value).map((item) => unsignedBytes(item, 4))); break;
    default: fail("ETS03", "unknown semantic wire type");
  }
  if (bytes.length > V2_PROFILE.limits.textBytes) fail("ETS04", "semantic field exceeds v2 limit");
  return Buffer.concat([Buffer.from([tag, wire, 0, 0]), unsignedBytes(bytes.length, 4), bytes]);
}

function encodeCommonEvent(event) {
  const names = COMMON_RECORD_FIELDS[event?.kind];
  if (!names) fail("ETS03", "unknown common semantic event");
  exactRecord(event, ["kind", ...names]);
  const kind = COMMON_RECORD_KIND[event.kind];
  const schema = EVENT_FIELDS[kind];
  const fields = schema.map(([tag, wire], index) => {
    let value = event[names[index]];
    if (kind === 6 && tag >= 12) value = nestedDiagnosticBytes(value, tag === 13);
    return encodedField(tag, wire, value);
  });
  if (kind === 4) {
    // The logical shape carries both fields; the frozen wire carries exactly one.
    if (event.target_shape === 1) {
      if (event.reason !== "") fail("ETS03", "visible reference cannot carry a reason");
      fields.push(encodedField(8, WIRE.id, event.target_value));
    } else {
      if (event.target_value !== ZERO_ID) fail("ETS03", "hidden reference cannot carry a target");
      fields.push(encodedField(9, WIRE.utf8, event.reason));
    }
    fields.push(encodedField(10, WIRE.ids, event.diagnostic_ids));
  }
  const payload = Buffer.concat(fields);
  return Buffer.concat([Buffer.from([kind, 0]), unsignedBytes(fields.length, 2),
    unsignedBytes(payload.length, 4), payload]);
}

function checkCaptureFrameBounds(bytes, cursor, end, count, kind, record) {
  for (let index = 0; index < count; index += 1) {
    if (end - cursor < 8) fail("ETS03", "truncated capture field header", { record, eventKind: kind });
    const tag = bytes[cursor];
    const length = readU32(bytes, cursor + 4);
    if (length > KSE2_LIMITS.field_bytes ||
        (kind === 13 && tag === 6 && length > KSE2_LIMITS.relations * 32)) {
      fail("ETS04", "capture field or origin list exceeds the v2 limit", { record, eventKind: kind });
    }
    cursor = checkedEnd(cursor + 8, length, end, "ETS04",
      "capture field exceeds its frame", { record, eventKind: kind });
  }
}

function checkCaptureBounds(events) {
  if (events.length > KSE2_LIMITS.capture_events) fail("ETS04", "capture event count exceeds the v2 limit");
  let pars = 0;
  let tasks = 0;
  const perTask = new Map();
  for (const event of events) {
    if (event.event === "par" && ++pars > 64) fail("ETS04", "par count exceeds the v2 limit");
    if (event.event === "task" && ++tasks > 64) fail("ETS04", "task count exceeds the v2 limit");
    if (typeof event.canonical_bytes === "string" && event.canonical_bytes.length > KSE2_LIMITS.field_bytes * 2) {
      fail("ETS04", "canonical capture bytes exceed the v2 field limit");
    }
    if (event.event === "capture") {
      const count = (perTask.get(event.task_id) ?? 0) + 1;
      if (count > 64) fail("ETS04", "captures per task exceed the v2 limit");
      perTask.set(event.task_id, count);
      if (Array.isArray(event.origin_node_ids) && event.origin_node_ids.length > KSE2_LIMITS.relations) {
        fail("ETS04", "capture origin count exceeds the v2 limit");
      }
    }
  }
}

function encodeV2Bytes(events) {
  if (!Array.isArray(events)) throw new TypeError("Stage 2 semantic events must be an array");
  if (events.length < 2 || events.length > V2_PROFILE.limits.events) {
    fail("ETS04", "semantic event count is outside the v2 profile");
  }
  const captures = events.filter((event) => typeof event?.kind === "number");
  if (captures.length > KSE2_LIMITS.capture_events) fail("ETS04", "capture event count exceeds the v2 limit");
  for (const event of captures) {
    const names = CAPTURE_RECORD_FIELDS[event.event];
    if (!names) fail("ETS03", "unknown capture event");
    exactRecord(event, ["event", "kind", ...names]);
  }
  checkCaptureBounds(captures);
  validateCaptureStream(captures);
  const frames = [];
  let payloadLength = 0;
  for (const event of events) {
    const frame = typeof event?.kind === "number" ? encodeCaptureEvent(event) : encodeCommonEvent(event);
    payloadLength += frame.length;
    if (payloadLength > V2_PROFILE.limits.payloadBytes) fail("ETS04", "semantic event stream exceeds the v2 byte cap");
    frames.push(frame);
  }
  const header = Buffer.concat([Buffer.from("KSE\0"), unsignedBytes(2, 2), unsignedBytes(0, 2),
    unsignedBytes(events.length, 4), unsignedBytes(payloadLength, 4)]);
  const digest = crypto.createHash("sha256").update(header);
  for (const frame of frames) digest.update(frame);
  return Buffer.concat([header, ...frames, digest.digest()], payloadLength + 48);
}

function projectV2Decoded(events) {
  const captures = events.filter((event) => typeof event.kind === "number");
  const common = events.filter((event) => typeof event.kind === "string");
  const projected = semanticProjection(common, V2_PROFILE.limits);
  const nodes = new Map(common.filter((event) => event.kind === "node").map((event) => [event.id, event]));
  // Key by the actual kind/value pair, not a display label or an arbitrary owner.
  const identities = new Map(common.filter((event) => event.kind === "identity")
    .map((event) => [`${event.identity_kind}:${event.value}`, event]));
  const node = (id) => {
    const found = nodes.get(id);
    if (!found) fail("ETS03", "capture names a node outside the committed node phase");
    return found;
  };
  const identity = (kind, value) => {
    const found = identities.get(`${kind}:${value}`);
    if (!found || found.status !== 1 || !nodes.has(found.owner_node_id)) {
      fail("ETS03", "capture names an identity outside the committed identity namespace");
    }
  };
  checkCaptureBounds(captures);
  validateCaptureStream(captures);
  for (const event of captures) {
    switch (event.event) {
      case "par":
        node(event.node_id);
        identity(4, event.scope_id);
        identity(4, event.parent_scope_id);
        identity(5, event.scope_token_binding_id);
        break;
      case "task":
        node(event.spawn_node_id);
        node(event.lambda_node_id);
        identity(5, event.handle_binding_id);
        break;
      case "join":
        if (event.join_kind === "explicit") node(event.node_id);
        break;
      case "place":
        identity(5, event.base_binding_id);
        for (const projection of event.projections) {
          if (projection.kind === "field") identity(8, projection.owner_type_id);
          else for (const bound of [projection.lower, projection.upper]) {
            if (bound.kind === "node") node(bound.node_id);
          }
        }
        break;
      case "unknown": node(event.witness_node_id); break;
      case "capture": {
        let previous;
        for (const origin of event.origin_node_ids) {
          const span = node(origin).span;
          if (span.start >= span.end) fail("ETS03", "capture origin must have a nonempty source span");
          const current = [span.start, span.end, origin];
          if (previous && tupleCompare(previous, current) >= 0) {
            fail("ETS03", "capture origins are not in committed source-span order");
          }
          previous = current;
        }
        break;
      }
      default: fail("ETS03", "unknown capture event");
    }
  }
  const document = projectSidecarV2(projected.document, captures);
  const encoded = encodeTypedSidecar(document);
  if (!encoded.ok) fail(mapCodecError(encoded.error), "typed-sidecar v2 projection rejected");
  const stable = readTypedSidecar(encoded.bytes);
  if (!stable.ok) fail(mapCodecError(stable.error), "typed-sidecar v2 projection replay rejected");
  return Object.freeze({ ok: true, document: stable.document,
    compiler_exit_class: projected.compiler_exit_class });
}

function validatedV2(input) {
  const read = readSemanticEventBytes(input, V2_PROFILE);
  if (!read.ok) {
    fail(read.error.code, read.error.message, { record: read.error.record, eventKind: read.error.event_kind });
  }
  return { events: read.events, projected: projectV2Decoded(read.events) };
}

export function readStage2SemanticEventsV2(input) {
  // Invalid byte-container usage is a programmer error, as in the v1 API.
  const bytes = byteView(input);
  try {
    return successResult("events", validatedV2(bytes).events);
  } catch (error) {
    return errorResult(error);
  }
}

export function encodeStage2SemanticEventsV2(events) {
  if (!Array.isArray(events)) throw new TypeError("Stage 2 semantic events must be an array");
  try {
    const bytes = encodeV2Bytes(events);
    validatedV2(bytes);
    return successResult("bytes", bytes);
  } catch (error) {
    return errorResult(error);
  }
}

export function projectStage2SemanticEventsV2(events) {
  if (!Array.isArray(events)) throw new TypeError("Stage 2 semantic events must be an array");
  try {
    // Logical callers get the same exact field/schema/encoding checks as bytes.
    return validatedV2(encodeV2Bytes(events)).projected;
  } catch (error) {
    return errorResult(error);
  }
}

export async function emitStage2TypedSidecarV2(eventBytes, destination, context) {
  return emitSemanticSidecar(eventBytes, destination, context,
    readStage2SemanticEventsV2, projectStage2SemanticEventsV2);
}

export function replayStage2SemanticEventsV2(input, onEvent) {
  if (typeof onEvent !== "function") throw new TypeError("semantic replay requires an event callback");
  const bytes = byteView(input);
  let validated;
  try {
    // Validate the last record and every cross-link before the first callback.
    validated = validatedV2(bytes);
  } catch (error) {
    return errorResult(error);
  }
  try {
    for (const event of validated.events) {
      const accepted = onEvent(event);
      if (accepted === false) fail("ETS03", "semantic replay destination refused a record");
      if (accepted && typeof accepted.then === "function") {
        // This API is synchronous. Consume a rejected promise without leaking
        // its possibly private exception, then refuse further delivery.
        Promise.resolve(accepted).catch(() => {});
        fail("ETS03", "semantic replay destination must be synchronous");
      }
    }
    return Object.freeze({ ok: true, event_count: validated.events.length,
      compiler_exit_class: validated.projected.compiler_exit_class });
  } catch {
    return errorResult(new ProjectionFailure("ETS03", "semantic replay destination refused a record"));
  }
}

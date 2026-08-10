#!/usr/bin/env node

/*
 * AggregateLayout v1 reference computer.
 *
 * Every byte quantity — size, alignment, offset, object-size bound — is a
 * decimal string parsed to BigInt rather than a JSON number. Offsets and
 * bounds exceed the exact range of an IEEE-754 double, so a number-typed
 * contract would silently round exactly the values the overflow rules exist
 * to reject. Strings keep the contract exact and independent of any host's
 * number representation.
 *
 * All arithmetic is checked against the target's declared maximum object
 * size before any value is reported, so an overflow fails here rather than
 * reaching a backend.
 */

import fs from "node:fs";

const SCHEMA_DOCUMENT = "kofun.aggregate-layout-document/v1";
const SCHEMA_TARGET = "kofun.target-data-layout/v1";
const SCHEMA_OUTPUT = "kofun.aggregate-layout/v1";
const ABI_VERSION = "aggregate-layout-v1";

/* Tag widths are the only ones v1 admits; the smallest that holds the
 * constructor count is selected, so the choice is deterministic rather
 * than a backend preference. */
const TAG_WIDTHS = [1n, 2n, 4n, 8n];
const DECIMAL = /^(0|[1-9][0-9]*)$/;

function fail(message) {
  throw new Error(message);
}

function readJson(file) {
  const bytes = fs.readFileSync(file);
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    fail(`${file}: byte order mark is not permitted`);
  }
  const text = bytes.toString("utf8");
  if (text.includes("�")) fail(`${file}: input is not valid UTF-8`);
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    fail(`${file}: ${error.message}`);
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    fail(`${file}: document root must be a JSON object`);
  }
  return value;
}

/* A byte quantity is a decimal string; anything else — a JSON number, a
 * negative, a leading zero — is rejected rather than coerced. */
function quantity(value, what) {
  if (typeof value !== "string") fail(`${what} must be a decimal string, got ${typeof value}`);
  if (!DECIMAL.test(value)) fail(`${what} is not a canonical decimal string: ${value}`);
  return BigInt(value);
}

function alignment(value, what) {
  const parsed = quantity(value, what);
  if (parsed <= 0n) fail(`${what} must be positive`);
  if ((parsed & (parsed - 1n)) !== 0n) fail(`${what} must be a power of two, got ${parsed}`);
  return parsed;
}

class Target {
  constructor(raw, file) {
    if (raw.schema !== SCHEMA_TARGET) fail(`${file}: schema must be ${SCHEMA_TARGET}`);
    if (typeof raw.name !== "string" || raw.name === "") fail(`${file}: name is required`);
    if (raw.endianness !== "little") {
      fail(`${file}: v1 defines little-endian targets only, got ${raw.endianness}`);
    }
    this.name = raw.name;
    this.endianness = raw.endianness;
    this.pointerSize = quantity(raw.pointer_size, `${file}: pointer_size`);
    this.pointerAlign = alignment(raw.pointer_align, `${file}: pointer_align`);
    this.maxObjectSize = quantity(raw.max_object_size, `${file}: max_object_size`);
    if (this.pointerSize <= 0n) fail(`${file}: pointer_size must be positive`);
    if (this.maxObjectSize <= 0n) fail(`${file}: max_object_size must be positive`);
    this.scalars = new Map();
    const scalars = raw.scalars;
    if (scalars === null || typeof scalars !== "object" || Array.isArray(scalars)) {
      fail(`${file}: scalars must be a JSON object`);
    }
    for (const name of Object.keys(scalars).sort()) {
      const entry = scalars[name];
      this.scalars.set(name, {
        size: quantity(entry.size, `${file}: scalar ${name} size`),
        align: alignment(entry.align, `${file}: scalar ${name} align`),
      });
    }
    /* The u64 object headers are target-independent: a Text or List header
     * is the same eight bytes on wasm32 as on x86-64, which is what lets a
     * 32-bit reference address a header written by a 64-bit producer. */
    this.headerSize = 8n;
    this.headerAlign = 8n;
  }

  bound(value, what) {
    if (value > this.maxObjectSize) {
      fail(
        `${what} is ${value} bytes, above the ${this.name} maximum object size ` +
          `of ${this.maxObjectSize}`
      );
    }
    return value;
  }

  add(left, right, what) {
    return this.bound(left + right, what);
  }

  multiply(left, right, what) {
    return this.bound(left * right, what);
  }

  alignUp(offset, align, what) {
    if (align <= 0n) fail(`${what}: alignment must be positive`);
    const padded = offset + (align - 1n);
    this.bound(padded, what);
    return this.bound(padded - (padded % align), what);
  }
}

function tagWidthFor(count, target) {
  if (count <= 0) fail("an ADT needs at least one constructor");
  for (const width of TAG_WIDTHS) {
    /* 2^(8*width) distinct tags fit in `width` bytes. */
    if (BigInt(count) <= 1n << (8n * width)) return width;
  }
  return target.bound(1n << 64n, `an ADT with ${count} constructors has no v1 tag width`);
}

class Solver {
  constructor(target, types) {
    this.target = target;
    this.declared = new Map();
    this.resolved = new Map();
    this.order = [];
    for (const type of types) {
      if (typeof type.id !== "string" || type.id === "") fail("every type needs an id");
      if (this.declared.has(type.id)) fail(`duplicate type id ${type.id}`);
      this.declared.set(type.id, type);
      this.order.push(type.id);
    }
  }

  layout(id, stack = []) {
    const cached = this.resolved.get(id);
    if (cached !== undefined) return cached;
    if (stack.includes(id)) {
      /* Recursive layout is out of scope for v1 and must fail explicitly
       * rather than diverge or invent an indirection. */
      fail(`recursive layout is not supported in v1: ${[...stack, id].join(" -> ")}`);
    }
    const type = this.declared.get(id);
    if (type === undefined) fail(`unknown type ${id}`);
    const computed = this.compute(type, [...stack, id]);
    this.resolved.set(id, computed);
    return computed;
  }

  compute(type, stack) {
    const t = this.target;
    switch (type.kind) {
      case "scalar": {
        const scalar = t.scalars.get(type.scalar);
        if (scalar === undefined) fail(`${type.id}: unknown scalar ${type.scalar}`);
        return {
          id: type.id,
          kind: "scalar",
          size: scalar.size,
          align: scalar.align,
          pointers: [],
          drop: "trivial",
        };
      }
      case "text":
      case "list": {
        /* A Text or List value is exactly one reference. The object it
         * addresses is described separately, so the value layout does not
         * depend on the payload. */
        if (type.kind === "list") {
          if (typeof type.element !== "string") fail(`${type.id}: list needs an element type`);
          this.layout(type.element, stack);
        }
        return {
          id: type.id,
          kind: type.kind,
          size: t.pointerSize,
          align: t.pointerAlign,
          pointers: [0n],
          drop: "managed",
        };
      }
      case "bounded_list": {
        /* A bounded list is the one list-shaped value that is NOT a
         * reference: it is stored inline, by value, with a fixed capacity.
         * The `list` kind above is unchanged and still describes `List`.
         * See RFC-0011 and the ledger amendment DD-033/A01.
         *
         * Alignment comes from the element and the header, never from the
         * size — a 520-byte carrier is 8-aligned, and deriving alignment
         * from size is the defect this kind exposes. */
        if (typeof type.element !== "string") {
          fail(`${type.id}: bounded_list needs an element type`);
        }
        const capacity = quantity(type.capacity, `${type.id}: capacity`);
        if (capacity <= 0n) fail(`${type.id}: capacity must be positive`);
        const inner = this.layout(type.element, stack);
        const align = inner.align > t.headerAlign ? inner.align : t.headerAlign;
        const start = t.alignUp(t.headerSize, inner.align, `${type.id} elements offset`);
        const end = t.add(
          start,
          t.multiply(capacity, inner.size, `${type.id} elements`),
          `${type.id} end`
        );
        /* Every slot carries the element's bitmap, because a bounded list
         * holds its elements rather than addressing them. An element with
         * no pointers therefore makes the whole carrier trivially
         * droppable and copyable, which is what separates this kind from
         * `list` for the purpose of deciding whether a record is Copy. */
        const pointers = [];
        for (let slot = 0n; slot < capacity; slot += 1n) {
          const base = t.add(
            start,
            t.multiply(slot, inner.size, `${type.id} slot ${slot}`),
            `${type.id} slot ${slot} offset`
          );
          for (const pointer of inner.pointers) {
            pointers.push(t.add(base, pointer, `${type.id} slot ${slot} pointer`));
          }
        }
        return {
          id: type.id,
          kind: "bounded_list",
          size: t.alignUp(end, align, `${type.id} size`),
          align,
          element: type.element,
          capacity,
          length_offset: 0n,
          length_size: t.headerSize,
          elements_offset: start,
          element_size: inner.size,
          pointers,
          drop: pointers.length === 0 ? "trivial" : "managed",
        };
      }
      case "record": {
        if (!Array.isArray(type.fields)) fail(`${type.id}: record needs a fields array`);
        let end = 0n;
        let align = 1n;
        const fields = [];
        const pointers = [];
        const seen = new Set();
        for (const field of type.fields) {
          if (typeof field.name !== "string" || field.name === "") {
            fail(`${type.id}: every field needs a name`);
          }
          if (seen.has(field.name)) fail(`${type.id}: duplicate field ${field.name}`);
          seen.add(field.name);
          const inner = this.layout(field.type, stack);
          const offset = t.alignUp(end, inner.align, `${type.id}.${field.name} offset`);
          fields.push({ name: field.name, type: field.type, offset, size: inner.size });
          for (const pointer of inner.pointers) {
            pointers.push(t.add(offset, pointer, `${type.id}.${field.name} pointer`));
          }
          end = t.add(offset, inner.size, `${type.id}.${field.name} end`);
          if (inner.align > align) align = inner.align;
        }
        return {
          id: type.id,
          kind: "record",
          size: t.alignUp(end, align, `${type.id} size`),
          align,
          fields,
          pointers,
          drop: pointers.length === 0 ? "trivial" : "managed",
        };
      }
      case "adt":
      case "optional": {
        const constructors =
          type.kind === "optional"
            ? [
                { name: "None", payload: null },
                { name: "Some", payload: requirePayload(type) },
              ]
            : type.constructors;
        if (!Array.isArray(constructors)) fail(`${type.id}: adt needs a constructors array`);
        const tagWidth = tagWidthFor(constructors.length, t);
        let payloadAlign = 1n;
        let payloadSize = 0n;
        const seen = new Set();
        const described = [];
        constructors.forEach((constructor, index) => {
          if (typeof constructor.name !== "string" || constructor.name === "") {
            fail(`${type.id}: every constructor needs a name`);
          }
          if (seen.has(constructor.name)) {
            fail(`${type.id}: duplicate constructor ${constructor.name}`);
          }
          seen.add(constructor.name);
          let inner = null;
          if (constructor.payload !== null && constructor.payload !== undefined) {
            inner = this.layout(constructor.payload, stack);
            if (inner.align > payloadAlign) payloadAlign = inner.align;
            if (inner.size > payloadSize) payloadSize = inner.size;
          }
          described.push({
            name: constructor.name,
            /* Tags follow declaration order from zero, so a reordered
             * source declaration is a layout change and not a silent one. */
            tag: BigInt(index),
            payload: constructor.payload ?? null,
            payload_size: inner === null ? 0n : inner.size,
          });
        });
        const payloadOffset = t.alignUp(tagWidth, payloadAlign, `${type.id} payload offset`);
        const align = tagWidth > payloadAlign ? tagWidth : payloadAlign;
        const end = t.add(payloadOffset, payloadSize, `${type.id} payload end`);
        /* The pointer bitmap of a tagged union is the union over payloads:
         * a byte that is a reference under any constructor must be treated
         * as one, because the tag is a runtime value. */
        const pointers = [];
        for (const constructor of constructors) {
          if (constructor.payload === null || constructor.payload === undefined) continue;
          const inner = this.layout(constructor.payload, stack);
          for (const pointer of inner.pointers) {
            const at = t.add(payloadOffset, pointer, `${type.id} pointer`);
            if (!pointers.some((existing) => existing === at)) pointers.push(at);
          }
        }
        pointers.sort((left, right) => (left < right ? -1 : left > right ? 1 : 0));
        return {
          id: type.id,
          kind: type.kind,
          size: t.alignUp(end, align, `${type.id} size`),
          align,
          tag_width: tagWidth,
          tag_offset: 0n,
          payload_offset: payloadOffset,
          payload_size: payloadSize,
          constructors: described,
          pointers,
          drop: pointers.length === 0 ? "trivial" : "managed",
        };
      }
      default:
        return fail(`${type.id}: unknown kind ${type.kind}`);
    }
  }
}

function requirePayload(type) {
  if (typeof type.payload !== "string") fail(`${type.id}: optional needs a payload type`);
  return type.payload;
}

/* Object images are the byte diagrams the contract owes for Text and List:
 * a value is a reference, so the bytes live here rather than in TypeLayout. */
function objectImage(target, solver, object) {
  const t = target;
  if (typeof object.id !== "string" || object.id === "") fail("every object needs an id");
  const type = solver.declared.get(object.type);
  if (type === undefined) fail(`${object.id}: unknown type ${object.type}`);
  if (type.kind === "text") {
    if (typeof object.text !== "string") fail(`${object.id}: text objects need a text field`);
    const bytes = BigInt(Buffer.byteLength(object.text, "utf8"));
    const start = t.alignUp(t.headerSize, 1n, `${object.id} bytes offset`);
    return {
      id: object.id,
      type: object.type,
      kind: "text",
      align: t.headerAlign,
      header: [{ name: "byte_length", type: "u64", offset: 0n, size: t.headerSize }],
      payload_offset: start,
      payload_size: bytes,
      /* No trailing padding: an object is individually referenced and
       * never inlined into an array, so nothing follows it that would
       * need alignment. */
      size: t.add(start, bytes, `${object.id} size`),
      byte_length: bytes,
    };
  }
  if (type.kind === "list") {
    if (!Number.isInteger(object.elements) || object.elements < 0) {
      fail(`${object.id}: list objects need a non-negative integer element count`);
    }
    const element = solver.layout(type.element);
    const count = BigInt(object.elements);
    const start = t.alignUp(t.headerSize, element.align, `${object.id} elements offset`);
    const span = t.multiply(element.size, count, `${object.id} elements span`);
    return {
      id: object.id,
      type: object.type,
      kind: "list",
      align: t.headerAlign > element.align ? t.headerAlign : element.align,
      header: [{ name: "length", type: "u64", offset: 0n, size: t.headerSize }],
      payload_offset: start,
      payload_size: span,
      size: t.add(start, span, `${object.id} size`),
      element_type: type.element,
      element_size: element.size,
      element_align: element.align,
      length: count,
    };
  }
  return fail(`${object.id}: ${object.type} has no object image in v1`);
}

/* Canonical serialization: BigInt becomes a decimal string, key order is
 * the order built here, and the document ends with exactly one newline —
 * so a descriptor is byte-comparable across producers. */
function canonical(value) {
  return (
    JSON.stringify(value, (_key, inner) => (typeof inner === "bigint" ? inner.toString() : inner), 2) +
    "\n"
  );
}

function describe(targetFile, documentFile) {
  const target = new Target(readJson(targetFile), targetFile);
  const document = readJson(documentFile);
  if (document.schema !== SCHEMA_DOCUMENT) {
    fail(`${documentFile}: schema must be ${SCHEMA_DOCUMENT}`);
  }
  if (!Array.isArray(document.types)) fail(`${documentFile}: types must be an array`);
  const solver = new Solver(target, document.types);
  const layouts = solver.order.map((id) => solver.layout(id));
  const objects = (document.objects ?? []).map((object) => objectImage(target, solver, object));
  return canonical({
    schema: SCHEMA_OUTPUT,
    abi_version: ABI_VERSION,
    target: {
      name: target.name,
      endianness: target.endianness,
      pointer_size: target.pointerSize,
      pointer_align: target.pointerAlign,
      max_object_size: target.maxObjectSize,
    },
    layouts,
    objects,
  });
}

function selfTestLimits() {
  const target = new Target(
    {
      schema: SCHEMA_TARGET,
      name: "self-test",
      endianness: "little",
      pointer_size: "8",
      pointer_align: "8",
      max_object_size: "1024",
      scalars: { Int: { size: "8", align: "8" } },
    },
    "self-test"
  );
  const expectFail = (label, run) => {
    let threw = false;
    try {
      run();
    } catch {
      threw = true;
    }
    if (!threw) fail(`self-test: ${label} was accepted but must be rejected`);
  };
  expectFail("add above the bound", () => target.add(1000n, 25n, "add"));
  expectFail("multiply above the bound", () => target.multiply(512n, 3n, "multiply"));
  expectFail("alignUp above the bound", () => target.alignUp(1020n, 16n, "alignUp"));
  expectFail("non-power-of-two alignment", () => alignment("3", "align"));
  expectFail("JSON number quantity", () => quantity(8, "size"));
  expectFail("negative quantity", () => quantity("-1", "size"));
  expectFail("leading-zero quantity", () => quantity("08", "size"));
  if (target.alignUp(1000n, 8n, "ok") !== 1000n) fail("self-test: aligned value changed");
  if (target.alignUp(993n, 8n, "ok") !== 1000n) fail("self-test: alignUp rounded wrong");
  if (tagWidthFor(2, target) !== 1n) fail("self-test: two constructors need one tag byte");
  if (tagWidthFor(256, target) !== 1n) fail("self-test: 256 constructors fit one tag byte");
  if (tagWidthFor(257, target) !== 2n) fail("self-test: 257 constructors need two tag bytes");
  process.stdout.write("aggregate-layout: self-test-limits ok\n");
}

function schemaSelfCheck() {
  if (TAG_WIDTHS.some((width) => (width & (width - 1n)) !== 0n)) {
    fail("tag widths must be powers of two");
  }
  process.stdout.write(`${SCHEMA_OUTPUT} ${ABI_VERSION}\n`);
}

function main(argv) {
  const [command, ...rest] = argv;
  switch (command) {
    case "schema":
      return schemaSelfCheck();
    case "self-test-limits":
      return selfTestLimits();
    case "describe": {
      if (rest.length !== 2) fail("usage: layout.mjs describe TARGET.json DOCUMENT.json");
      process.stdout.write(describe(rest[0], rest[1]));
      return undefined;
    }
    default:
      return fail(`unknown command ${command ?? "(none)"}`);
  }
}

try {
  main(process.argv.slice(2));
} catch (error) {
  process.stderr.write(`aggregate-layout: ${error.message}\n`);
  process.exit(1);
}

/*
 * Independent oracle for the generic-record HIR v1 contract (#1674).
 *
 * This file shares no code with the compiler. It is written from
 * generic-record-hir-v1.md and from the #303 frame in
 * spec/modules/module-identity.md, so a disagreement between it and the
 * compiler is a finding rather than a diff in a shared helper.
 *
 * Two jobs:
 *   1. build a canonical document from a structured case, deriving every
 *      TypeParameterId and ConstructedTypeId from its preimage, and
 *   2. validate a document against the contract: recompute every derived
 *      identity, check canonical order and the substituted fields, and refuse
 *      the limit and cycle cases.
 */

import { createHash } from "node:crypto";

export class GenericRecordError extends Error {
    constructor(code, message) {
        super(message);
        this.name = "GenericRecordError";
        this.code = code;
    }
}

function refuse(code, message) {
    throw new GenericRecordError(code, message);
}

/* --------------------------------------------------------------- framing */

const FRAME_PREFIX = Buffer.from("KOFUN\0", "latin1");

export const DOMAINS = Object.freeze({
    typeParameter: "kofun.id.type-parameter/v3",
    constructedType: "kofun.id.constructed-type/v3",
    primitive: "kofun.id.primitive/v1",
});

export function framedHash(domain, payload) {
    const domainBytes = Buffer.from(domain, "ascii");
    if (domainBytes.length > 0xffff) {
        refuse("internal", `domain too long: ${domain}`);
    }
    const header = Buffer.alloc(6);
    header.writeUInt16BE(domainBytes.length, 0);
    header.writeUInt32BE(payload.length, 2);
    return createHash("sha256")
        .update(FRAME_PREFIX)
        .update(header.subarray(0, 2))
        .update(domainBytes)
        .update(header.subarray(2))
        .update(payload)
        .digest("hex");
}

export const LIMITS = Object.freeze({
    binders_per_declaration: 2,
    instantiations_per_declaration: 8,
    constructed_depth: 8,
    declarations: 64,
    fields_per_declaration: 256,
    field_name_bytes: 65535,
    display_bytes: 128,
    document_bytes: 1048576,
});

export const CODES = Object.freeze({
    tooManyParameters: "E2S192",
    duplicateParameter: "E2S193",
    unboundParameter: "E2S194",
    arityMismatch: "E2S195",
    unknownNominal: "E2S196",
    instantiationLimit: "E2S197",
    depthExceeded: "E2S198",
    directCycle: "E2S199",
    mutualCycle: "E2S200",
    unsupportedField: "E2S201",
    unsupportedBinder: "E2S202",
});

export const PRIMITIVES = Object.freeze(["Int", "Bool", "Text", "Unit"]);

/* ------------------------------------------------------------- byte tools */

function u8(value) {
    return Buffer.from([value & 0xff]);
}

function u16be(value) {
    if (!Number.isInteger(value) || value < 0 || value > 0xffff) {
        refuse("internal", `not a u16: ${value}`);
    }
    const bytes = Buffer.alloc(2);
    bytes.writeUInt16BE(value, 0);
    return bytes;
}

function identityBytes(hex, what) {
    if (typeof hex !== "string" || !/^[0-9a-f]{64}$/.test(hex)) {
        refuse("internal", `${what} is not 64 lowercase hexadecimal digits: ${hex}`);
    }
    return Buffer.from(hex, "hex");
}

function concat(parts) {
    return Buffer.concat(parts);
}

function sequence(items, encode) {
    if (items.length > 0xffff) {
        refuse("internal", "sequence exceeds its 16-bit count");
    }
    return concat([u16be(items.length), ...items.map(encode)]);
}

/* --------------------------------------------------------- derived ids */

export function primitiveTypeId(name) {
    if (!PRIMITIVES.includes(name)) {
        refuse(CODES.unsupportedField, `unsupported primitive \`${name}\``);
    }
    return framedHash(DOMAINS.primitive, Buffer.from(name, "ascii"));
}

/*
 * The existing anonymous-single-file `kofun.id.file/v1` identity over the
 * logical path (scope-HIR v2 §11 reuses the same preimage). Kept here rather
 * than imported so the oracle does not share an implementation with the
 * compiler.
 */
export function fileId(logicalPath) {
    const packageBytes =
        "kofun.package-id/v1\nkind=anonymous-single-file\nlogical-source=" + logicalPath + "\n";
    const payload =
        "kofun.file-id-input/v1\npackage-payload-begin\n" + packageBytes +
        "package-payload-end\nlogical-path=" + logicalPath +
        "\nsource-role=authored\nprovenance=explicit-source\n";
    return framedHash("kofun.id.file/v1", Buffer.from(payload, "utf8"));
}

export function typeParameterId(ownerHex, ordinal) {
    const payload = concat([identityBytes(ownerHex, "owner TypeId"), u8(1), u16be(ordinal)]);
    return framedHash(DOMAINS.typeParameter, payload);
}

export function encodeTypeRef(node, depth = 0) {
    if (depth > LIMITS.constructed_depth) {
        refuse(CODES.depthExceeded, "constructed TypeRef depth above 8");
    }
    switch (node.tag) {
        case "primitive":
            return concat([u8(1), identityBytes(node.id, "PrimitiveTypeId")]);
        case "parameter":
            return concat([u8(2), identityBytes(node.id, "TypeParameterId")]);
        case "nominal":
            return concat([
                u8(3),
                identityBytes(node.id, "TypeId"),
                sequence(node.arguments ?? [], (argument) => encodeTypeRef(argument, depth + 1)),
            ]);
        case "constructed":
            return concat([u8(4), identityBytes(node.id, "ConstructedTypeId")]);
        default:
            refuse("internal", `unknown TypeRef tag: ${String(node.tag)}`);
    }
    return Buffer.alloc(0);
}

export function constructedTypeId(declarationHex, arguments_) {
    const payload = concat([
        identityBytes(declarationHex, "declaration TypeId"),
        sequence(arguments_, (argument) => encodeTypeRef(argument)),
    ]);
    return framedHash(DOMAINS.constructedType, payload);
}

/* ------------------------------------------------------- canonical json */

export function canonicalJson(value) {
    if (value === null || typeof value === "boolean" || typeof value === "number") {
        return JSON.stringify(value);
    }
    if (typeof value === "string") {
        return JSON.stringify(value);
    }
    if (Array.isArray(value)) {
        return `[${value.map(canonicalJson).join(",")}]`;
    }
    if (typeof value === "object") {
        const keys = Object.keys(value).sort();
        return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
    }
    refuse("internal", `not canonically encodable: ${String(value)}`);
    return "";
}

/* ------------------------------------------------------------ case build */

const IDENT = /^[A-Za-z_][A-Za-z0-9_]*$/;

function fieldName(name) {
    if (typeof name !== "string" || name.length === 0 || !IDENT.test(name)) {
        refuse(CODES.unsupportedField, `invalid field name: ${String(name)}`);
    }
    if (Buffer.byteLength(name, "utf8") > LIMITS.field_name_bytes) {
        refuse(CODES.unsupportedField, `field name over ${LIMITS.field_name_bytes} bytes`);
    }
    return name;
}

/*
 * A case names declarations in source order and, per declaration, the concrete
 * applications its source mentions in first-use order. TypeIds are given (the
 * nominal declaration identity is the existing module-identity scheme, outside
 * this slice); the two #1673 identities are always derived here.
 */
export function buildDocument(caseValue) {
    if (!caseValue || typeof caseValue !== "object") {
        refuse("internal", "case is not an object");
    }
    const declarations = caseValue.declarations ?? [];
    if (declarations.length > LIMITS.declarations) {
        refuse("internal", `more than ${LIMITS.declarations} declarations`);
    }
    const byName = new Map(declarations.map((declaration) => [declaration.name, declaration]));

    const binderNames = (declaration) => {
        const binders = declaration.binders ?? [];
        if (binders.length > LIMITS.binders_per_declaration) {
            refuse(CODES.tooManyParameters, `\`${declaration.name}\` declares ${binders.length} type parameters`);
        }
        const names = [];
        const seen = new Set();
        for (const binder of binders) {
            if (typeof binder !== "string") {
                refuse(CODES.unsupportedBinder, `unsupported binder in \`${declaration.name}\``);
            }
            if (!IDENT.test(binder) || seen.has(binder)) {
                refuse(CODES.duplicateParameter, `duplicate or invalid type parameter in \`${declaration.name}\``);
            }
            seen.add(binder);
            names.push(binder);
        }
        return names;
    };

    const materialize = (raw, declaration, names, depth) => {
        if (depth > LIMITS.constructed_depth) {
            refuse(CODES.depthExceeded, "constructed TypeRef depth above 8");
        }
        if (raw && typeof raw === "object" && "primitive" in raw) {
            return { id: primitiveTypeId(raw.primitive), tag: "primitive" };
        }
        if (raw && typeof raw === "object" && "parameter" in raw) {
            const ordinal = names.indexOf(raw.parameter);
            if (ordinal < 0) {
                refuse(CODES.unboundParameter, `unbound type parameter \`${raw.parameter}\` in \`${declaration.name}\``);
            }
            return { id: typeParameterId(declaration.id, ordinal), tag: "parameter" };
        }
        if (raw && typeof raw === "object" && "nominal" in raw) {
            const target = byName.get(raw.nominal);
            if (!target) {
                refuse(CODES.unknownNominal, `unknown nominal type \`${raw.nominal}\``);
            }
            const targetNames = binderNames(target);
            const arguments_ = raw.arguments ?? [];
            if (arguments_.length !== targetNames.length) {
                refuse(CODES.arityMismatch, `\`${raw.nominal}\` expects ${targetNames.length} arguments, got ${arguments_.length}`);
            }
            return {
                arguments: arguments_.map((argument) => materialize(argument, declaration, names, depth + 1)),
                id: target.id,
                tag: "nominal",
            };
        }
        refuse(CODES.unsupportedField, "unsupported field type");
        return null;
    };

    const fieldsOf = (declaration, names) => {
        const fields = declaration.fields ?? [];
        if (fields.length > LIMITS.fields_per_declaration) {
            refuse(CODES.unsupportedField, `\`${declaration.name}\` has more than ${LIMITS.fields_per_declaration} fields`);
        }
        return fields.map((field) => ({ name: fieldName(field.name), type: materialize(field.type, declaration, names, 0) }));
    };

    const substitute = (fields, declaration, names, arguments_) => {
        const walk = (node) => {
            if (node.tag === "parameter") {
                for (let ordinal = 0; ordinal < names.length; ordinal += 1) {
                    if (typeParameterId(declaration.id, ordinal) === node.id) {
                        return arguments_[ordinal];
                    }
                }
                return node;
            }
            if (node.tag === "nominal") {
                return { arguments: node.arguments.map(walk), id: node.id, tag: "nominal" };
            }
            return node;
        };
        return fields.map((field) => ({ name: field.name, type: walk(field.type) }));
    };

    const out = declarations.map((declaration) => {
        const names = binderNames(declaration);
        const fields = fieldsOf(declaration, names);
        const applications = [];
        const seen = new Set();
        for (const application of declaration.applications ?? []) {
            const arguments_ = (application.arguments ?? []).map((argument) =>
                materialize(argument, declaration, names, 0),
            );
            if (arguments_.length !== names.length) {
                refuse(CODES.arityMismatch, `\`${declaration.name}\` expects ${names.length} arguments, got ${arguments_.length}`);
            }
            const key = canonicalJson(arguments_);
            if (!seen.has(key)) {
                seen.add(key);
                if (seen.size > LIMITS.instantiations_per_declaration) {
                    refuse(CODES.instantiationLimit, `\`${declaration.name}\` has more than ${LIMITS.instantiations_per_declaration} concrete instantiations`);
                }
            }
            applications.push({
                arguments: arguments_,
                fields: substitute(fields, declaration, names, arguments_),
                id: constructedTypeId(declaration.id, arguments_),
            });
        }
        return {
            applications,
            binders: names.map((_, ordinal) => ({
                id: typeParameterId(declaration.id, ordinal),
                kind: "type",
                ordinal,
            })),
            fields,
            id: declaration.id,
            kind: "record",
            name: declaration.name,
        };
    });

    return {
        declarations: out,
        file_id: fileId(caseValue.logical_path ?? "input.kofun"),
        limits: { ...LIMITS },
        profile: "kofun.stage2-analysis/generic-record/v1",
        schema: "kofun.generic-record-hir/v1",
    };
}

/* ------------------------------------------------------------ validation */

function substituteValidated(fields, binders, arguments_) {
    const walk = (node) => {
        if (node.tag === "parameter") {
            const ordinal = binders.findIndex((binder) => binder.id === node.id);
            return ordinal >= 0 ? arguments_[ordinal] : node;
        }
        if (node.tag === "nominal") {
            return { arguments: node.arguments.map(walk), id: node.id, tag: "nominal" };
        }
        return node;
    };
    return fields.map((field) => ({ name: field.name, type: walk(field.type) }));
}

function checkTypeRef(node, binders, idsByName) {
    switch (node.tag) {
        case "primitive":
            if (!/^[0-9a-f]{64}$/.test(node.id)) refuse("internal", "primitive id");
            return;
        case "parameter":
            if (!binders.some((binder) => binder.id === node.id)) {
                refuse(CODES.unboundParameter, "parameter does not name a binder");
            }
            return;
        case "nominal":
            if (![...idsByName.values()].includes(node.id)) {
                refuse(CODES.unknownNominal, "nominal does not name a declaration");
            }
            (node.arguments ?? []).forEach((argument) => checkTypeRef(argument, binders, idsByName));
            return;
        case "constructed":
            return;
        default:
            refuse(CODES.unsupportedField, "unknown TypeRef tag");
    }
}

export function validateDocument(document) {
    if (!document || typeof document !== "object") refuse("internal", "document is not an object");
    if (document.schema !== "kofun.generic-record-hir/v1") refuse("internal", "wrong schema");
    if (document.profile !== "kofun.stage2-analysis/generic-record/v1") refuse("internal", "wrong profile");
    if (!/^[0-9a-f]{64}$/.test(document.file_id)) refuse("internal", "file_id is not an identity");
    for (const [name, value] of Object.entries(LIMITS)) {
        if (document.limits?.[name] !== value) refuse("internal", `limit ${name} is not ${value}`);
    }
    const declarations = document.declarations ?? [];
    if (declarations.length > LIMITS.declarations) refuse("internal", "declaration limit");
    const idsByName = new Map(declarations.map((declaration) => [declaration.name, declaration.id]));
    for (const declaration of declarations) {
        if (declaration.kind !== "record") refuse("internal", "declaration kind is not record");
        if (!/^[0-9a-f]{64}$/.test(declaration.id)) refuse("internal", "declaration id is not an identity");
        const binders = declaration.binders ?? [];
        if (binders.length > LIMITS.binders_per_declaration) refuse(CODES.tooManyParameters, "too many parameters");
        binders.forEach((binder, ordinal) => {
            if (binder.kind !== "type") refuse(CODES.unsupportedBinder, "binder kind");
            if (binder.ordinal !== ordinal) refuse("internal", "binder ordinal is not declaration order");
            if (binder.id !== typeParameterId(declaration.id, ordinal)) {
                refuse("internal", "binder id is not derived from its preimage");
            }
        });
        const fields = declaration.fields ?? [];
        if (fields.length > LIMITS.fields_per_declaration) refuse("internal", "field limit");
        for (const field of fields) {
            fieldName(field.name);
            checkTypeRef(field.type, binders, idsByName);
        }
        const applications = declaration.applications ?? [];
        if (applications.length > LIMITS.instantiations_per_declaration) refuse(CODES.instantiationLimit, "instantiation limit");
        const seen = new Set();
        for (const application of applications) {
            const key = canonicalJson(application.arguments ?? []);
            if (seen.has(key)) refuse("internal", "duplicate instantiation");
            seen.add(key);
            for (const argument of application.arguments ?? []) checkTypeRef(argument, binders, idsByName);
            if (application.id !== constructedTypeId(declaration.id, application.arguments ?? [])) {
                refuse("internal", "constructed id is not derived from its preimage");
            }
            const expected = substituteValidated(declaration.fields ?? [], binders, application.arguments ?? []);
            if (canonicalJson(expected) !== canonicalJson(application.fields ?? [])) {
                refuse("internal", "substituted fields disagree with the arguments");
            }
        }
    }
    return true;
}

/* ------------------------------------------------------------- cycles */

/*
 * This slice has no indirection form, so every field reference is by value and
 * a declaration graph edge that returns to its source is a refusal. The whole
 * graph is classified, not one declaration in isolation, which is what makes
 * the mutual case reachable.
 */
export function recordCycle(declarations) {
    const edges = new Map();
    for (const declaration of declarations) {
        const targets = new Set();
        const walk = (node) => {
            if (node.tag === "nominal") {
                targets.add(node.id);
                (node.arguments ?? []).forEach(walk);
            }
        };
        for (const field of declaration.fields ?? []) walk(field.type);
        edges.set(declaration.id, targets);
    }
    const state = new Map();
    const visit = (id) => {
        if (state.get(id) === "done") return;
        state.set(id, "active");
        for (const target of edges.get(id) ?? []) {
            if (state.get(target) === "active") {
                if (target === id) refuse(CODES.directCycle, "by-value self cycle");
                refuse(CODES.mutualCycle, "mutual by-value cycle");
            }
            visit(target);
        }
        state.set(id, "done");
    };
    for (const id of edges.keys()) visit(id);
}

/* ------------------------------------------------------------ serialization */

export function serializeDocument(document) {
    return `${canonicalJson(document)}\n`;
}

export function parseDocument(text) {
    return JSON.parse(text);
}

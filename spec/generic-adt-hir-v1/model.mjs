/*
 * Independent oracle for the generic-ADT HIR v1 contract (#1675).
 *
 * This file shares no code with the compiler. It is written from
 * generic-adt-hir-v1.md and from the #303 frame in
 * spec/modules/module-identity.md, so a disagreement between it and the
 * compiler is a finding rather than a diff in a shared helper.
 *
 * It does import the *frozen identity core* from the generic-record oracle
 * (`../generic-record-hir-v1/model.mjs`): the framed hash, TypeParameterId,
 * ConstructedTypeId, PrimitiveTypeId, the TypeRef byte encoding, the file
 * identity and canonical JSON. That import is the contract: #1673 decision 2(a)
 * and the issue require the ADT child to reuse the #1674 core UNCHANGED, so an
 * ADT-local copy of any of them would be a second definition that could drift.
 *
 * Two jobs:
 *   1. build a canonical document from a structured case, deriving every
 *      TypeParameterId and ConstructedTypeId from its preimage, substituting
 *      applications through ADT constructor payloads and record fields, and
 *      classifying by-value cycles over records and ADTs together, and
 *   2. validate a document against the contract: recompute every derived
 *      identity, check canonical order and the substituted members.
 */

import {
    PRIMITIVES,
    canonicalJson,
    constructedTypeId,
    fileId,
    framedHash,
    primitiveTypeId,
    typeParameterId,
} from "../generic-record-hir-v1/model.mjs";

export { canonicalJson, constructedTypeId, fileId, framedHash, primitiveTypeId, typeParameterId };

export class GenericAdtError extends Error {
    constructor(code, message) {
        super(message);
        this.name = "GenericAdtError";
        this.code = code;
    }
}

function refuse(code, message) {
    throw new GenericAdtError(code, message);
}

export const LIMITS = Object.freeze({
    binders_per_declaration: 2,
    instantiations_per_declaration: 8,
    constructed_depth: 8,
    declarations: 64,
    constructors_per_declaration: 64,
    payload_fields_per_constructor: 1,
    fields_per_declaration: 256,
    name_bytes: 65535,
    document_bytes: 1048576,
});

/*
 * E2S199 and E2S200 are the generic-record contract's direct and mutual
 * by-value cycle codes. A cycle whose members are all records keeps them here,
 * unchanged: the two documents agree on a record cycle.
 */
export const CODES = Object.freeze({
    recordDirectCycle: "E2S199",
    recordMutualCycle: "E2S200",
    tooManyParameters: "E2S203",
    duplicateParameter: "E2S204",
    unboundParameter: "E2S205",
    arityMismatch: "E2S206",
    unknownNominal: "E2S207",
    instantiationLimit: "E2S208",
    depthExceeded: "E2S209",
    adtDirectCycle: "E2S210",
    adtMutualCycle: "E2S211",
    mixedCycle: "E2S212",
    unsupportedPayload: "E2S213",
    unsupportedBinder: "E2S214",
    duplicateType: "E2S215",
    constructorShape: "E2S216",
    sizeLimit: "E2S217",
});

export { PRIMITIVES };

/* --------------------------------------------------------------- type ids */

function hex32(value) {
    const bytes = Buffer.alloc(4);
    bytes.writeUInt32BE(value >>> 0, 0);
    return bytes.toString("hex");
}

/*
 * The declaration kind is part of the SymbolId preimage (module-identity.md:
 * "the kind distinguishes, for example, a value function from a value
 * constructor"), so a record and an ADT of one spelling are different TypeIds.
 * `record` is the exact preimage the generic-record contract froze; `adt` is
 * the same TLV with the three-byte kind text `adt`.
 */
const KIND_TLV = Object.freeze({
    record: "8003000000067265636f7264",
    adt: "800300000003616474",
});

export function declarationTypeId(logicalPath, name, kind) {
    if (!(kind in KIND_TLV)) {
        refuse("internal", `unknown declaration kind: ${String(kind)}`);
    }
    const packageBytes =
        "kofun.package-id/v1\nkind=anonymous-single-file\nlogical-source=" + logicalPath + "\n";
    const moduleId = framedHash(
        "kofun.id.module/v1",
        Buffer.from(
            "kofun.module-id-input/v1\npackage-payload-begin\n" + packageBytes +
                "package-payload-end\nkind=synthetic-root\n",
            "utf8",
        ),
    );
    const namespaceId = framedHash(
        "kofun.id.namespace/v1",
        Buffer.from("kofun.namespace-id/v1\ntag=1\nname=type\n", "utf8"),
    );
    const nameHex = Buffer.from(name, "utf8").toString("hex");
    const payload =
        "800100000020" + moduleId + "800200000020" + namespaceId + KIND_TLV[kind] +
        "8004" + hex32(Buffer.byteLength(name, "utf8")) + nameHex;
    return framedHash("kofun.id.symbol/v1", Buffer.from(payload, "hex"));
}

/* ------------------------------------------------------------ case build */

const IDENT = /^[A-Za-z_][A-Za-z0-9_]*$/;

function checkName(name, what, code = CODES.unsupportedPayload) {
    if (typeof name !== "string" || !IDENT.test(name)) {
        refuse(code, `invalid ${what} name: ${String(name)}`);
    }
    if (Buffer.byteLength(name, "utf8") > LIMITS.name_bytes) {
        refuse(CODES.sizeLimit, `${what} name over ${LIMITS.name_bytes} bytes`);
    }
    return name;
}

function declarationMembers(declaration) {
    if (declaration.kind === "record") {
        return (declaration.fields ?? []).map((field) => field.type);
    }
    const types = [];
    for (const constructor_ of declaration.constructors ?? []) {
        for (const entry of constructor_.payload ?? []) types.push(entry.type);
    }
    return types;
}

/*
 * A case names every record and ADT declaration in source order, and per
 * declaration the concrete applications its source mentions in first-use
 * order. A declaration with no type binder is *context*: it supplies a TypeId,
 * an arity of zero and by-value edges, but it is not listed in the document.
 * TypeIds are derived here from (logical path, name, kind); the two #1673
 * identities are always derived, never given.
 */
export function buildDocument(caseValue) {
    if (!caseValue || typeof caseValue !== "object") {
        refuse("internal", "case is not an object");
    }
    const declarations = caseValue.declarations ?? [];
    const logicalPath = caseValue.logical_path ?? "input.kofun";

    /*
     * Phase 1: the scan, one declaration at a time in source order: its name
     * bound, its binder list, a duplicate name, then the 64-declaration bound.
     */
    const byName = new Map();
    const binderOf = new Map();
    for (const declaration of declarations) {
        if (declaration.kind !== "record" && declaration.kind !== "adt") {
            refuse("internal", `declaration kind is neither record nor adt: ${String(declaration.kind)}`);
        }
        checkName(declaration.name, "declaration");
        const binders = declaration.binders ?? [];
        const names = [];
        const seen = new Set();
        for (const binder of binders) {
            if (typeof binder !== "string") {
                refuse(CODES.unsupportedBinder, `unsupported binder in \`${declaration.name}\``);
            }
            if (names.length >= LIMITS.binders_per_declaration) {
                refuse(CODES.tooManyParameters, `\`${declaration.name}\` declares more than two type parameters`);
            }
            if (!IDENT.test(binder) || seen.has(binder)) {
                refuse(CODES.duplicateParameter, `duplicate or invalid type parameter in \`${declaration.name}\``);
            }
            seen.add(binder);
            names.push(binder);
        }
        /*
         * A const binder is not a type binder. On an ADT it is refused outright
         * (const parameters are admissible on a nominal record only); on a record
         * it is refused beside a type binder, and a const-only list leaves the
         * record without a type binder, so it is context rather than listed.
         */
        const constBinders = declaration.constBinders ?? 0;
        if (constBinders > 0 && (declaration.kind === "adt" || names.length > 0)) {
            refuse(CODES.unsupportedBinder, `\`${declaration.name}\` declares a const binder beside or on an ADT`);
        }
        if (byName.has(declaration.name)) {
            refuse(CODES.duplicateType, `duplicate type declaration \`${declaration.name}\``);
        }
        if (byName.size + 1 > LIMITS.declarations) {
            refuse(CODES.sizeLimit, `more than ${LIMITS.declarations} record and ADT declarations`);
        }
        if (declaration.kind === "adt" &&
            (declaration.constructors ?? []).length > LIMITS.constructors_per_declaration) {
            refuse(CODES.sizeLimit, `\`${declaration.name}\` has more than ${LIMITS.constructors_per_declaration} constructors`);
        }
        byName.set(declaration.name, declaration);
        binderOf.set(declaration.name, names);
    }
    const derivedId = new Map(
        declarations.map((declaration) => [
            declaration.name,
            declarationTypeId(logicalPath, declaration.name, declaration.kind),
        ]),
    );

    /* Phase 2: by-value cycle classification over the whole graph. */
    classifyCycles(declarations);

    /* Phase 3: materialize every listed declaration's members. */
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
            return { id: typeParameterId(derivedId.get(declaration.name), ordinal), tag: "parameter" };
        }
        if (raw && typeof raw === "object" && "nominal" in raw) {
            const target = byName.get(raw.nominal);
            if (!target && (raw.arguments ?? []).length === 0) {
                /* A bare name that is no binder and no declaration is unbound. */
                refuse(CODES.unboundParameter, `unbound type parameter \`${raw.nominal}\` in \`${declaration.name}\``);
            }
            if (!target) {
                refuse(CODES.unknownNominal, `unknown nominal type \`${raw.nominal}\``);
            }
            const wanted = binderOf.get(raw.nominal).length;
            const arguments_ = raw.arguments ?? [];
            if (arguments_.length !== wanted) {
                refuse(CODES.arityMismatch, `\`${raw.nominal}\` expects ${wanted} arguments, got ${arguments_.length}`);
            }
            return {
                arguments: arguments_.map((argument) => materialize(argument, declaration, names, depth + 1)),
                id: derivedId.get(raw.nominal),
                tag: "nominal",
            };
        }
        refuse(CODES.unsupportedPayload, "unsupported payload or field type");
        return null;
    };

    const fieldsOf = (declaration, names) => {
        const fields = declaration.fields ?? [];
        if (fields.length > LIMITS.fields_per_declaration) {
            refuse(CODES.sizeLimit, `\`${declaration.name}\` has more than ${LIMITS.fields_per_declaration} fields`);
        }
        return fields.map((field) => ({
            name: checkName(field.name, "field"),
            type: materialize(field.type, declaration, names, 0),
        }));
    };

    const constructorsOf = (declaration, names) => {
        const constructors = declaration.constructors ?? [];
        const seen = new Set();
        for (const constructor_ of constructors) {
            checkName(constructor_.name, "constructor", CODES.constructorShape);
            if (seen.has(constructor_.name)) {
                refuse(CODES.constructorShape, `duplicate constructor \`${constructor_.name}\``);
            }
            seen.add(constructor_.name);
            if ((constructor_.payload ?? []).length > LIMITS.payload_fields_per_constructor) {
                refuse(CODES.constructorShape, `constructor \`${constructor_.name}\` has more than one payload field`);
            }
        }
        if (constructors.length < 2) {
            refuse(CODES.constructorShape, `\`${declaration.name}\` must declare at least two constructors`);
        }
        return constructors.map((constructor_, ordinal) => ({
            name: constructor_.name,
            ordinal,
            payload: (constructor_.payload ?? []).map((entry) => ({
                name: checkName(entry.name, "payload field", CODES.constructorShape),
                type: materialize(entry.type, declaration, names, 0),
            })),
        }));
    };

    const membersOf = (declaration, names) =>
        declaration.kind === "record"
            ? { key: "fields", value: fieldsOf(declaration, names) }
            : { key: "constructors", value: constructorsOf(declaration, names) };

    const substituteType = (node, owner, names, arguments_) => {
        if (node.tag === "parameter") {
            for (let ordinal = 0; ordinal < names.length; ordinal += 1) {
                if (typeParameterId(owner, ordinal) === node.id) {
                    return arguments_[ordinal];
                }
            }
            return node;
        }
        if (node.tag === "nominal") {
            return {
                arguments: node.arguments.map((argument) => substituteType(argument, owner, names, arguments_)),
                id: node.id,
                tag: "nominal",
            };
        }
        return node;
    };

    const substituteMembers = (declaration, members, owner, names, arguments_) => {
        if (declaration.kind === "record") {
            return members.map((field) => ({
                name: field.name,
                type: substituteType(field.type, owner, names, arguments_),
            }));
        }
        return members.map((constructor_) => ({
            name: constructor_.name,
            ordinal: constructor_.ordinal,
            payload: constructor_.payload.map((entry) => ({
                name: entry.name,
                type: substituteType(entry.type, owner, names, arguments_),
            })),
        }));
    };

    const listed = declarations.filter((declaration) => binderOf.get(declaration.name).length > 0);
    const materialized = new Map();
    for (const declaration of listed) {
        const names = binderOf.get(declaration.name);
        materialized.set(declaration.name, membersOf(declaration, names));
    }

    /*
     * Phase 4: applications, one listed declaration at a time in source order.
     * Each application is materialized and substituted in first-use order, each
     * distinct concrete tuple once, and the ninth distinct tuple of one
     * declaration refuses at once.
     */
    const applicationsOf = new Map();
    for (const declaration of listed) {
        const owner = derivedId.get(declaration.name);
        const names = binderOf.get(declaration.name);
        const members = materialized.get(declaration.name);
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
            if (seen.has(key)) continue;
            seen.add(key);
            if (seen.size > LIMITS.instantiations_per_declaration) {
                refuse(CODES.instantiationLimit, `\`${declaration.name}\` has more than ${LIMITS.instantiations_per_declaration} concrete instantiations`);
            }
            applications.push({
                arguments: arguments_,
                [members.key]: substituteMembers(declaration, members.value, owner, names, arguments_),
                id: constructedTypeId(owner, arguments_),
            });
        }
        applicationsOf.set(declaration.name, applications);
    }

    const out = listed.map((declaration) => {
        const owner = derivedId.get(declaration.name);
        const names = binderOf.get(declaration.name);
        const members = materialized.get(declaration.name);
        const applications = applicationsOf.get(declaration.name);
        return {
            applications,
            binders: names.map((_, ordinal) => ({
                id: typeParameterId(owner, ordinal),
                kind: "type",
                ordinal,
            })),
            [members.key]: members.value,
            id: owner,
            kind: declaration.kind,
            name: declaration.name,
        };
    });

    const document = {
        declarations: out,
        file_id: fileId(logicalPath),
        limits: { ...LIMITS },
        profile: "kofun.stage2-analysis/generic-adt/v1",
        schema: "kofun.generic-adt-hir/v1",
    };
    if (Buffer.byteLength(`${canonicalJson(document)}\n`) > LIMITS.document_bytes) {
        refuse(CODES.sizeLimit, `document exceeds ${LIMITS.document_bytes} bytes`);
    }
    return document;
}

/* ------------------------------------------------------------- cycles */

function nominalHeads(raw, byName, out) {
    if (!raw || typeof raw !== "object") return;
    if ("nominal" in raw) {
        if (byName.has(raw.nominal) && !out.includes(raw.nominal)) out.push(raw.nominal);
        for (const argument of raw.arguments ?? []) nominalHeads(argument, byName, out);
    }
}

/*
 * Every field reference and payload reference in this slice is by value (there
 * is no indirection form), so the declaration graph's edges are the nominal
 * heads a declaration writes, in first-use order, including heads nested in
 * type arguments (a constructed type holds its arguments by value). The graph
 * covers every record and ADT, listed or not, because a plain record that
 * holds an instantiation over itself is exactly the cycle that matters.
 *
 * Roots are visited in source order and edges in first-use order; the first
 * edge that returns to an active declaration closes the cycle, and the stack
 * suffix from that declaration names its members.
 */
export function classifyCycles(declarations) {
    const byName = new Map(declarations.map((declaration) => [declaration.name, declaration]));
    const edges = new Map();
    for (const declaration of declarations) {
        const targets = [];
        for (const raw of declarationMembers(declaration)) nominalHeads(raw, byName, targets);
        edges.set(declaration.name, targets);
    }
    const done = new Set();
    const visit = (name, stack) => {
        for (const target of edges.get(name) ?? []) {
            if (target === name) {
                refuse(
                    byName.get(name).kind === "adt" ? CODES.adtDirectCycle : CODES.recordDirectCycle,
                    `\`${name}\` holds itself by value`,
                );
            }
            const at = stack.indexOf(target);
            if (at >= 0) {
                const kinds = new Set(stack.slice(at).map((member) => byName.get(member).kind));
                if (kinds.size > 1) refuse(CODES.mixedCycle, "mixed record/ADT by-value cycle");
                refuse(kinds.has("adt") ? CODES.adtMutualCycle : CODES.recordMutualCycle, "mutual by-value cycle");
            }
            if (done.has(target)) continue;
            visit(target, [...stack, target]);
        }
        done.add(name);
    };
    for (const declaration of declarations) visit(declaration.name, [declaration.name]);
}

/* ------------------------------------------------------------ validation */

function substituteValidated(node, binders, arguments_) {
    if (node.tag === "parameter") {
        const ordinal = binders.findIndex((binder) => binder.id === node.id);
        return ordinal >= 0 ? arguments_[ordinal] : node;
    }
    if (node.tag === "nominal") {
        return {
            arguments: node.arguments.map((argument) => substituteValidated(argument, binders, arguments_)),
            id: node.id,
            tag: "nominal",
        };
    }
    return node;
}

function substituteMembersValidated(declaration, binders, arguments_) {
    if (declaration.kind === "record") {
        return (declaration.fields ?? []).map((field) => ({
            name: field.name,
            type: substituteValidated(field.type, binders, arguments_),
        }));
    }
    return (declaration.constructors ?? []).map((constructor_) => ({
        name: constructor_.name,
        ordinal: constructor_.ordinal,
        payload: (constructor_.payload ?? []).map((entry) => ({
            name: entry.name,
            type: substituteValidated(entry.type, binders, arguments_),
        })),
    }));
}

function checkTypeRef(node, binders, knownIds) {
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
            if (!knownIds.has(node.id)) {
                refuse(CODES.unknownNominal, "nominal does not name a declaration");
            }
            (node.arguments ?? []).forEach((argument) => checkTypeRef(argument, binders, knownIds));
            return;
        case "constructed":
            return;
        default:
            refuse(CODES.unsupportedPayload, "unknown TypeRef tag");
    }
}

/*
 * `contextIds` are the TypeIds of declarations the case names but the document
 * does not list (no type binder). A nominal reference may name one.
 */
export function validateDocument(document, logicalPath, contextIds = []) {
    if (!document || typeof document !== "object") refuse("internal", "document is not an object");
    if (document.schema !== "kofun.generic-adt-hir/v1") refuse("internal", "wrong schema");
    if (document.profile !== "kofun.stage2-analysis/generic-adt/v1") refuse("internal", "wrong profile");
    if (!/^[0-9a-f]{64}$/.test(document.file_id)) refuse("internal", "file_id is not an identity");
    if (logicalPath !== undefined && document.file_id !== fileId(logicalPath)) {
        refuse("internal", "file_id is not derived from its logical path");
    }
    for (const [name, value] of Object.entries(LIMITS)) {
        if (document.limits?.[name] !== value) refuse("internal", `limit ${name} is not ${value}`);
    }
    if (Object.keys(document.limits ?? {}).length !== Object.keys(LIMITS).length) {
        refuse("internal", "limits is not the closed set");
    }
    const declarations = document.declarations ?? [];
    if (declarations.length > LIMITS.declarations) refuse("internal", "declaration limit");
    const knownIds = new Set([...declarations.map((declaration) => declaration.id), ...contextIds]);
    for (const declaration of declarations) {
        if (declaration.kind !== "record" && declaration.kind !== "adt") {
            refuse("internal", "declaration kind is neither record nor adt");
        }
        if (!/^[0-9a-f]{64}$/.test(declaration.id)) refuse("internal", "declaration id is not an identity");
        if (logicalPath !== undefined &&
            declaration.id !== declarationTypeId(logicalPath, declaration.name, declaration.kind)) {
            refuse("internal", "declaration id is not derived from its name and kind");
        }
        const binders = declaration.binders ?? [];
        if (binders.length < 1) refuse("internal", "a listed declaration carries no binder");
        if (binders.length > LIMITS.binders_per_declaration) refuse(CODES.tooManyParameters, "too many parameters");
        binders.forEach((binder, ordinal) => {
            if (binder.kind !== "type") refuse(CODES.unsupportedBinder, "binder kind");
            if (binder.ordinal !== ordinal) refuse("internal", "binder ordinal is not declaration order");
            if (binder.id !== typeParameterId(declaration.id, ordinal)) {
                refuse("internal", "binder id is not derived from its preimage");
            }
        });
        if (declaration.kind === "record") {
            if ("constructors" in declaration) refuse("internal", "a record carries constructors");
            const fields = declaration.fields ?? [];
            if (fields.length > LIMITS.fields_per_declaration) refuse("internal", "field limit");
            for (const field of fields) {
                checkName(field.name, "field");
                checkTypeRef(field.type, binders, knownIds);
            }
        } else {
            if ("fields" in declaration) refuse("internal", "an ADT carries fields");
            const constructors = declaration.constructors ?? [];
            if (constructors.length < 2) refuse("internal", "an ADT declares fewer than two constructors");
            if (constructors.length > LIMITS.constructors_per_declaration) refuse("internal", "constructor limit");
            const seen = new Set();
            constructors.forEach((constructor_, ordinal) => {
                checkName(constructor_.name, "constructor", CODES.constructorShape);
                if (seen.has(constructor_.name)) refuse("internal", "duplicate constructor");
                seen.add(constructor_.name);
                if (constructor_.ordinal !== ordinal) refuse("internal", "constructor ordinal is not declaration order");
                const payload = constructor_.payload ?? [];
                if (payload.length > LIMITS.payload_fields_per_constructor) refuse("internal", "payload field limit");
                for (const entry of payload) {
                    checkName(entry.name, "payload field");
                    checkTypeRef(entry.type, binders, knownIds);
                }
            });
        }
        const applications = declaration.applications ?? [];
        if (applications.length > LIMITS.instantiations_per_declaration) refuse(CODES.instantiationLimit, "instantiation limit");
        const seenArguments = new Set();
        for (const application of applications) {
            const key = canonicalJson(application.arguments ?? []);
            if (seenArguments.has(key)) refuse("internal", "duplicate instantiation");
            seenArguments.add(key);
            if ((application.arguments ?? []).length !== binders.length) refuse("internal", "application arity");
            for (const argument of application.arguments ?? []) checkTypeRef(argument, [], knownIds);
            if (application.id !== constructedTypeId(declaration.id, application.arguments ?? [])) {
                refuse("internal", "constructed id is not derived from its preimage");
            }
            const members = declaration.kind === "record" ? "fields" : "constructors";
            const expected = substituteMembersValidated(declaration, binders, application.arguments ?? []);
            if (canonicalJson(expected) !== canonicalJson(application[members] ?? [])) {
                refuse("internal", "substituted members disagree with the arguments");
            }
            const other = declaration.kind === "record" ? "constructors" : "fields";
            if (other in application) refuse("internal", "application carries the wrong member list");
        }
    }
    return true;
}

/* ------------------------------------------------------------ serialization */

export function serializeDocument(document) {
    return `${canonicalJson(document)}\n`;
}

export function parseDocument(text) {
    return JSON.parse(text);
}

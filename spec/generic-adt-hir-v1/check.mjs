#!/usr/bin/env node
/*
 * Gate for the generic-ADT HIR v1 contract (#1675).
 *
 * The independent oracle (`model.mjs`, which shares no code with the compiler)
 * recomputes every TypeParameterId and ConstructedTypeId from its preimage
 * with the #303 frame, the canonical document matches its frozen golden and its
 * closed JSON schema, constructor payloads and record fields are substituted
 * through nested TypeRefs, the by-value cycle classes and every limit and
 * refusal fire, and mutations of the preimage are caught.
 *
 * Then both halves of the canonical pair -- the Kofun half through the bounded
 * host driver and the maintained C half as the built binary -- must reproduce
 * the golden byte for byte, refuse every negative fixture with its registered
 * code and no artifact, agree with each other on every byte they print, agree
 * with the record entry on a record-only file (the executable form of "the
 * identity core is reused unchanged"), and leave ordinary compilation refusing
 * generic sources with `E2S148`.
 */

import fs from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
    CODES,
    GenericAdtError,
    LIMITS,
    buildDocument,
    canonicalJson,
    constructedTypeId,
    declarationTypeId,
    parseDocument,
    primitiveTypeId,
    serializeDocument,
    typeParameterId,
    validateDocument,
} from "./model.mjs";
import * as recordModel from "../generic-record-hir-v1/model.mjs";
import { loadCompiler, bytes, text } from "../../bootstrap/stage2/host-driver.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const FIX = `${HERE}fixtures/`;
const RECORD_FIX = `${HERE}../generic-record-hir-v1/fixtures/`;
const ROOT = `${HERE}../../`;
const PASS = [];
let failures = 0;

function pass(line) {
    PASS.push(`PASS: ${line}`);
}

function fail(label, detail) {
    failures += 1;
    process.stderr.write(`FAIL: ${label}${detail ? `: ${detail}` : ""}\n`);
}

function check(condition, label, detail) {
    if (!condition) fail(label, detail);
    return Boolean(condition);
}

function readJson(path) {
    return JSON.parse(fs.readFileSync(path, "utf8"));
}

function clone(value) {
    return JSON.parse(JSON.stringify(value));
}

function expectRefuse(code, label, thunk) {
    try {
        thunk();
    } catch (error) {
        if (error instanceof GenericAdtError && error.code === code) {
            return;
        }
        fail(label, `expected ${code}, got ${error.code ?? error.name}: ${error.message}`);
        return;
    }
    fail(label, `expected ${code}, but the case was accepted`);
}

const stage2 = process.env.KOFUN_GENERIC_ADT_STAGE2;
const stage2O0 = process.env.KOFUN_GENERIC_ADT_STAGE2_O0;
const WORK = process.env.KOFUN_GENERIC_ADT_WORK;
if (!stage2 || !fs.existsSync(stage2) || !WORK || !fs.existsSync(WORK)) {
    process.stderr.write("FAIL: KOFUN_GENERIC_ADT_STAGE2 and KOFUN_GENERIC_ADT_WORK must name a built binary and a work directory\n");
    process.exit(1);
}

/* ------------------------------------------------- a small schema checker */

/*
 * The schema file is part of the contract, so the gate holds documents to it.
 * This checks exactly the keywords the schema uses: $ref, const, type,
 * required, properties, additionalProperties:false, items, minItems, maxItems,
 * minLength, pattern, minimum, maximum and oneOf.
 */
function schemaErrors(schema, value) {
    const errors = [];
    const lookup = (reference) =>
        reference.slice(2).split("/").reduce((node, part) => node[part], schema);
    const walk = (node, subject, at, sink) => {
        if (node.$ref) {
            walk(lookup(node.$ref), subject, at, sink);
            return;
        }
        if ("const" in node && subject !== node.const) sink.push(`${at}: not ${JSON.stringify(node.const)}`);
        if (node.type === "object" && (subject === null || typeof subject !== "object" || Array.isArray(subject))) {
            sink.push(`${at}: not an object`);
            return;
        }
        if (node.type === "array" && !Array.isArray(subject)) {
            sink.push(`${at}: not an array`);
            return;
        }
        if (node.type === "string" && typeof subject !== "string") {
            sink.push(`${at}: not a string`);
            return;
        }
        if (node.type === "integer" && !Number.isInteger(subject)) {
            sink.push(`${at}: not an integer`);
            return;
        }
        if (typeof subject === "string") {
            if (node.minLength !== undefined && subject.length < node.minLength) sink.push(`${at}: too short`);
            if (node.pattern !== undefined && !new RegExp(node.pattern).test(subject)) sink.push(`${at}: pattern`);
        }
        if (Number.isInteger(subject)) {
            if (node.minimum !== undefined && subject < node.minimum) sink.push(`${at}: below minimum`);
            if (node.maximum !== undefined && subject > node.maximum) sink.push(`${at}: above maximum`);
        }
        if (Array.isArray(subject)) {
            if (node.minItems !== undefined && subject.length < node.minItems) sink.push(`${at}: too few items`);
            if (node.maxItems !== undefined && subject.length > node.maxItems) sink.push(`${at}: too many items`);
            if (node.items) subject.forEach((item, index) => walk(node.items, item, `${at}[${index}]`, sink));
        }
        if (subject !== null && typeof subject === "object" && !Array.isArray(subject)) {
            for (const key of node.required ?? []) if (!(key in subject)) sink.push(`${at}: missing ${key}`);
            if (node.additionalProperties === false) {
                for (const key of Object.keys(subject)) {
                    if (!(key in (node.properties ?? {}))) sink.push(`${at}: unexpected ${key}`);
                }
            }
            for (const [key, child] of Object.entries(node.properties ?? {})) {
                if (key in subject) walk(child, subject[key], `${at}.${key}`, sink);
            }
        }
        if (node.oneOf) {
            const matching = node.oneOf.filter((branch) => {
                const branchErrors = [];
                walk(branch, subject, at, branchErrors);
                return branchErrors.length === 0;
            });
            if (matching.length !== 1) sink.push(`${at}: matches ${matching.length} of ${node.oneOf.length} alternatives`);
        }
    };
    walk(schema, value, "$", errors);
    return errors;
}

const schema = readJson(`${HERE}kofun.generic-adt-hir.v1.schema.json`);

/* ----------------------------------------------------- golden and the core */

const positive = readJson(`${FIX}positive.case.json`);
const document = buildDocument(positive);
const goldenText = serializeDocument(document);
const goldenPath = `${FIX}positive.golden.json`;
if (fs.existsSync(goldenPath)) {
    if (fs.readFileSync(goldenPath, "utf8") !== goldenText) {
        fail("positive golden", "the oracle no longer reproduces the committed document");
    } else {
        pass("the canonical positive document matches its frozen golden byte for byte");
    }
} else {
    fail("positive golden", `missing ${goldenPath}`);
}

const contextIds = positive.declarations
    .filter((declaration) => (declaration.binders ?? []).length === 0)
    .map((declaration) => declarationTypeId(positive.logical_path, declaration.name, declaration.kind));
validateDocument(parseDocument(goldenText), positive.logical_path, contextIds);
pass("every derived identity recomputes from its preimage and the limits hold");
if (Buffer.byteLength(goldenText) > LIMITS.document_bytes) fail("document bytes", "over the limit");

const goldenErrors = schemaErrors(schema, parseDocument(goldenText));
check(goldenErrors.length === 0, "schema", `the golden violates its own schema: ${goldenErrors.slice(0, 3).join("; ")}`);
if (goldenErrors.length === 0) pass("the positive document conforms to the closed schema");

for (const [label, mutate] of [
    ["an unexpected key", (doc) => { doc.declarations[0].extra = 1; }],
    ["a missing limit", (doc) => { delete doc.limits.name_bytes; }],
    ["a third binder", (doc) => {
        doc.declarations[1].binders.push(clone(doc.declarations[1].binders[0]));
    }],
    ["a one-constructor ADT", (doc) => { doc.declarations[0].constructors.pop(); }],
    ["a record application carrying constructors", (doc) => {
        const recordDeclaration = doc.declarations.find((declaration) => declaration.kind === "record");
        recordDeclaration.applications[0].constructors = [];
    }],
    ["an unknown TypeRef tag", (doc) => { doc.declarations[0].constructors[1].payload[0].type.tag = "function"; }],
    ["a payload with two fields", (doc) => {
        doc.declarations[0].constructors[1].payload.push(clone(doc.declarations[0].constructors[1].payload[0]));
    }],
]) {
    const mutated = parseDocument(goldenText);
    mutate(mutated);
    check(schemaErrors(schema, mutated).length > 0, `schema mutation: ${label}`, "the schema accepted it");
}
pass("the schema refuses unexpected, missing, over-bound and mis-shaped content");

/*
 * The identity core is imported, not copied: the ADT oracle's identity
 * functions are the record oracle's own function objects, so there is exactly
 * one definition of each.
 */
check(
    typeParameterId === recordModel.typeParameterId &&
        constructedTypeId === recordModel.constructedTypeId &&
        primitiveTypeId === recordModel.primitiveTypeId &&
        canonicalJson === recordModel.canonicalJson,
    "identity core reuse",
    "the ADT oracle carries its own copy of an identity function",
);
check(
    declarationTypeId(positive.logical_path, "Box", "record") ===
        recordModel.declarationTypeId(positive.logical_path, "Box"),
    "record TypeId",
    "a record's TypeId differs between the record and ADT contracts",
);
pass("the identity core is the record contract's own, and a record keeps its TypeId");

/* ------------------------------------------------------------- identities */

const byName = new Map(document.declarations.map((declaration) => [declaration.name, declaration]));
const opt = byName.get("Opt");
const box = byName.get("Box");
const wrapped = byName.get("Wrapped");
const holder = byName.get("Holder");
const tagged = byName.get("Tagged");
const late = byName.get("Late");
const nest = byName.get("Nest");
const colorId = declarationTypeId(positive.logical_path, "Color", "adt");

const kindBlind = declarationTypeId(positive.logical_path, "Opt", "record");
if (kindBlind === opt.id || declarationTypeId(positive.logical_path, "Opt", "adt") !== opt.id) {
    fail("declaration kind", "an ADT and a record of one name did not mint distinct TypeIds");
} else {
    pass("the declaration kind is part of the TypeId: a record and an ADT of one name differ");
}

const tIds = new Set(
    ["Opt", "Wrapped", "Holder", "Tagged", "Late", "Nest", "Box", "Slot"].map((name) => byName.get(name).binders[0].id),
);
if (tIds.size !== 8) {
    fail("declaration-scoped shadowing", "eight owners named `T` did not mint eight ids");
} else {
    pass("a binder spelled `T` in eight declarations, records and ADTs, mints eight distinct ids");
}

if (tagged.constructors[1].payload[0].type.id !== colorId || tagged.constructors[1].payload[0].type.arguments.length !== 0) {
    fail("forward use", "Tagged.Colored did not resolve to the later non-generic ADT `Color`");
} else {
    pass("a payload may name a non-generic ADT collected later, with zero arguments (forward use)");
}

const wrappedText = wrapped.applications[0].constructors[1].payload[0].type;
if (wrappedText.id !== opt.id || wrappedText.arguments[0].tag !== "primitive") {
    fail("substitution", "Wrapped[Text].Present.inner is not Opt[Text]");
} else {
    pass("Wrapped[Text] substitutes its argument into the nested nominal payload Opt[T]");
}

const wrappedBox = wrapped.applications[1].constructors[1].payload[0].type;
if (wrappedBox.id !== opt.id || wrappedBox.arguments[0].id !== box.id ||
    wrappedBox.arguments[0].arguments[0].tag !== "primitive") {
    fail("nested substitution", "Wrapped[Box[Int]].Present.inner is not Opt[Box[Int]]");
} else {
    pass("Wrapped[Box[Int]] substitutes through two levels: Opt[Box[Int]]");
}

const laterUnit = late.applications[0].constructors[1].payload[0].type;
if (laterUnit.arguments[0].id !== opt.id || laterUnit.arguments[0].arguments[0].tag !== "primitive") {
    fail("deep substitution", "Late[Unit].Later.next is not Opt[Opt[Unit]]");
} else {
    pass("Late[Unit] substitutes the innermost parameter of Opt[Opt[T]]");
}

const deepBool = nest.applications[0].constructors[1].payload[0].type;
if (deepBool.arguments.length !== 2 || deepBool.arguments[1].arguments[0].tag !== "primitive") {
    fail("multi-argument substitution", "Nest[Bool].Deep.inner is not Either[Bool, Opt[Bool]]");
} else {
    pass("Nest[Bool] substitutes both parameters of Either[T, Opt[T]], including the one nested under Opt");
}

const holderInt = holder.applications[0].constructors[1].payload[0].type;
if (holderInt.id !== box.id || holderInt.arguments[0].tag !== "primitive") {
    fail("ADT over record", "Holder[Int].Held.box is not Box[Int]");
} else {
    pass("an ADT payload substitutes through a record application, Holder[Int] holding Box[Int]");
}

if (document.declarations.some((declaration) => declaration.name === "Color")) {
    fail("context", "the non-generic `Color` was listed");
} else {
    pass("a declaration with no type binder is context: it has a TypeId but is not listed");
}

if (opt.constructors.map((constructor_) => constructor_.ordinal).join() !== "0,1" ||
    opt.applications[0].constructors.map((constructor_) => constructor_.ordinal).join() !== "0,1") {
    fail("ordinals", "constructor ordinals are not declaration order");
} else {
    pass("constructor ordinals are declaration order, in the declaration and in every application");
}

/* The two #1673 identities are the core's: an ADT application's id equals the
 * core function over the ADT's TypeId and its arguments. */
const optInt = [{ id: primitiveTypeId("Int"), tag: "primitive" }];
if (opt.applications[0].id !== recordModel.constructedTypeId(opt.id, optInt)) {
    fail("constructed identity", "Opt[Int] disagrees with the record core's ConstructedTypeId");
} else {
    pass("Opt[Int]'s ConstructedTypeId is the record core's function of the ADT TypeId and its arguments");
}

/* Mutations. */
const renamed = clone(positive);
const optCase = renamed.declarations.find((declaration) => declaration.name === "Opt");
optCase.binders = ["Q"];
optCase.constructors[1].payload[0].type.parameter = "Q";
if (canonicalJson(buildDocument(renamed)) !== canonicalJson(document)) {
    fail("spelling independence", "renaming a binder changed a derived identity");
} else {
    pass("renaming a binder does not change any derived identity");
}

const movedOwner = clone(positive);
for (const declaration of movedOwner.declarations) {
    if (declaration.name === "Opt") declaration.name = "Maybe";
    const rename = (node) => {
        if (node && typeof node === "object") {
            if (node.nominal === "Opt") node.nominal = "Maybe";
            Object.values(node).forEach(rename);
        }
    };
    rename(declaration);
}
const moved = buildDocument(movedOwner);
const maybe = moved.declarations.find((declaration) => declaration.name === "Maybe");
if (maybe.binders[0].id !== opt.binders[0].id && maybe.applications[0].id !== opt.applications[0].id) {
    pass("a mutated owner preimage moves both TypeParameterId and ConstructedTypeId");
} else {
    fail("preimage sensitivity", "an owner mutation left a derived identity unchanged");
}

const either = byName.get("Either");
const intBool = constructedTypeId(either.id, [
    { id: primitiveTypeId("Int"), tag: "primitive" },
    { id: primitiveTypeId("Bool"), tag: "primitive" },
]);
const boolInt = constructedTypeId(either.id, [
    { id: primitiveTypeId("Bool"), tag: "primitive" },
    { id: primitiveTypeId("Int"), tag: "primitive" },
]);
if (intBool !== boolInt && either.applications[0].id === intBool) {
    pass("ConstructedTypeId separates argument order that discovery order does not");
} else {
    fail("argument order", "ConstructedTypeId did not separate the two orders");
}

const reordered = clone(positive);
reordered.declarations = [...reordered.declarations].reverse();
const reorderedDocument = buildDocument(reordered);
const sameIds = document.declarations.every((declaration) => {
    const other = reorderedDocument.declarations.find((candidate) => candidate.name === declaration.name);
    return other && other.id === declaration.id &&
        canonicalJson(other.binders) === canonicalJson(declaration.binders) &&
        canonicalJson(other.applications.map((application) => application.id)) ===
            canonicalJson(declaration.applications.map((application) => application.id));
});
if (sameIds) {
    pass("declaration order does not change any TypeId, TypeParameterId or ConstructedTypeId");
} else {
    fail("discovery order", "reordering declarations moved an identity");
}

/* A tampered document is refused, not accepted as another value. */
function tampered(label, mutate) {
    const copy = parseDocument(goldenText);
    mutate(copy);
    expectRefuse("internal", label, () => validateDocument(copy, positive.logical_path, contextIds));
}
tampered("a tampered binder id is refused", (doc) => { doc.declarations[0].binders[0].id = "00".repeat(32); });
tampered("a tampered constructed id is refused", (doc) => { doc.declarations[0].applications[0].id = "00".repeat(32); });
tampered("a tampered substitution is refused", (doc) => {
    doc.declarations[0].applications[0].constructors[1].payload[0].type = { id: primitiveTypeId("Text"), tag: "primitive" };
});
tampered("a kind-blind ADT TypeId is refused", (doc) => {
    doc.declarations[0].id = declarationTypeId(positive.logical_path, "Opt", "record");
});
tampered("a shuffled constructor ordinal is refused", (doc) => { doc.declarations[0].constructors[1].ordinal = 5; });
tampered("a record carrying constructors is refused", (doc) => {
    const recordDeclaration = doc.declarations.find((declaration) => declaration.kind === "record");
    recordDeclaration.constructors = [];
});
pass("tampered binder, constructed, substituted, kind-blind and ordinal documents are refused");

/* ---------------------------------------------------- oracle: cases built */

const P = (name) => ({ primitive: name });
const param = (name) => ({ parameter: name });
const nom = (name, ...args) => ({ nominal: name, arguments: args });
const LOGICAL = "examples/generic_adt.kofun";
const rec = (name, binders, fields, applications = []) => ({
    name,
    kind: "record",
    binders,
    fields: fields.map(([fieldName, type]) => ({ name: fieldName, type })),
    applications: applications.map((arguments_) => ({ arguments: arguments_ })),
});
const adt = (name, binders, constructors, applications = []) => ({
    name,
    kind: "adt",
    binders,
    constructors: constructors.map(([constructorName, payload]) => ({
        name: constructorName,
        payload: payload === undefined ? [] : [{ name: "v", type: payload }],
    })),
    applications: applications.map((arguments_) => ({ arguments: arguments_ })),
});
const doc = (...declarations) => ({ logical_path: LOGICAL, declarations });
const optDeclaration = () => adt("Opt", ["T"], [["None"], ["Some", param("T")]]);

/* Binders. */
expectRefuse(CODES.tooManyParameters, "three type parameters are refused", () =>
    buildDocument(doc(adt("X", ["A", "B", "C"], [["E"], ["F", param("A")]]))));
expectRefuse(CODES.duplicateParameter, "a duplicate type parameter is refused", () =>
    buildDocument(doc(adt("X", ["T", "T"], [["E"], ["F", param("T")]]))));
expectRefuse(CODES.unsupportedBinder, "a const binder on an ADT is refused", () =>
    buildDocument(doc({ ...adt("X", ["T"], [["E"], ["F", param("T")]]), constBinders: 1 })));
expectRefuse(CODES.unsupportedBinder, "a const binder beside a type binder on a record is refused", () =>
    buildDocument(doc({ ...rec("X", ["T"], [["v", param("T")]]), constBinders: 1 })));
check(
    buildDocument(doc({ ...rec("X", [], [["v", P("Int")]]), constBinders: 1 })).declarations.length === 0,
    "const-only record",
    "a record whose parameter list is exactly one const parameter was listed",
);
pass("binder bounds, duplicates and kinds refuse, and a const-only record is context");

/* Members. */
expectRefuse(CODES.unboundParameter, "an unbound payload parameter is refused", () =>
    buildDocument(doc(adt("X", ["T"], [["E"], ["F", param("Q")]]))));
expectRefuse(CODES.unboundParameter, "a bare unknown name is an unbound parameter", () =>
    buildDocument(doc(adt("X", ["T"], [["E"], ["F", nom("Zed")]]))));
expectRefuse(CODES.unknownNominal, "an applied unknown nominal is refused", () =>
    buildDocument(doc(adt("X", ["T"], [["E"], ["F", nom("Nope", param("T"))]]))));
expectRefuse(CODES.arityMismatch, "too many arguments to an ADT are refused", () =>
    buildDocument(doc(optDeclaration(), adt("X", ["T"], [["E"], ["F", nom("Opt", param("T"), param("T"))]]))));
expectRefuse(CODES.arityMismatch, "a generic ADT named with no arguments is refused", () =>
    buildDocument(doc(optDeclaration(), adt("X", ["T"], [["E"], ["F", nom("Opt")]]))));
expectRefuse(CODES.arityMismatch, "an application with the wrong arity is refused", () =>
    buildDocument(doc({ ...optDeclaration(), applications: [{ arguments: [P("Int"), P("Int")] }] })));
expectRefuse(CODES.unsupportedPayload, "a function payload is refused", () =>
    buildDocument(doc(adt("X", ["T"], [["E"], ["F", { function: [] }]]))));
expectRefuse(CODES.duplicateType, "a record and an ADT of one name are refused", () =>
    buildDocument(doc(optDeclaration(), rec("Opt", ["U"], [["v", param("U")]]))));
expectRefuse(CODES.constructorShape, "a duplicate constructor is refused", () =>
    buildDocument(doc(adt("X", ["T"], [["Same"], ["Same", param("T")]]))));
expectRefuse(CODES.constructorShape, "a one-constructor ADT is refused", () =>
    buildDocument(doc(adt("X", ["T"], [["Only", param("T")]]))));
expectRefuse(CODES.constructorShape, "a two-field payload is refused", () =>
    buildDocument(doc({
        ...adt("X", ["T"], [["E"], ["F", param("T")]]),
        constructors: [
            { name: "E", payload: [] },
            { name: "F", payload: [{ name: "a", type: param("T") }, { name: "b", type: param("T") }] },
        ],
    })));
pass("unbound, unknown, arity, form, duplicate and constructor-shape refusals fire");

/* Limits: the boundary accepted and one past it refused. */
const eight = [
    [P("Int")], [P("Bool")], [P("Text")], [P("Unit")],
    [nom("Opt", P("Int"))], [nom("Opt", P("Bool"))], [nom("Opt", P("Text"))], [nom("Opt", P("Unit"))],
];
buildDocument(doc({ ...optDeclaration(), applications: eight.map((arguments_) => ({ arguments: arguments_ })) }));
buildDocument(doc({
    ...optDeclaration(),
    applications: [...eight, eight[0]].map((arguments_) => ({ arguments: arguments_ })),
}));
pass("eight distinct concrete instantiations are accepted, and a repeated tuple is counted once");
expectRefuse(CODES.instantiationLimit, "a ninth distinct instantiation is refused", () =>
    buildDocument(doc({
        ...optDeclaration(),
        applications: [...eight, [nom("Opt", nom("Opt", P("Int")))]].map((arguments_) => ({ arguments: arguments_ })),
    })));

function nested(levels, leaf) {
    let node = leaf;
    for (let index = 0; index < levels; index += 1) node = nom("Opt", node);
    return node;
}
buildDocument(doc(optDeclaration(), adt("D", ["T"], [["E"], ["F", nested(8, P("Int"))]])));
expectRefuse(CODES.depthExceeded, "a member at depth nine is refused", () =>
    buildDocument(doc(optDeclaration(), adt("D", ["T"], [["E"], ["F", nested(9, P("Int"))]]))));
buildDocument(doc({ ...optDeclaration(), applications: [{ arguments: [nested(8, P("Int"))] }] }));
expectRefuse(CODES.depthExceeded, "an application argument at depth nine is refused", () =>
    buildDocument(doc({ ...optDeclaration(), applications: [{ arguments: [nested(9, P("Int"))] }] })));
pass("the depth limit is accepted at eight and refused at nine, in members and in applications");

const records = (count) => Array.from({ length: count }, (_, index) => rec(`R${index}`, ["T"], [["v", param("T")]]));
buildDocument(doc(...records(64)));
expectRefuse(CODES.sizeLimit, "a 65th declaration is refused", () => buildDocument(doc(...records(65))));
const constructors = (count) => Array.from({ length: count }, (_, index) => [`C${index}`, index === 0 ? param("T") : undefined]);
buildDocument(doc(adt("Many", ["T"], constructors(64))));
expectRefuse(CODES.sizeLimit, "a 65th constructor is refused", () =>
    buildDocument(doc(adt("Many", ["T"], constructors(65)))));
const fields = (count) => Array.from({ length: count }, (_, index) => [`f${index}`, param("T")]);
buildDocument(doc(rec("Wide", ["T"], fields(256))));
expectRefuse(CODES.sizeLimit, "a 257th field is refused", () => buildDocument(doc(rec("Wide", ["T"], fields(257)))));
buildDocument(doc(rec("N".repeat(65535), ["T"], [["v", param("T")]])));
expectRefuse(CODES.sizeLimit, "a 65536-byte declaration name is refused", () =>
    buildDocument(doc(rec("N".repeat(65536), ["T"], [["v", param("T")]]))));
expectRefuse(CODES.sizeLimit, "a 65536-byte constructor name is refused", () =>
    buildDocument(doc(adt("X", ["T"], [["k".repeat(65536)], ["Other", param("T")]]))));
expectRefuse(CODES.sizeLimit, "a 65536-byte field name is refused", () =>
    buildDocument(doc(rec("X", ["T"], [["f".repeat(65536), param("T")]]))));
pass("the declaration, constructor, field and name bounds are accepted at the limit and refused one past it");

/* A document over its byte bound: the substituted payloads are what grow. */
function sizeCase(adts) {
    const declarations = [{ ...optDeclaration(), applications: [[P("Int")], [P("Bool")], [P("Text")], [P("Unit")]].map((arguments_) => ({ arguments: arguments_ })) }];
    const arguments_ = [P("Int"), P("Bool"), P("Text"), P("Unit"), nom("Opt", P("Int")), nom("Opt", P("Bool")),
        nom("Opt", P("Text")), nom("Opt", P("Unit"))];
    for (let index = 0; index < adts; index += 1) {
        declarations.push(adt(`G${index}`, ["T"],
            Array.from({ length: 16 }, (_, ctor) => [`C${index}_${ctor}`, nested(7, param("T"))]),
            arguments_.map((argument) => [argument])));
    }
    return doc(...declarations);
}
const underSize = serializeDocument(buildDocument(sizeCase(7)));
check(Buffer.byteLength(underSize) <= LIMITS.document_bytes && Buffer.byteLength(underSize) > 900000,
    "document bound", "the 7-declaration case is not just under the bound");
expectRefuse(CODES.sizeLimit, "a document over 1048576 bytes is refused", () => buildDocument(sizeCase(8)));
pass("a document just under 1048576 bytes is accepted and one over it is refused");

/* Cycles: every class, and the shapes beside them that must be accepted. */
const recA = (name, target) => rec(name, ["T"], [["next", nom(target, param("T"))]]);
const adtA = (name, target) => adt(name, ["T"], [["Stop"], ["Step", nom(target, param("T"))]]);
expectRefuse(CODES.adtDirectCycle, "a direct ADT cycle is refused", () => buildDocument(doc(adtA("L", "L"))));
expectRefuse(CODES.recordDirectCycle, "a direct record cycle keeps the record code", () =>
    buildDocument(doc(recA("N", "N"))));
expectRefuse(CODES.adtMutualCycle, "a mutual ADT-to-ADT cycle is refused", () =>
    buildDocument(doc(adtA("A", "B"), adtA("B", "A"))));
expectRefuse(CODES.recordMutualCycle, "a mutual record cycle keeps the record code", () =>
    buildDocument(doc(recA("A", "B"), recA("B", "A"))));
expectRefuse(CODES.mixedCycle, "a mixed record/ADT cycle is refused", () =>
    buildDocument(doc(recA("R", "A"), adtA("A", "R"))));
expectRefuse(CODES.mixedCycle, "a mixed cycle is refused whichever declaration comes first", () =>
    buildDocument(doc(adtA("A", "R"), recA("R", "A"))));
expectRefuse(CODES.mixedCycle, "a three-member mixed cycle is refused", () =>
    buildDocument(doc(recA("R", "A"), adtA("A", "B"), adtA("B", "R"))));
expectRefuse(CODES.adtMutualCycle, "a three-member ADT cycle is refused", () =>
    buildDocument(doc(adtA("A", "B"), adtA("B", "C"), adtA("C", "A"))));
expectRefuse(CODES.adtDirectCycle, "an ADT holding itself through a record argument is refused", () =>
    buildDocument(doc(rec("Box", ["T"], [["v", param("T")]]),
        adt("L", ["T"], [["Stop"], ["Step", nom("Box", nom("L", param("T")))]]))));
expectRefuse(CODES.recordDirectCycle, "a plain record holding an instantiation over itself is refused", () =>
    buildDocument(doc(optDeclaration(), rec("Node", [], [["next", nom("Opt", nom("Node"))]]))));
expectRefuse(CODES.mixedCycle, "a cycle through a non-generic ADT and a generic record is refused", () =>
    buildDocument(doc(
        rec("R", ["T"], [["c", nom("Color")]]),
        adt("Color", [], [["Red"], ["Wrapped", nom("R", P("Int"))]]),
    )));
buildDocument(doc(
    rec("Top", ["T"], [["left", nom("Mid1", param("T"))], ["right", nom("Mid2", param("T"))]]),
    adtA("Mid1", "Leaf"),
    adtA("Mid2", "Leaf"),
    rec("Leaf", ["T"], [["v", param("T")]]),
));
buildDocument(doc(adt("A", ["T"], [["Stop"], ["Step", nom("B", param("T"))]]), rec("B", ["T"], [["v", param("T")]])));
pass("every cycle class refuses with its code, and a diamond and a record-under-ADT graph are accepted");

/* ---------------------------------------------------- the compiler halves */

let printed = "";
const kofun = loadCompiler({
    print: (value) => { printed += text(value) + "\n"; },
    validate() { return ""; },
});

const ENTRY = {
    adt: { flag: "--emit-generic-adt-hir", kofun: "emit_generic_adt_hir_file" },
    record: { flag: "--emit-generic-record-hir", kofun: "emit_generic_record_hir_file" },
};
let counter = 0;

function runKofun(entry, input, logicalPath) {
    const out = `${WORK}/k-${counter += 1}.json`;
    fs.rmSync(out, { force: true });
    printed = "";
    const ok = kofun[ENTRY[entry].kofun](bytes(input), bytes(out), bytes(logicalPath));
    const artifact = fs.existsSync(out) ? fs.readFileSync(out, "latin1") : null;
    fs.rmSync(out, { force: true });
    return { artifact, ok: Boolean(ok), printed };
}

function runC(entry, input, logicalPath, binary = stage2) {
    const out = `${WORK}/c-${counter += 1}.json`;
    fs.rmSync(out, { force: true });
    const result = spawnSync(binary, [ENTRY[entry].flag, input, out, logicalPath], { encoding: "latin1" });
    const artifact = fs.existsSync(out) ? fs.readFileSync(out, "latin1") : null;
    fs.rmSync(out, { force: true });
    return { artifact, status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

/* One source through both halves: the same outcome, byte for byte. */
function both(entry, input, logicalPath = positive.logical_path) {
    const c = runC(entry, input, logicalPath);
    const k = runKofun(entry, input, logicalPath);
    const agree = c.stderr === "" && c.stdout === k.printed && c.artifact === k.artifact &&
        c.status === (k.ok ? 0 : 1);
    return { agree, c, k };
}

function codeOf(printedText) {
    return /^error\[(E2S\d+)\]/.exec(printedText)?.[1] ?? null;
}

const compiledPositive = both("adt", `${FIX}positive.kofun`);
if (!compiledPositive.agree || compiledPositive.k.artifact !== goldenText) {
    fail("compiler positive", `the halves do not both reproduce the golden (${compiledPositive.k.printed.trim()} / ${compiledPositive.c.stdout.trim()})`);
} else {
    pass("both halves reproduce the positive golden byte for byte, including multi-argument types nested in arguments");
}

const negatives = [
    ["adt_direct_cycle", "E2S210"],
    ["adt_mutual_cycle", "E2S211"],
    ["mixed_cycle", "E2S212"],
    ["record_direct_cycle", "E2S199"],
    ["record_mutual_cycle", "E2S200"],
    ["holder_cycle", "E2S199"],
    ["arity_mismatch", "E2S206"],
    ["unbound_parameter", "E2S205"],
    ["unknown_nominal", "E2S207"],
    ["too_many_parameters", "E2S203"],
    ["duplicate_parameter", "E2S204"],
    ["unsupported_binder", "E2S214"],
    ["unsupported_payload", "E2S213"],
    ["duplicate_type", "E2S215"],
    ["duplicate_constructor", "E2S216"],
    ["payload_fields", "E2S216"],
    ["one_constructor", "E2S216"],
    ["instantiation_limit", "E2S208"],
    ["depth_exceeded", "E2S209"],
    ["constructor_limit", "E2S217"],
];
let refused = 0;
for (const [fixture, code] of negatives) {
    const golden = fs.readFileSync(`${FIX}${fixture}.stderr`, "utf8");
    const result = both("adt", `${FIX}${fixture}.kofun`);
    if (!result.agree) {
        fail(`pair ${fixture}`, `the halves disagree: C(${result.c.status}) ${result.c.stdout.trim()} | Kofun(${result.k.ok ? 0 : 1}) ${result.k.printed.trim()}`);
    } else if (result.k.ok || result.c.status !== 1) {
        fail(`compiler ${fixture}`, "accepted a source the contract refuses");
    } else if (codeOf(result.k.printed) !== code) {
        fail(`compiler ${fixture}`, `expected ${code}, got: ${result.k.printed.trim()}`);
    } else if (result.k.artifact !== null || result.c.artifact !== null) {
        fail(`compiler ${fixture}`, "wrote an artifact on refusal");
    } else if (result.k.printed !== golden) {
        fail(`compiler ${fixture}`, `diagnostic differs from the golden: ${result.k.printed.trim()}`);
    } else {
        refused += 1;
    }
}
if (refused === negatives.length) {
    pass(`both halves refuse all ${negatives.length} negative fixtures with their codes, the golden text and no artifact, and agree byte for byte`);
}

/* The pre-existing artifact survives a refusal: transactional publication. */
{
    const destination = `${WORK}/preexisting.json`;
    fs.writeFileSync(destination, "sentinel\n");
    const result = spawnSync(stage2, [ENTRY.adt.flag, `${FIX}mixed_cycle.kofun`, destination, positive.logical_path], { encoding: "latin1" });
    check(result.status === 1 && fs.readFileSync(destination, "utf8") === "sentinel\n",
        "transactional publication", "a refused run changed a pre-existing destination");
    const same = spawnSync(stage2, [ENTRY.adt.flag, `${FIX}positive.kofun`, `${FIX}positive.kofun`, positive.logical_path], { encoding: "latin1" });
    check(same.status === 1 && /E2S217/.test(same.stdout), "distinct files", "an input used as its own output was accepted");
    const badPath = spawnSync(stage2, [ENTRY.adt.flag, `${FIX}positive.kofun`, `${WORK}/unused.json`, "../escape.kofun"], { encoding: "latin1" });
    check(badPath.status === 1 && /E2S217/.test(badPath.stdout) && !fs.existsSync(`${WORK}/unused.json`),
        "logical path", "a non-canonical logical path was accepted");
    pass("a refusal leaves a pre-existing destination byte-identical; input and output must be distinct; the logical path is validated");
}

/* The record entry and the ADT entry agree on a record-only file. */
{
    const subsetLogical = "examples/generic_record.kofun";
    const pairArguments = [P("Int"), P("Bool")];
    const subsetRecords = (withKind) => {
        const tag = withKind ? { kind: "record" } : {};
        const make = (name, binders, fields, applications) => ({
            name, ...tag, binders,
            fields: fields.map(([fieldName, type]) => ({ name: fieldName, type })),
            applications: applications.map((arguments_) => ({ arguments: arguments_ })),
        });
        return {
            logical_path: subsetLogical,
            declarations: [
                make("Box", ["T"], [["value", param("T")]], [
                    [nom("Pair", ...pairArguments)],
                    [P("Int")],
                ]),
                make("Pair", ["T", "U"], [["left", param("T")], ["right", param("U")]], [
                    pairArguments,
                    [nom("Box", P("Int")), nom("Pair", P("Bool"), P("Text"))],
                    [P("Bool"), P("Text")],
                ]),
                make("Wrap", ["T"], [["inner", nom("Box", nom("Pair", param("T"), P("Int")))]], [[P("Text")]]),
            ],
        };
    };
    const recordExpected = recordModel.buildDocument(subsetRecords(false)).declarations;
    const adtExpected = buildDocument(subsetRecords(true)).declarations;
    check(canonicalJson(recordExpected) === canonicalJson(adtExpected), "oracle subset",
        "the two oracles disagree on a record-only case");

    const subsetFiles = [
        [`${FIX}record_subset.kofun`, recordExpected],
        [`${RECORD_FIX}positive.kofun`, readJson(`${RECORD_FIX}positive.golden.json`).declarations],
    ];
    let subsets = 0;
    for (const [file, expected] of subsetFiles) {
        const logical = file.endsWith("record_subset.kofun") ? subsetLogical : readJson(`${RECORD_FIX}positive.case.json`).logical_path;
        const results = [
            ["record/C", runC("record", file, logical)],
            ["record/Kofun", runKofun("record", file, logical)],
            ["adt/C", runC("adt", file, logical)],
            ["adt/Kofun", runKofun("adt", file, logical)],
        ];
        const declarations = results.map(([label, result]) => [label, result.artifact === null ? null : parseDocument(result.artifact).declarations]);
        const mismatch = declarations.find(([, value]) => value === null || canonicalJson(value) !== canonicalJson(expected));
        if (mismatch) {
            fail(`record subset ${file.split("/").pop()}`, `${mismatch[0]} does not equal the record contract's declarations`);
        } else {
            subsets += 1;
        }
    }
    if (subsets === subsetFiles.length) {
        pass("a record-only file yields the record contract's declarations through the record and ADT entries, in both halves");
    }
}

/* Ordinary compilation keeps refusing generic sources. */
{
    const sources = [
        `${FIX}positive.kofun`,
        `${RECORD_FIX}positive.kofun`,
        `${ROOT}tests/conformance/adt/generic_unsupported.kofun`,
    ];
    let ordinary = 0;
    for (const source of sources) {
        const base = `${WORK}/ordinary-${counter += 1}`;
        const outputs = [`${base}.c`, `${base}.ir`, `${base}.tokens`];
        const c = spawnSync(stage2, ["--compile-outcome", source, ...outputs], { encoding: "latin1" });
        const cLeft = outputs.filter((output) => fs.existsSync(output));
        printed = "";
        const status = kofun.compile_file(bytes(source), bytes(outputs[0]), bytes(outputs[1]), bytes(outputs[2]));
        const kLeft = outputs.filter((output) => fs.existsSync(output));
        outputs.forEach((output) => fs.rmSync(output, { force: true }));
        if (c.status !== 1 || !c.stdout.startsWith("error[E2S148]")) {
            fail("ordinary C", `${source.split("/").pop()}: expected E2S148 exit 1, got ${c.status} ${c.stdout.trim()}`);
        } else if (Number(status) !== 1 || !printed.startsWith("error[E2S148]")) {
            fail("ordinary Kofun", `${source.split("/").pop()}: expected E2S148 exit 1, got ${status} ${printed.trim()}`);
        } else if (cLeft.length > 0 || kLeft.length > 0) {
            fail("ordinary artifacts", `${source.split("/").pop()}: a refused compilation left ${[...cLeft, ...kLeft].join(", ")}`);
        } else if (c.stdout !== printed) {
            fail("ordinary agreement", `${source.split("/").pop()}: the halves disagree on the refusal`);
        } else {
            ordinary += 1;
        }
    }
    if (ordinary === sources.length) {
        pass("ordinary compilation and --compile-outcome still refuse generic sources with E2S148, exit 1 and no artifact, in both halves");
    }
}

/* A lexical error is reported as such by both entries in both halves. */
{
    const file = `${WORK}/unterminated.kofun`;
    fs.writeFileSync(file, 'type "Opt\n    | None\n    | Some(value: Int)\n');
    let lexed = 0;
    for (const entry of ["adt", "record"]) {
        const c = runC(entry, file, positive.logical_path);
        const k = runKofun(entry, file, positive.logical_path);
        if (c.stderr === "" && c.status === 1 && /^error\[E2S01\]/.test(c.stdout) && c.stdout === k.printed &&
            !k.ok && c.artifact === null && k.artifact === null) {
            lexed += 1;
        } else {
            fail(`lex first (${entry})`, `C ${c.status} ${c.stdout.trim()} ${c.stderr.trim()} | Kofun ${k.printed.trim()}`);
        }
    }
    if (lexed === 2) pass("an unterminated string is a lexical error in both entries and both halves, not an out-of-bounds read");
}

/* Generated boundaries, through both halves. */
function generated(label, source, expected) {
    const file = `${WORK}/gen-${counter += 1}.kofun`;
    fs.writeFileSync(file, source);
    const result = both("adt", file);
    if (!result.agree) {
        fail(`boundary ${label}`, `the halves disagree: C ${result.c.stdout.trim().slice(0, 120)} | Kofun ${result.k.printed.trim().slice(0, 120)}`);
        return;
    }
    if (expected === "document") {
        if (!result.k.ok || result.k.artifact === null) {
            fail(`boundary ${label}`, `refused: ${result.k.printed.trim().slice(0, 160)}`);
            return;
        }
        const parsed = parseDocument(result.k.artifact);
        const errors = schemaErrors(schema, parsed);
        if (errors.length > 0) fail(`boundary ${label}`, `schema: ${errors.slice(0, 2).join("; ")}`);
        return;
    }
    if (result.k.ok || codeOf(result.k.printed) !== expected) {
        fail(`boundary ${label}`, `expected ${expected}, got ${result.k.ok ? "a document" : result.k.printed.trim().slice(0, 160)}`);
    }
}
const generatedRecords = (count) =>
    Array.from({ length: count }, (_, index) => `type R${index}[T] = {\n    v: T,\n}\n`).join("\n");
generated("64 declarations", generatedRecords(64), "document");
generated("65 declarations", generatedRecords(65), "E2S217");
const generatedConstructors = (count) =>
    `type Many[T] =\n    | C0(value: T)\n${Array.from({ length: count - 1 }, (_, index) => `    | C${index + 1}\n`).join("")}`;
generated("64 constructors", generatedConstructors(64), "document");
generated("65 constructors", generatedConstructors(65), "E2S217");
const generatedFields = (count) =>
    `type Wide[T] = {\n${Array.from({ length: count }, (_, index) => `    f${index}: T,\n`).join("")}}\n`;
generated("256 fields", generatedFields(256), "document");
generated("257 fields", generatedFields(257), "E2S217");
generated("65535-byte declaration name", `type ${"N".repeat(65535)}[T] = {\n    v: T,\n}\n`, "document");
generated("65536-byte declaration name", `type ${"N".repeat(65536)}[T] = {\n    v: T,\n}\n`, "E2S217");
generated("65535-byte constructor name", `type X[T] =\n    | ${"k".repeat(65535)}\n    | Other(v: T)\n`, "document");
generated("65536-byte constructor name", `type X[T] =\n    | ${"k".repeat(65536)}\n    | Other(v: T)\n`, "E2S217");
generated("65535-byte field name", `type X[T] = {\n    ${"f".repeat(65535)}: T,\n}\n`, "document");
generated("65536-byte field name", `type X[T] = {\n    ${"f".repeat(65536)}: T,\n}\n`, "E2S217");
const OPT = "type Opt[T] =\n    | None\n    | Some(value: T)\n";
const optNest = (levels, leaf) => `${"Opt[".repeat(levels)}${leaf}${"]".repeat(levels)}`;
generated("depth 8", `${OPT}\ntype Deep[T] =\n    | Shallow\n    | Buried(value: ${optNest(8, "Int")})\n`, "document");
generated("depth 9", `${OPT}\ntype Deep[T] =\n    | Shallow\n    | Buried(value: ${optNest(9, "Int")})\n`, "E2S209");
const eightArguments = ["Int", "Bool", "Text", "Unit", "Opt[Int]", "Opt[Bool]", "Opt[Text]", "Opt[Unit]"];
const useAll = (arguments_) => `fn consume(\n${arguments_.map((argument, index) => `    p${index}: Opt[${argument}],\n`).join("")}) -> Int {\n    return 0\n}\n`;
generated("8 instantiations", `${OPT}\n${useAll(eightArguments)}`, "document");
generated("8 instantiations with a repeat", `${OPT}\n${useAll([...eightArguments, "Int"])}`, "document");
generated("9 instantiations", `${OPT}\n${useAll([...eightArguments, "Opt[Opt[Int]]"])}`, "E2S208");

/* A diamond ladder has 2^21 paths: it is linear only because finished
 * declarations are not walked again. */
{
    const parts = [];
    for (let level = 0; level < 21; level += 1) {
        const next = level + 1 < 21 ? `D${level + 1}` : "Int";
        parts.push(`type D${level} = {\n    a: B${level},\n    b: C${level},\n}\n`);
        parts.push(`type B${level} = {\n    n: ${next},\n}\n`);
        parts.push(`type C${level} = {\n    n: ${next},\n}\n`);
    }
    parts.push("type Opt[T] =\n    | None\n    | Some(value: T)\n");
    generated("diamond ladder of 64 declarations", parts.join("\n"), "document");
}
{
    const parts = [];
    for (let index = 0; index < 64; index += 1) {
        parts.push(`type C${index} =\n    | Stop${index}\n    | Next${index}(n: C${(index + 1) % 64})\n`);
    }
    generated("a 64-member ADT cycle", parts.join("\n"), "E2S211");
}

/* The document bound, through both halves: 953 KB accepted, 1.09 MB refused. */
function sizeSource(adts) {
    const arguments_ = ["Int", "Bool", "Text", "Unit", "Opt[Int]", "Opt[Bool]", "Opt[Text]", "Opt[Unit]"];
    const parts = [OPT];
    for (let index = 0; index < adts; index += 1) {
        const lines = [`type G${index}[T] =`];
        for (let ctor = 0; ctor < 16; ctor += 1) lines.push(`    | C${index}_${ctor}(v: ${optNest(7, "T")})`);
        parts.push(`${lines.join("\n")}\n`);
    }
    const params = [];
    for (let index = 0; index < adts; index += 1) {
        arguments_.forEach((argument, slot) => params.push(`    p${index}_${slot}: G${index}[${argument}],\n`));
    }
    parts.push(`fn consume(\n${params.join("")}) -> Int {\n    return 0\n}\n`);
    return parts.join("\n");
}
generated("a document just under the byte bound", sizeSource(7), "document");
generated("a document over the byte bound", sizeSource(8), "E2S217");
pass("every limit is accepted at its boundary and refused one past it, in both halves, with the halves agreeing");
pass("a diamond ladder of 64 declarations and a 64-member cycle classify without enumerating paths");

/* Determinism. */
const repeatC = runC("adt", `${FIX}positive.kofun`, positive.logical_path);
const repeatK = runKofun("adt", `${FIX}positive.kofun`, positive.logical_path);
if (repeatC.artifact !== goldenText || repeatK.artifact !== goldenText) {
    fail("repeat", "a second run differs from the golden");
} else {
    pass("a repeated run is byte-identical in both halves");
}

const remapPhysical = `${WORK}/remap-positive.kofun`;
fs.copyFileSync(`${FIX}positive.kofun`, remapPhysical);
const remappedC = runC("adt", remapPhysical, positive.logical_path);
const remappedK = runKofun("adt", remapPhysical, positive.logical_path);
if (remappedC.artifact !== goldenText || remappedK.artifact !== goldenText) {
    fail("remap", "a physical-path remap changed the document");
} else {
    pass("a physical-path remap under the same logical path is byte-identical in both halves");
}

if (stage2O0 && fs.existsSync(stage2O0)) {
    const o0 = runC("adt", `${FIX}positive.kofun`, positive.logical_path, stage2O0);
    const o0Refusal = runC("adt", `${FIX}mixed_cycle.kofun`, positive.logical_path, stage2O0);
    if (o0.status !== 0 || o0.artifact !== goldenText) {
        fail("c -O0", "the -O0 build differs from the -O2 golden");
    } else if (o0Refusal.stdout !== fs.readFileSync(`${FIX}mixed_cycle.stderr`, "utf8")) {
        fail("c -O0", "the -O0 build refuses differently");
    } else {
        pass("the -O0 and -O2 builds emit byte-identical documents and diagnostics");
    }
} else {
    fail("c -O0", "KOFUN_GENERIC_ADT_STAGE2_O0 is not a built binary");
}

/* Reordering the declarations of the file keeps every declaration's entry. */
{
    const original = fs.readFileSync(`${FIX}positive.kofun`, "utf8");
    const split = original.indexOf("fn consume(");
    const blocks = original.slice(0, split).trim().split(/\n\n+/);
    const reorderedSource = `${[...blocks].reverse().join("\n\n")}\n\n${original.slice(split)}`;
    const file = `${WORK}/reordered.kofun`;
    fs.writeFileSync(file, reorderedSource);
    const reorderedRuns = [runC("adt", file, positive.logical_path), runKofun("adt", file, positive.logical_path)];
    const expected = new Map(parseDocument(goldenText).declarations.map((declaration) => [declaration.name, canonicalJson(declaration)]));
    const intact = reorderedRuns.every((run) => {
        if (run.artifact === null) return false;
        const declarations = parseDocument(run.artifact).declarations;
        return declarations.length === expected.size &&
            declarations.every((declaration) => expected.get(declaration.name) === canonicalJson(declaration));
    });
    if (intact) {
        pass("reordering the declarations of the file keeps every declaration's entry, in both halves");
    } else {
        fail("declaration order", "a reordered file changed a declaration's entry");
    }
}

/* ------------------------------------------------------------------ output */

for (const line of PASS) process.stdout.write(`${line}\n`);
if (failures > 0) {
    process.stderr.write(`FAIL: generic-ADT HIR contract: ${failures} check(s) failed\n`);
    process.exit(1);
}
process.stdout.write("PASS: generic-ADT HIR v1 identities, cycle classes, refusals, and limits are frozen\n");

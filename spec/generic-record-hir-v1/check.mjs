#!/usr/bin/env node
/*
 * Gate for the generic-record HIR v1 contract (#1674).
 *
 * This proves the CONTRACT and its independent oracle, producer-independent:
 * every TypeParameterId and ConstructedTypeId is recomputed from its preimage
 * with the #303 frame, the canonical document matches its frozen golden, the
 * substituted fields agree with the arguments, and every limit and refusal
 * fires. The compiler entry that must reproduce these bytes is the next slice;
 * its agreement assertions are added here beside these.
 */

import fs from "node:fs";
import { fileURLToPath } from "node:url";

import {
    CODES,
    GenericRecordError,
    LIMITS,
    buildDocument,
    canonicalJson,
    constructedTypeId,
    primitiveTypeId,
    recordCycle,
    serializeDocument,
    typeParameterId,
    validateDocument,
} from "./model.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const PASS = [];
let failures = 0;

function pass(line) {
    PASS.push(`PASS: ${line}`);
}

function fail(label, detail) {
    failures += 1;
    process.stderr.write(`FAIL: ${label}${detail ? `: ${detail}` : ""}\n`);
}

function readJson(path) {
    return JSON.parse(fs.readFileSync(path, "utf8"));
}

function expectRefuse(code, label, thunk) {
    try {
        thunk();
    } catch (error) {
        if (error instanceof GenericRecordError && error.code === code) {
            return;
        }
        fail(label, `expected ${code}, got ${error.code ?? error.name}: ${error.message}`);
        return;
    }
    fail(label, `expected ${code}, but the case was accepted`);
}

function clone(value) {
    return JSON.parse(JSON.stringify(value));
}

const positive = readJson(`${HERE}fixtures/positive.case.json`);

/* -------------------------------------------------- golden and validation */

const document = buildDocument(positive);
const goldenText = serializeDocument(document);
const goldenPath = `${HERE}fixtures/positive.golden.json`;
if (fs.existsSync(goldenPath)) {
    const committed = fs.readFileSync(goldenPath, "utf8");
    if (committed !== goldenText) {
        fail("positive golden", "the oracle no longer reproduces the committed document");
    } else {
        pass("the canonical positive document matches its frozen golden byte for byte");
    }
} else {
    fail("positive golden", `missing ${goldenPath}`);
}

validateDocument(JSON.parse(goldenText), positive.logical_path);
pass(`every derived identity recomputes from its preimage and the limits hold`);
if (Buffer.byteLength(goldenText) > LIMITS.document_bytes) {
    fail("document bytes", "over the limit");
}

/* ------------------------------------------------------------- identities */

const box = document.declarations.find((declaration) => declaration.name === "Box");
const first = document.declarations.find((declaration) => declaration.name === "First");
const second = document.declarations.find((declaration) => declaration.name === "Second");
const pair = document.declarations.find((declaration) => declaration.name === "Pair");

/* Declaration-scoped shadowing: three declarations each name a binder `T`, and
 * the identifiers differ because the preimage owner differs. */
const tIds = new Set([
    box.binders[0].id,
    first.binders[0].id,
    pair.binders[0].id,
]);
if (tIds.size !== 3) {
    fail("declaration-scoped shadowing", "three owners named `T` did not mint three ids");
} else {
    pass("a binder spelled `T` in three declarations mints three distinct ids");
}

/* Forward use: `First`'s field names `Second`, declared later. */
if (first.fields[0].type.id !== second.id) {
    fail("forward use", "First.inner did not resolve to Second");
} else {
    pass("a field may name a declaration collected later (forward use)");
}

/* Substitution through a nominal argument. */
const firstInt = first.applications[0];
if (firstInt.fields[0].type.tag !== "nominal" ||
    firstInt.fields[0].type.arguments[0].tag !== "primitive") {
    fail("substitution", "First[Int].inner is not Second[Int]");
} else {
    pass("First[Int] substitutes its argument through the nested nominal field");
}

/* Nested application in a field. */
const boxBox = box.applications[2];
if (boxBox.fields[0].type.tag !== "nominal" || boxBox.fields[0].type.id !== box.id) {
    fail("nested application", "Box[Box[Int]].value is not Box[Int]");
} else {
    pass("Box[Box[Int]] substitutes to a nested nominal Box[Int]");
}

/* ------------------------------------------------------------- mutations */

/* A name-based spelling is not an identity input: renaming the binder in the
 * case (and in the field that uses it) leaves every derived id unchanged. */
const renamed = clone(positive);
renamed.declarations[2].binders = ["Q"];
renamed.declarations[2].fields[0].type.parameter = "Q";
if (canonicalJson(buildDocument(renamed)) !== canonicalJson(document)) {
    fail("spelling independence", "renaming a binder changed a derived identity");
} else {
    pass("renaming a binder does not change any derived identity");
}

/* A preimage mutation moves the identity: renaming the declaration changes the
 * derived TypeId, and both TypeParameterId and ConstructedTypeId follow it. */
const movedOwner = clone(positive);
const boxDeclaration = movedOwner.declarations[2];
boxDeclaration.name = "Crate";
boxDeclaration.applications[2].arguments[0].nominal = "Crate";
const moved = buildDocument(movedOwner);
const movedBox = moved.declarations.find((declaration) => declaration.name === "Crate");
if (movedBox.binders[0].id !== box.binders[0].id &&
    movedBox.applications[0].id !== box.applications[0].id) {
    pass("a mutated owner preimage moves both TypeParameterId and ConstructedTypeId");
} else {
    fail("preimage sensitivity", "an owner mutation left a derived identity unchanged");
}

/* Argument order is the identity, not the discovery order. */
const intBool = constructedTypeId(
    pair.id,
    [{ id: primitiveTypeId("Int"), tag: "primitive" }, { id: primitiveTypeId("Bool"), tag: "primitive" }],
);
const boolInt = constructedTypeId(
    pair.id,
    [{ id: primitiveTypeId("Bool"), tag: "primitive" }, { id: primitiveTypeId("Int"), tag: "primitive" }],
);
if (intBool !== boolInt && pair.applications[0].id === intBool) {
    pass("ConstructedTypeId separates argument order that discovery order does not");
} else {
    fail("argument order", "ConstructedTypeId did not separate the two orders");
}

/* Declaration discovery order does not change an identity. */
const reordered = clone(positive);
reordered.declarations = [...reordered.declarations].reverse();
const reorderedDoc = buildDocument(reordered);
const reorderedBox = reorderedDoc.declarations.find((declaration) => declaration.name === "Box");
if (reorderedBox.binders[0].id === box.binders[0].id &&
    reorderedBox.applications[0].id === box.applications[0].id) {
    pass("declaration discovery order does not change any derived identity");
} else {
    fail("discovery order", "reordering declarations moved an identity");
}

/* A mutated golden is refused by validation, not accepted as another value. */
const tampered = clone(document);
tampered.declarations[0].binders[0].id = "00".repeat(32);
expectRefuse("internal", "a tampered binder id is refused", () => validateDocument(tampered, positive.logical_path));

const tamperedApp = clone(document);
tamperedApp.declarations[0].applications[0].id = "00".repeat(32);
expectRefuse("internal", "a tampered constructed id is refused", () => validateDocument(tamperedApp, positive.logical_path));

const tamperedSub = clone(document);
tamperedSub.declarations[2].applications[0].fields[0].type = { id: primitiveTypeId("Text"), tag: "primitive" };
expectRefuse("internal", "a tampered substitution is refused", () => validateDocument(tamperedSub, positive.logical_path));

/* ---------------------------------------------------------------- refusals */

const base = {
    logical_path: "examples/generic_record.kofun",
    declarations: [
        { name: "Box", binders: ["T"], fields: [{ name: "value", type: { parameter: "T" } }], applications: [] },
    ],
};

function caseWith(mutate) {
    const value = clone(base);
    mutate(value);
    return value;
}

expectRefuse(CODES.tooManyParameters, "three type parameters are refused", () =>
    buildDocument(caseWith((value) => { value.declarations[0].binders = ["T", "U", "V"]; })));
expectRefuse(CODES.duplicateParameter, "a duplicate type parameter is refused", () =>
    buildDocument(caseWith((value) => { value.declarations[0].binders = ["T", "T"]; })));
expectRefuse(CODES.unsupportedBinder, "a const binder is refused", () =>
    buildDocument(caseWith((value) => { value.declarations[0].binders = [{ const: "N" }]; value.declarations[0].fields[0].type = { primitive: "Int" }; })));
expectRefuse(CODES.unboundParameter, "an unbound field parameter is refused", () =>
    buildDocument(caseWith((value) => { value.declarations[0].fields[0].type = { parameter: "Q" }; })));
expectRefuse(CODES.unknownNominal, "an unknown nominal field is refused", () =>
    buildDocument(caseWith((value) => { value.declarations[0].fields[0].type = { nominal: "Nope", arguments: [] }; })));
expectRefuse(CODES.arityMismatch, "a nominal field with the wrong arity is refused", () =>
    buildDocument(caseWith((value) => {
        value.declarations.push({ name: "Wrap", binders: ["T"], fields: [{ name: "v", type: { parameter: "T" } }], applications: [] });
        value.declarations[0].fields[0].type = { nominal: "Wrap", arguments: [] };
    })));
expectRefuse(CODES.unsupportedField, "a function field is refused", () =>
    buildDocument(caseWith((value) => { value.declarations[0].fields[0].type = { function: [] }; })));

/* The eight-instantiation limit at its boundary. */
const eight = clone(base);
eight.declarations[0].applications = [
    { arguments: [{ primitive: "Int" }] },
    { arguments: [{ primitive: "Bool" }] },
    { arguments: [{ primitive: "Text" }] },
    { arguments: [{ primitive: "Unit" }] },
    { arguments: [{ nominal: "Box", arguments: [{ primitive: "Int" }] }] },
    { arguments: [{ nominal: "Box", arguments: [{ primitive: "Bool" }] }] },
    { arguments: [{ nominal: "Box", arguments: [{ primitive: "Text" }] }] },
    { arguments: [{ nominal: "Box", arguments: [{ primitive: "Unit" }] }] },
];
buildDocument(eight);
pass("eight concrete instantiations of one declaration are accepted");
const nine = clone(eight);
nine.declarations[0].applications.push({ arguments: [{ nominal: "Box", arguments: [{ nominal: "Box", arguments: [{ primitive: "Int" }] }] }] });
expectRefuse(CODES.instantiationLimit, "a ninth instantiation is refused", () => buildDocument(nine));

/* The depth limit at its boundary. */
function nest(levels) {
    let node = { primitive: "Int" };
    for (let index = 0; index < levels; index += 1) {
        node = { nominal: "Box", arguments: [node] };
    }
    return node;
}
const depthEight = clone(base);
depthEight.declarations[0].applications = [{ arguments: [nest(8)] }];
buildDocument(depthEight);
pass("a constructed TypeRef at depth eight is accepted");
const depthNine = clone(base);
depthNine.declarations[0].applications = [{ arguments: [nest(9)] }];
expectRefuse(CODES.depthExceeded, "a constructed TypeRef at depth nine is refused", () => buildDocument(depthNine));

/* Cycles: direct and mutual. */
const directCycle = caseWith((value) => {
    value.declarations[0].fields = [{ name: "self", type: { nominal: "Box", arguments: [{ parameter: "T" }] } }];
});
expectRefuse(CODES.directCycle, "a direct by-value cycle is refused", () =>
    recordCycle(buildDocument(directCycle).declarations));

const mutualCycle = {
    logical_path: "examples/generic_record.kofun",
    declarations: [
        { name: "A", binders: ["T"], fields: [{ name: "b", type: { nominal: "B", arguments: [{ parameter: "T" }] } }], applications: [] },
        { name: "B", binders: ["U"], fields: [{ name: "a", type: { nominal: "A", arguments: [{ parameter: "U" }] } }], applications: [] },
    ],
};
expectRefuse(CODES.mutualCycle, "a mutual by-value cycle is refused", () =>
    recordCycle(buildDocument(mutualCycle).declarations));

/* The accepted shape beside the cycle: A holds a *different* declaration. */
const acyclic = {
    logical_path: "examples/generic_record.kofun",
    declarations: [
        { name: "A", binders: ["T"], fields: [{ name: "b", type: { nominal: "B", arguments: [{ parameter: "T" }] } }], applications: [] },
        { name: "B", binders: ["U"], fields: [{ name: "v", type: { parameter: "U" } }], applications: [] },
    ],
};
recordCycle(buildDocument(acyclic).declarations);
pass("an acyclic by-value reference graph is accepted beside the cycle refusals");

/* --------------------------------------------- canonical Kofun half */

/*
 * The compiler entry that must reproduce the contract. This drives the
 * canonical source through the bounded host driver, so a divergence between
 * the contract and the implementation is caught here rather than only in a
 * golden nobody compares. The C half joins this gate in the next slice.
 */
const { loadCompiler, bytes, text } = await import("../../bootstrap/stage2/host-driver.mjs");

let printed = "";
const kofun = loadCompiler({
    print: (value) => { printed += text(value) + "\n"; },
    validate() { return ""; },
});

function runCompiler(fixture, logicalPath) {
    const out = `${HERE}fixtures/.compiler-${fixture}.out.json`;
    fs.rmSync(out, { force: true });
    printed = "";
    const ok = kofun.emit_generic_record_hir_file(
        bytes(`${HERE}fixtures/${fixture}`),
        bytes(out),
        bytes(logicalPath),
    );
    const artifact = fs.existsSync(out) ? fs.readFileSync(out, "latin1") : null;
    fs.rmSync(out, { force: true });
    return { artifact, ok: Boolean(ok), printed };
}

const compiled = runCompiler("positive.kofun", positive.logical_path);
if (!compiled.ok || compiled.artifact !== goldenText) {
    fail("compiler positive", `the canonical Kofun half does not reproduce the golden (${compiled.printed.trim()})`);
} else {
    pass("the canonical Kofun half reproduces the positive golden byte for byte");
}

const compilerRefusals = [
    ["too_many_parameters.kofun", "E2S192"],
    ["duplicate_parameter.kofun", "E2S193"],
    ["unbound_parameter.kofun", "E2S194"],
    ["arity_mismatch.kofun", "E2S195"],
    ["unknown_nominal.kofun", "E2S196"],
    ["instantiation_limit.kofun", "E2S197"],
    ["depth_exceeded.kofun", "E2S198"],
    ["direct_cycle.kofun", "E2S199"],
    ["mutual_cycle.kofun", "E2S200"],
    ["unsupported_field.kofun", "E2S201"],
    ["unsupported_binder.kofun", "E2S202"],
];
for (const [fixture, code] of compilerRefusals) {
    const result = runCompiler(fixture, positive.logical_path);
    if (result.ok) {
        fail(`compiler ${fixture}`, "accepted a source the contract refuses");
    } else if (!result.printed.includes(`error[${code}]`)) {
        fail(`compiler ${fixture}`, `expected ${code}, got: ${result.printed.trim()}`);
    } else if (result.artifact !== null) {
        fail(`compiler ${fixture}`, "wrote an artifact on refusal");
    }
}
pass(`the canonical Kofun half refuses all ${compilerRefusals.length} negative fixtures with their codes and no artifact`);

/* ------------------------------------------------------------------ output */

for (const line of PASS) process.stdout.write(`${line}\n`);
if (failures > 0) {
    process.stderr.write(`FAIL: generic-record HIR contract: ${failures} check(s) failed\n`);
    process.exit(1);
}
process.stdout.write("PASS: generic-record HIR v1 identities, refusals, and limits are frozen\n");

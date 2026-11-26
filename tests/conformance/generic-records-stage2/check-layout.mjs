import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
    constructedTypeId, framedHash, primitiveTypeId, validateDocument,
} from "../../../spec/generic-record-hir-v1/model.mjs";

const root = fileURLToPath(new URL("../../../", import.meta.url));
export function verifyLayouts(hirFile, logicalPath, work, generatedC) {
    const hir = JSON.parse(readFileSync(hirFile, "utf8"));
    validateDocument(hir, logicalPath);

    // Compute concrete field types from declaration binders, including instances
    // that occur only in a substituted field, without using compiler layouts.
    const declarations = new Map(hir.declarations.map(decl => [decl.id, decl]));
    const types = new Map();
    for (const name of ["Bool", "Int", "Text"]) {
        const id = primitiveTypeId(name);
        types.set(id, name === "Text" ? { id, kind: "text" } : { id, kind: "scalar", scalar: name });
    }
    function substitute(ref, argumentsById) {
        if (ref.tag === "primitive") return ref;
        if (ref.tag === "parameter") {
            assert.ok(argumentsById.has(ref.id), "unbound type parameter");
            return argumentsById.get(ref.id);
        }
        assert.equal(ref.tag, "nominal");
        return { ...ref, arguments: ref.arguments.map(arg => substitute(arg, argumentsById)) };
    }
    function layoutType(ref) {
        if (ref.tag === "primitive") {
            assert.ok(types.has(ref.id), "unsupported field carrier");
            return ref.id;
        }
        const id = constructedTypeId(ref.id, ref.arguments);
        if (types.has(id)) return id;
        const decl = declarations.get(ref.id);
        assert.ok(decl, "unknown record declaration");
        assert.equal(decl.binders.length, ref.arguments.length);
        const environment = new Map(decl.binders.map((b, i) => [b.id, ref.arguments[i]]));
        const record = { id, kind: "record", fields: [] };
        types.set(id, record);
        record.fields = decl.fields.map(f => ({
            name: f.name, type: layoutType(substitute(f.type, environment)),
        }));
        return id;
    }
    for (const decl of hir.declarations) {
        for (const app of decl.applications) {
            assert.equal(layoutType({ tag: "nominal", id: decl.id, arguments: app.arguments }), app.id);
        }
    }
    const input = join(work, "layout-input.json");
    writeFileSync(input, JSON.stringify({ schema: "kofun.aggregate-layout-document/v1", types: [...types.values()] }));
    const { layouts } = JSON.parse(execFileSync(process.execPath, [
        join(root, "spec/aggregate-layout-v1/layout.mjs"), "describe",
        join(root, "spec/aggregate-layout-v1/targets/x86_64-linux.json"), input,
    ], { encoding: "utf8" }));

    // All 256 bits fit in the 63 significant initial characters guaranteed by C11
    // for an internal identifier. No identifier truncation or source-order suffix.
    function symbol(id) {
        const bytes = Buffer.concat([
            Buffer.from("x86_64-linux\0", "ascii"), Buffer.from(id, "hex"),
            Buffer.from("\0record-c11/v1\0aggregate-layout-v1", "ascii"),
        ]);
        const hash = framedHash("kofun.id.backend-symbol/v1", bytes);
        const bits = [...Buffer.from(hash, "hex")].map(b => b.toString(2).padStart(8, "0")).join("");
        const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
        return "KofunGR_" + bits.padEnd(260, "0").match(/.{5}/g)
            .map(word => alphabet[Number.parseInt(word, 2)]).join("");
    }
    const records = layouts.filter(type => type.kind === "record");
    const names = records.map(type => symbol(type.id));
    assert.ok(names.length > 0);
    assert.equal(new Set(names).size, names.length);
    // Each association of a C11 generic selection must name an incompatible
    // type. This makes type erasure a compiler error even for identical layouts.
    const associations = names.map(name => name + "*: 1").join(", ");
    const assertions = [`_Static_assert(_Generic((${names[0]}*)0, ${associations}), "distinct constructed C types");`];
    for (const type of records) {
        const name = symbol(type.id);
        assertions.push(`_Static_assert(sizeof(${name}) == ${type.size}, "oracle size");`);
        assertions.push(`_Static_assert(_Alignof(${name}) == ${type.align}, "oracle alignment");`);
        for (const field of type.fields) {
            assert.match(field.name, /^[A-Za-z_][A-Za-z0-9_]*$/);
            assertions.push(`_Static_assert(offsetof(${name}, f_${field.name}) == ${field.offset}, "oracle offset");`);
        }
    }
    writeFileSync(join(work, "assert-layout.c"), assertions.join("\n") + "\n");
    if (generatedC) {
        const emitted = readFileSync(generatedC, "utf8");
        for (const name of names) {
            assert.equal(emitted.split(`} ${name};`).length - 1, 1, `one C type for ${name}`);
            assert.ok(emitted.includes(`_Static_assert(sizeof(${name})`), `compiler size for ${name}`);
            assert.ok(emitted.includes(`_Static_assert(_Alignof(${name})`), `compiler alignment for ${name}`);
        }
    }
    console.log(`Verified ${names.length} concrete record identities and independently calculated their layouts`);
}

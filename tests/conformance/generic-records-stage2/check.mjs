import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { verifyLayouts } from "./check-layout.mjs";
import { bytes, loadCompiler, text } from "../../../bootstrap/stage2/host-driver.mjs";

const directory = fileURLToPath(new URL(".", import.meta.url));
const root = path.resolve(directory, "../../..");
const [native, compilerSource, work] = process.argv.slice(2);
const cc = process.env.CC || "cc";
const inputs = path.join(work, "inputs");
fs.mkdirSync(inputs, { recursive: true });

function run(command, args) {
    const result = spawnSync(command, args, { encoding: "utf8" });
    if (result.error) throw result.error;
    return result;
}

function checked(command, args) {
    const result = run(command, args);
    assert.equal(result.status, 0, [command, ...args, result.stdout, result.stderr].join(" "));
    return result.stdout;
}

let message = "";
const compiler = loadCompiler({
    source: fs.readFileSync(compilerSource, "utf8"),
    print: line => { message += text(line) + "\n"; },
    validate: () => "",
});

function compare(source, expectedError) {
    const name = path.basename(source, ".kofun");
    const outputs = [".c", ".ir", ".tokens"].map(ext => path.join(work, name + ext));
    // Both halves write to the same paths in turn, so a difference even in
    // the path printed on success is observable without rewriting stdout.
    function reset() { for (const file of outputs) fs.rmSync(file, { force: true }); }
    function snapshot() { return outputs.map(file => fs.existsSync(file) ? fs.readFileSync(file) : null); }
    const args = [source, ...outputs];
    reset();
    const result = run(native, ["--compile-outcome", ...args]);
    assert.equal(result.stderr, "", name);
    const artifacts = snapshot();
    reset();
    message = "";
    const code = Number(compiler.compile_file(...args.map(bytes)));
    assert.equal(code, result.status, name + " exit status");
    assert.equal(message, result.stdout, name + " diagnostic");
    assert.deepEqual(snapshot(), artifacts, name + " C, scope IR, and token tape");
    if (expectedError) {
        assert.equal(code, 1, name);
        assert.equal(message.trimEnd(), expectedError, name);
        assert.equal(artifacts[0], null, name + " refused before emitting C");
    } else {
        assert.equal(code, 0, name + ": " + message);
        assert.ok(artifacts[0], name + " emitted C");
    }
    return outputs[0];
}

for (const name of ["execute", "transitive", "transfer", "mixed"]) {
    const expected = fs.readFileSync(path.join(directory, name + ".stdout"), "utf8");
    const input = path.join(directory, name + ".kofun");
    const generated = compare(input);
    let checkedSource = generated;
    if (name === "execute") {
        const hir = path.join(work, "execute-hir.json");
        checked(native, ["--emit-generic-record-hir", input, hir, "main.kofun"]);
        verifyLayouts(hir, "main.kofun", work, generated);
        checkedSource = path.join(work, "checked.c");
        fs.writeFileSync(checkedSource, Buffer.concat([fs.readFileSync(generated), fs.readFileSync(path.join(work, "assert-layout.c"))]));
    }
    for (const optimization of ["-O0", "-O2"]) {
        const program = path.join(work, name + optimization);
        checked(cc, ["-std=c11", optimization, "-Wall", "-Wextra", "-Werror", "-pedantic", checkedSource, "-o", program]);
        assert.equal(checked(program, []), expected);
    }

    if (name === "execute") {
        const authored = fs.readFileSync(input, "utf8");
        const split = authored.indexOf("type Pair[");
        const end = authored.indexOf("fn pack(");
        assert.ok(split > 0 && end > split);
        const reordered = path.join(inputs, "declaration-order.kofun");
        fs.writeFileSync(reordered, authored.slice(split, end) + authored.slice(0, split) + authored.slice(end));
        const reorderedC = compare(reordered);
        assert.deepEqual(fs.readFileSync(reorderedC), fs.readFileSync(generated), "declaration order changed emitted C");
    }

    const relocated = path.join(inputs, path.basename(input));
    fs.copyFileSync(input, relocated);
    const repeat = path.join(work, name + "-repeat.c");
    checked(native, ["--compile-outcome", relocated, repeat, repeat + ".ir", repeat + ".tokens"]);
    assert.deepEqual(fs.readFileSync(repeat), fs.readFileSync(generated), name + " varies by physical source path");
}
compare(path.join(directory, "distinct.kofun"), "error[E2S32]: nominal record binding `Box[Text]` does not match `Box[Int]` at byte 182");
compare(path.join(directory, "use_after_move.kofun"), "error[E2S123]: `box` was moved by `take` and cannot be used again at bytes 92..95; moved by `take` at bytes 72..80");

const hirCases = path.join(root, "spec/generic-record-hir-v1/fixtures");
for (const name of ["arity_mismatch", "depth_exceeded", "duplicate_parameter", "too_many_parameters",
                    "unbound_parameter", "unknown_nominal", "unsupported_binder", "unsupported_field"]) {
    compare(path.join(hirCases, name + ".kofun"), fs.readFileSync(path.join(hirCases, name + ".stderr"), "utf8").trimEnd());
}

function boundary(name, source, expected) {
    const file = path.join(inputs, name + ".kofun");
    fs.writeFileSync(file, source);
    compare(file, expected);
}
boundary("direct-cycle", "type X[T] = { self: X[T] }\nfn consume(read x: X[Int]) -> Int { return 0 }\nfn main() -> Int { return 0 }\n",
    "error[E2S199]: recursive by-value record layout at byte 46");
boundary("mutual-cycle", "type A[T] = { b: B[T] }\ntype B[T] = { a: A[T] }\nfn consume(read x: A[Int]) -> Int { return 0 }\nfn main() -> Int { return 0 }\n",
    "error[E2S200]: mutually recursive by-value record layout at byte 67");
const tuples = ["Int", "Bool", "Text", "Box[Int]", "Box[Bool]", "Box[Text]", "Box[Box[Int]]", "Box[Box[Bool]]", "Box[Box[Text]]"];
const parameters = tuples.map((arg, i) => `p${i}: Box[${arg}]`).join(", ");
boundary("instance-limit", `type Box[T] = { value: T }\nfn consume(${parameters}) -> Int { return 0 }\nfn main() -> Int { return 0 }\n`,
    "error[E2S197]: `Box` has more than 8 instantiations at byte 0");
console.log("PASS: both Stage 2 compilers agree on concrete generic record C, type identities, layouts, runtime output, and refusal boundaries");

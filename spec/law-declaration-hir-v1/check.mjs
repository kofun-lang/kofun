import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {bytes, loadCompiler, text} from '../../bootstrap/stage2/host-driver.mjs';
import {fileId} from '../generic-record-hir-v1/model.mjs';

const [binary, validator, work] = process.argv.slice(2);
const here = fileURLToPath(new URL('.', import.meta.url));
const root = path.resolve(here, '../..');
const logical = 'examples/law.kofun';
const fixtures = path.join(here, 'fixtures');
const read = file => fs.readFileSync(file, 'utf8');
const file = name => path.join(work, name);
const spawn = (command, args) => {
    const result = spawnSync(command, args, {encoding: 'utf8'});
    if (result.error) throw result.error;
    assert.equal(result.signal, null);
    assert.equal(result.stderr, '');
    return {status: result.status, stdout: result.stdout};
};

let args = [], printed = '';
const compiler = loadCompiler({
    argv: args,
    print(value) { printed += text(value) + '\n'; },
    validate(value) {
        const input = file('unicode-input');
        fs.writeFileSync(input, Buffer.from(value, 'latin1'));
        const result = spawn(validator, ['--validate', input]);
        assert.equal(result.status, 0);
        return bytes(result.stdout.trimEnd());
    },
});
function run(half, command) {
    if (half === 'C11') return spawn(binary, command);
    args.splice(0, args.length, ...command);
    printed = '';
    return {status: Number(compiler.main()), stdout: printed};
}

// In the gate the only host-side scratch file is the pinned Unicode
// primitive's input. Snapshot the actual directory at each successful
// invocation to detect accidental publication of an extra document.
fs.writeFileSync(file('unicode-input'), '');
function compare(input) {
    const artifacts = [];
    for (const half of ['C11', 'Kofun']) {
        const output = file('analysis-' + half + '.json');
        fs.rmSync(output, {force: true});
        const before = fs.readdirSync(work);
        assert.deepEqual(run(half, ['--emit-law-hir', input, output, logical]), {status: 0, stdout: ''}, half);
        assert.deepEqual(fs.readdirSync(work).sort(), [...before, path.basename(output)].sort());
        artifacts.push(read(output));
    }
    assert.equal(artifacts[0], artifacts[1], 'encoded HIR bytes');
    const hir = JSON.parse(artifacts[0]);
    assert.deepEqual(Object.keys(hir).sort(), ['check', 'family', 'file_id', 'functions', 'implementation', 'schema']);
    assert.equal(hir.schema, 'kofun.law-declaration-hir/v1');
    assert.equal(hir.file_id, fileId(logical));
    return hir;
}

function refuse(input, expected, logicalPath = logical) {
    for (const half of ['C11', 'Kofun']) {
        const output = file('refusal-' + half + '.json');
        fs.rmSync(output, {force: true});
        const command = ['--emit-law-hir', input, output, logicalPath];
        assert.deepEqual(run(half, command), {status: 1, stdout: expected}, half + ' ' + input);
        assert.equal(fs.existsSync(output), false, 'no partial output');
        fs.writeFileSync(output, 'previous contents');
        assert.deepEqual(run(half, command), {status: 1, stdout: expected});
        assert.equal(read(output), 'previous contents');
    }
}

const canonical = path.join(root, 'tests/usability/06_monad_laws.kofun');
const source = fs.readFileSync(canonical);
const hir = compare(canonical);
assert.equal(read(file('analysis-C11.json')), read(path.join(fixtures, 'canonical.golden.json')),
    'canonical encoded law HIR');
const named = new Map();
function declaration(record) {
    const [start, end] = record.span;
    assert.equal(source.subarray(start, end).toString(), record.name);
    assert.equal(named.has(start), false);
    named.set(start, record);
    return record;
}
function fullSpan(record, first, last) {
    const [start, end] = record.declaration_span;
    const decl = source.subarray(start, end).toString();
    assert.ok(start < record.span[0] && end >= record.span[1], record.name);
    assert.ok(decl.startsWith(first), decl);
    assert.ok(decl.endsWith(last), decl);
}
function points(at, name) {
    assert.equal(named.get(at)?.name, name, 'resolved target at ' + at);
}

declaration(hir.family);
declaration(hir.implementation);
declaration(hir.check);
assert.deepEqual([hir.family.name, hir.implementation.name, hir.check.name],
    ['Monad', 'OptionalBoolMonad', 'OptionalBoolMonadEvidence']);
fullSpan(hir.family, 'law Monad[', '}');
fullSpan(hir.implementation, 'impl OptionalBoolMonad:', '}');
fullSpan(hir.check, 'check laws OptionalBoolMonadEvidence', '}');
for (const fn of hir.functions) fullSpan(fn, 'fn ' + fn.name + '(', '}');
for (const op of hir.family.operations) fullSpan(op, 'operation ' + op.name + '(', 'MA');
points(hir.implementation.family, 'Monad');
points(hir.check.instance, 'OptionalBoolMonad');
assert.deepEqual(hir.family.slots.map(slot => {
    declaration(slot);
    assert.equal(source.subarray(...slot.argument_span).toString(), slot.type);
    return [slot.name, slot.type];
}), [['A', 'Bool'], ['MA', 'Bool?']]);

const signatures = [
    ['optional_pure', '(Bool)->Bool?'], ['optional_bind', '(Bool?,(Bool)->Bool?)->Bool?'],
    ['pure', '(Bool)->Bool?'], ['bind', '(Bool?,(Bool)->Bool?)->Bool?'],
];
const functions = [...hir.functions, ...hir.family.operations];
assert.deepEqual(functions.map(fn => [declaration(fn).name, fn.type]), signatures);
for (const fn of functions) for (const param of fn.parameters) declaration(param);
for (const binding of hir.implementation.bindings) {
    declaration(binding);
    points(binding.operation, binding.name);
    points(binding.function, 'optional_' + binding.name);
    assert.equal(source.subarray(...binding.target_span).toString(), 'optional_' + binding.name);
}
assert.deepEqual(hir.implementation.bindings.map(b => b.name), ['pure', 'bind']);
assert.deepEqual(hir.check.domains.map(domain => [declaration(domain).name, domain.type, domain.origin]),
    [['values', 'Bool', 'all'], ['monads', 'Bool?', 'all'], ['functions', '(Bool)->Bool?', 'all_functions']]);
points(hir.check.domains[2].input, 'values');
points(hir.check.domains[2].output, 'monads');
assert.deepEqual(hir.check.equality, {type: 'Bool?', kind: 'structural'});
assert.equal(hir.check.requested_assurance, 'proven_finite');
assert.equal(hir.check.budget, 'standard');

// Resolve every expression using only lexical declarations in the expected
// equation scope. Rebuild call types from the argument subtrees, and retain
// the order and binding names to compare with the specified equations.
function inspect(node, env) {
    const excerpt = source.subarray(...node.span).toString();
    if (node.kind === 'ref') {
        const expected = env.get(excerpt);
        assert.ok(expected, 'reference in lexical scope: ' + excerpt);
        assert.equal(node.target, expected.span[0]);
        assert.equal(node.type, expected.type);
        return excerpt;
    }
    if (node.kind === 'lambda') {
        const nested = new Map(env);
        for (const param of node.parameters) nested.set(param.name, declaration(param));
        assert.ok(excerpt.startsWith('fn('));
        const body = inspect(node.body, nested);
        assert.equal(node.type, '(' + node.parameters.map(p => p.type).join(',') + ')->' + node.body.type);
        return ['lambda', node.parameters.map(p => p.name), body];
    }
    assert.equal(node.kind, 'call');
    assert.equal(node.span[0], node.callee.span[0]);
    assert.ok(excerpt.endsWith(')'));
    const callee = inspect(node.callee, env);
    const arguments_ = node.arguments.map(arg => inspect(arg, env));
    assert.equal(node.callee.type, '(' + node.arguments.map(arg => arg.type).join(',') + ')->' + node.type);
    return [callee, ...arguments_];
}

const equations = hir.family.equations.map(eq => {
    declaration(eq);
    assert.equal(eq.declaration_span[1], eq.right.span[1]);
    fullSpan(eq, 'equation ' + eq.name + '(', source.subarray(...eq.right.span).toString());
    assert.equal(eq.kind, 'equal');
    assert.equal(eq.type, 'Bool');
    assert.equal(eq.left.type, hir.check.equality.type);
    assert.equal(eq.right.type, hir.check.equality.type);
    const local = new Map(hir.family.operations.map(op => [op.name, op]));
    for (const param of eq.parameters) {
        local.set(param.name, declaration(param));
        assert.ok(hir.check.domains.some(d => d.span[0] === param.domain && d.type === param.type));
    }
    return [eq.name, inspect(eq.left, local), inspect(eq.right, local)];
});
assert.deepEqual(equations, [
    ['left_identity', ['bind', ['pure', 'value'], 'next'], ['next', 'value']],
    ['right_identity', ['bind', 'value', 'pure'], 'value'],
    ['associativity', ['bind', ['bind', 'value', 'first'], 'second'],
        ['bind', 'value', ['lambda', ['x'], ['bind', ['first', 'x'], 'second']]]],
]);

const basePath = path.join(fixtures, 'contextual.kofun');
const base = read(basePath);
const contextual = compare(basePath);
const contextualOperand = file('contextual-operand.kofun');
const equation = 'equation unit(x: T in values) = identity(x) == x';
assert.ok(base.includes(equation));
fs.writeFileSync(contextualOperand, base.replace(equation,
    'equation previous(operation: T in values) = identity(operation) == operation\n    ' + equation));
const withOperand = compare(contextualOperand);
const [previous, unit] = withOperand.family.equations;
assert.equal(unit.name, 'unit');
assert.equal(previous.right.target, previous.parameters[0].span[0]);
assert.equal(contextual.functions[0].name, 'operation');
assert.equal(contextual.implementation.bindings[0].function, contextual.functions[0].span[0]);

for (const name of ['unknown-binding', 'signature', 'substitution', 'syntax']) {
    refuse(path.join(fixtures, name + '.kofun'), read(path.join(fixtures, name + '.stderr')));
}
function mutation(original, old, replacement, marker, code, message, last = false) {
    assert.ok(original.includes(old));
    const changed = original.replace(old, replacement);
    const at = (last ? changed.lastIndexOf(marker) : changed.indexOf(marker));
    assert.ok(at >= 0, marker);
    const input = file('mutated.kofun');
    fs.writeFileSync(input, changed);
    refuse(input, 'error[' + code + ']: ' + message + ' at byte ' + Buffer.byteLength(changed.slice(0, at)) + '\n');
}

mutation(base, 'instance = Concrete', 'instance = Wrong', 'Wrong', 'E2S229', 'unresolved law name `Wrong`');
mutation(base, 'in values)', 'in unknown)', 'unknown', 'E2S229', 'unresolved law name `unknown`');
mutation(base, '{ identity = operation }', '{ }', '}\ncheck', 'E2S229', 'unbound required law operation `identity`');
mutation(base, 'Identity[Bool]', 'Identity[Bool,Bool?]', ',Bool?]', 'E2S231', 'law substitution arity does not match family');
mutation(base, 'identity(x) == x', 'identity(x,x) == x', '(x,x)', 'E2S230', 'law call arguments do not match callable type');
mutation(base, 'identity(x) == x', 'identity(x) == identity', '==', 'E2S230', 'law operands do not match the selected equality type');
mutation(source.toString(), 'all_functions(values, monads)', 'all_functions(monads, values)', 'all_functions(monads, values)',
    'E2S230', 'function domain type does not match component domains');
mutation(source.toString(), 'bind(first(x), second)', 'bind(first(unbound), second)', 'unbound',
    'E2S229', 'unresolved law name `unbound`');

// Renaming all contextual uses and reordering independent declarations must
// still resolve the function by name, including a forward definition.
const reordered = file('forward.kofun');
const moved = base.match(/^fn .*\n/m)[0];
fs.writeFileSync(reordered, '# 担当者\n' + base.replace(moved, '').replaceAll('Identity', 'Join').replaceAll('identity', 'equation') + moved);
const forward = compare(reordered);
assert.equal(forward.family.operations[0].name, 'equation');
assert.ok(forward.implementation.bindings[0].function > forward.implementation.bindings[0].span[0]);
assert.equal(forward.implementation.bindings[0].function, Buffer.from(read(reordered)).indexOf('fn operation') + 3);

refuse(basePath, 'error[E2S228]: law HIR logical path must be canonical relative UTF-8 at byte 0\n', '../law.kofun');
const tooLarge = file('too-large.kofun');
fs.writeFileSync(tooLarge, '#'.repeat(16385));
refuse(tooLarge, 'error[E2S228]: law declaration source exceeds 16384 bytes at byte 0\n');
const tooMany = file('too-many-tokens.kofun');
fs.writeFileSync(tooMany, 't '.repeat(1025));
refuse(tooMany, 'error[E2S228]: law declaration source exceeds 1024 tokens at byte 2048\n');
const unterminated = file('unterminated.kofun');
fs.writeFileSync(unterminated, '"unterminated');
refuse(unterminated, 'error[E2S228]: expected a complete source token in law declarations at byte 0\n');
const same = file('same.kofun');
fs.writeFileSync(same, base);
for (const half of ['C11', 'Kofun']) {
    assert.deepEqual(run(half, ['--emit-law-hir', same, same, logical]),
        {status: 1, stdout: 'error[E2S228]: law HIR input and output must be distinct at byte 0\n'});
    assert.equal(read(same), base);
}

// Use the ordinary code-producing entry to request a program that contains
// the assurance requirement. Analysis-only recognition must never turn that
// request into a successful build, evidence, or even a partial C artifact.
const ordinary = file('ordinary.kofun');
fs.writeFileSync(ordinary, 'fn law(check: Int) -> Int { return check }\nfn main() -> Int { return law(0) }\n');
const outputs = [];
for (const half of ['C11', 'Kofun']) {
    const destination = file('ordinary-' + half + '.c');
    const ir = file('ordinary-' + half + '.ir'), tokens = ir + '.tokens';
    const rejected = run(half, ['--compile-outcome', canonical, destination, ir, tokens]);
    assert.equal(rejected.status, 1);
    assert.match(rejected.stdout, /^error\[E2S02\]/);
    for (const item of [destination, ir, tokens]) assert.equal(fs.existsSync(item), false);
    assert.deepEqual(run(half, ['--compile-outcome', ordinary, destination, ir, tokens]), {status: 0, stdout: destination + '\n'});
    assert.ok(read(destination).includes('int main('));
    outputs.push([read(ir), read(tokens)]);
}
assert.deepEqual(outputs[0], outputs[1], 'non-law token tape and structural IR');

console.log('PASS: law declaration HIR, resolution, typed equations, refusals and ordinary compilation on both compiler halves');

// Compiler capture transactions (#1225): complete checked-capture facts reach
// KSE2 and typed-sidecar v2 through `bootstrap/stage2/capture_events_producer.c`.
// Expectations come from the authored §14 source fixtures through the
// independent oracle and the accepted capture model, never from the producer.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {framedHash, identities, maximumRecordsFixture, sourceExpected, uint} from '../captures-direct/oracle.mjs';
import {buildScopeHir, projectKse2CaptureSection, projectTypedSidecarCaptures} from '../../../spec/concurrency/scoped-captures-v1/model.mjs';
import {encodeStage2SemanticEventsV2, readStage2SemanticEvents, readStage2SemanticEventsV2} from '../../../tooling/typed-sidecar/from-stage2.mjs';
import {readTypedSidecar} from '../../../tooling/typed-sidecar/codec.mjs';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const fixtures = JSON.parse(fs.readFileSync(path.join(root, 'tests/concurrency/captures/cases.json'), 'utf8'));
const logical = fixtures.logical_path;
const emitter = path.join(root, 'tooling/typed-sidecar/emit-stage2-v2.mjs');
const parent = path.join(root, 'build', process.env.KOFUN_GATE_WORK_NAMESPACE ?? '', 'concurrency-capture-events');
fs.mkdirSync(parent, {recursive: true});
const work = fs.mkdtempSync(path.join(parent, 'run-'));
const sentinel = Buffer.from('prior capture transaction\n');

function run(command, args, options = {}) {
    const result = spawnSync(command, args, {cwd: root, timeout: 600000, maxBuffer: 64 * 1024 * 1024, ...options});
    if (result.error) throw result.error;
    return {status: result.status, signal: result.signal, stdout: result.stdout.toString('utf8'), stderr: result.stderr.toString('utf8')};
}
function compile(name, flags, cc = process.env.CC || 'cc', source) {
    const output = path.join(work, name);
    let input = 'bootstrap/stage2/capture_events_producer.c';
    if (source !== undefined) {
        input = path.join(work, `${name}.c`);
        fs.writeFileSync(input, source);
    }
    const result = run(cc, ['-std=c11', ...flags, '-Wall', '-Wextra', '-Werror', '-pedantic', '-Ibootstrap/stage2',
        input, 'bootstrap/stage2/sha256.c', '-o', output]);
    assert.equal(result.status, 0, result.stderr);
    return output;
}
const O0 = compile('producer-O0', ['-O0']);
const O2 = compile('producer-O2', ['-O2']);
const sanitized = compile('producer-sanitized', ['-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'], process.env.SANITIZER_CC || 'clang');
const producers = [O0, O2, sanitized];
const compilerBinary = path.join(work, 'kofun-stage2');
{
    const result = run(process.env.CC || 'cc', ['-std=c11', '-O2', 'bootstrap/stage2/compiler.c', '-o', compilerBinary]);
    assert.equal(result.status, 0, result.stderr);
}
let serial = 0;
const sha = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const writeSource = (name, source) => {
    const input = path.join(work, `${serial++}-${name}.kofun`);
    fs.writeFileSync(input, source);
    return input;
};

// ------------------------------------------------------------------ wire

// A structural frame walk written from §7/KSE1 alone, independent of both
// the producer and the #1224 reader.
function frames(bytes) {
    assert.equal(bytes.subarray(0, 4).toString('latin1'), 'KSE\0');
    assert.equal(bytes.readUInt16BE(4), 2);
    assert.equal(bytes.readUInt16BE(6), 0);
    const count = bytes.readUInt32BE(8), payload = bytes.readUInt32BE(12);
    assert.equal(bytes.length, 16 + payload + 32);
    assert.equal(sha(bytes.subarray(0, 16 + payload)), bytes.subarray(16 + payload).toString('hex'));
    const result = [];
    let at = 16;
    while (at < 16 + payload) {
        const length = bytes.readUInt32BE(at + 4);
        result.push({kind: bytes[at], bytes: bytes.subarray(at, at + 8 + length)});
        at += 8 + length;
    }
    assert.equal(at, 16 + payload);
    assert.equal(result.length, count);
    return result;
}
const sectionHex = (bytes) => Buffer.concat(frames(bytes).filter((f) => f.kind >= 8 && f.kind <= 13).map((f) => f.bytes)).toString('hex');

function decode(bytes, label) {
    const read = readStage2SemanticEventsV2(bytes);
    assert.equal(read.ok, true, `${label}: ${JSON.stringify(read.error)}`);
    // The #1224 encoder is a second, independent implementation of the wire.
    const again = encodeStage2SemanticEventsV2(structuredClone(read.events));
    assert.equal(again.ok, true, `${label}: ${JSON.stringify(again.error)}`);
    assert.equal(Buffer.compare(again.bytes, bytes), 0, `${label}: C producer and #1224 encoder bytes`);
    return read.events;
}

// ------------------------------------------------------------------ oracle

const moduleIds = (logicalPath) => {
    const pkg = `kofun.package-id/v1\nkind=anonymous-single-file\nlogical-source=${logicalPath}\n`;
    return {
        package: framedHash('kofun.id.package/v1', Buffer.from(pkg)),
        module: framedHash('kofun.id.module/v1', Buffer.from(`kofun.module-id-input/v1\npackage-payload-begin\n${pkg}package-payload-end\nkind=synthetic-root\n`)),
    };
};
const ORDER = (a, b) => a.span.start - b.span.start || b.span.end - a.span.end || a.node_kind - b.node_kind ||
    Buffer.compare(Buffer.from(a.id, 'hex'), Buffer.from(b.id, 'hex'));

// Named function parameter lists, from the authored source text: the KSE1
// producer's rule makes their bindings parameters and every other one local.
function parameterRanges(source) {
    const ranges = [];
    for (const match of source.matchAll(/\bfn\s+[\p{L}_][\p{L}\p{N}_]*\s*\(/gu)) {
        let depth = 0, at = match.index + match[0].length - 1;
        for (; at < source.length; at++) {
            if (source[at] === '(') depth++;
            if (source[at] === ')' && --depth === 0) break;
        }
        ranges.push([Buffer.byteLength(source.slice(0, match.index + match[0].length)), Buffer.byteLength(source.slice(0, at))]);
    }
    return ranges;
}

function expected(test, logicalPath = logical) {
    const {document, modelInput} = sourceExpected(test, logicalPath);
    assert.deepEqual(document, buildScopeHir(modelInput), `${test.name}: oracle agrees with the accepted model`);
    const ids = identities(logicalPath), source = Buffer.from(test.source);
    const nodes = new Map(), bindings = new Map(), types = new Map(), scopes = new Map();
    const node = (kind, [start, end]) => {
        const id = kind === 13 ? ids.expression([start, end]) : ids.node(kind, [start, end]);
        nodes.set(id, {node_kind: kind, span: {start, end}});
    };
    scopes.set(ids.named('scope', 0), {start: 0, end: source.length});
    for (const par of test.pars) {
        node(4, par.span);
        scopes.set(ids.named('scope', par.scope), {close: par.span[1], within: par.span});
        bindings.set(ids.named('binding', par.token), typeof par.name === 'string' ? {text: par.name} : {});
    }
    for (const task of test.tasks) {
        node(8, task.span);
        node(2, task.lambda_span);
        if (task.join_span) node(8, task.join_span);
        bindings.set(ids.named('binding', task.handle), task.name ? {text: task.name} : {span: task.span});
        for (const observation of task.observations) {
            node(13, observation.span);
            const projections = observation.projections ?? [];
            if (observation.reason || projections.length > 8) continue;
            bindings.set(ids.named('binding', observation.binding), typeof observation.name === 'string' ? {text: observation.name} : {});
            for (const projection of projections) {
                if (projection.kind === 'field') types.set(ids.type(projection.owner), projection.owner);
                else for (const bound of [projection.lower, projection.upper]) if (bound.kind === 'node') node(13, bound.span);
            }
        }
    }
    return {document, nodes, bindings, types, scopes, ids, source, parameters: parameterRanges(test.source)};
}

// Every node and identity of a transaction, checked against the oracle.
function checkNodes(events, oracle, label, {section = true} = {}) {
    const {ids, source} = oracle;
    const nodes = events.filter((e) => e.kind === 'node');
    const owned = events.filter((e) => e.kind === 'identity');
    const byId = new Map(nodes.map((n) => [n.id, n]));
    assert.equal(byId.size, nodes.length, `${label}: unique nodes`);
    assert.deepEqual([...nodes].sort(ORDER).map((n) => n.id), nodes.map((n) => n.id), `${label}: canonical node order`);
    const referenced = new Set();
    for (const n of nodes) {
        assert.equal(n.status, 1, label);
        assert.deepEqual([n.dependencies, n.diagnostic_ids], [[], []], label);
        const recomputed = n.node_kind === 13 ? ids.expression([n.span.start, n.span.end]) : ids.node(n.node_kind, [n.span.start, n.span.end]);
        assert.equal(n.id, recomputed, `${label}: NodeId commits its kind and span`);
    }
    const module = nodes[0];
    assert.deepEqual([module.node_kind, module.span], [1, {start: 0, end: source.length}], `${label}: module root first`);
    const mids = moduleIds(oracle.logical ?? logical);
    const ownerIndex = new Map(nodes.map((n, i) => [n.id, i]));
    assert.deepEqual([...owned].sort((a, b) => ownerIndex.get(a.owner_node_id) - ownerIndex.get(b.owner_node_id) || a.identity_kind - b.identity_kind), owned, `${label}: canonical identity order`);
    for (const identity of owned) {
        const owner = byId.get(identity.owner_node_id);
        assert(owner, `${label}: identity owner committed`);
        referenced.add(owner.id);
        const text = source.subarray(owner.span.start, owner.span.end).toString();
        switch (identity.identity_kind) {
            case 1: case 2: case 3:
                assert.equal(owner, module, label);
                assert.equal(identity.value, [mids.package, mids.module, ids.file][identity.identity_kind - 1], label);
                break;
            case 4: {
                const scope = oracle.scopes.get(identity.value);
                assert(scope, `${label}: ScopeId is a root or par scope`);
                assert.equal(owner.node_kind, 4, label);
                if (scope.close === undefined) assert.deepEqual(owner.span, {start: scope.start, end: scope.end}, `${label}: root scope span`);
                else {
                    assert.equal(owner.span.end, scope.close, `${label}: par scope closes with its par`);
                    assert(owner.span.start > scope.within[0] && text.startsWith('{'), `${label}: par scope opens at its block`);
                }
                break;
            }
            case 5: {
                const binding = oracle.bindings.get(identity.value);
                assert(binding, `${label}: BindingId is a token, handle or place base`);
                if (binding.span) assert.deepEqual(owner.span, {start: binding.span[0], end: binding.span[1]}, `${label}: hidden handle span`);
                else if (binding.text !== undefined) assert.equal(text, binding.text, `${label}: binding declaration span`);
                const parameter = oracle.parameters.some(([s, e]) => owner.span.start >= s && owner.span.end <= e);
                assert.equal(owner.node_kind, parameter ? 3 : 5, `${label}: parameter/local binding kind`);
                break;
            }
            case 8: {
                const name = oracle.types.get(identity.value);
                assert(name, `${label}: TypeId owns a captured field`);
                assert.equal(owner.node_kind, 6, label);
                assert.match(text, new RegExp(`^(?:[a-z]+\\s+)?type\\s+${name}\\b[^]*\\}$`), `${label}: record declaration span`);
                break;
            }
            default:
                assert.fail(`${label}: unexpected identity kind ${identity.identity_kind}`);
        }
    }
    const identityKeys = (kind) => new Set(owned.filter((i) => i.identity_kind === kind).map((i) => i.value));
    if (section) {
        assert.deepEqual(identityKeys(4), new Set(oracle.scopes.keys()), `${label}: every scope`);
        assert.deepEqual(identityKeys(5), new Set(oracle.bindings.keys()), `${label}: every binding`);
        assert.deepEqual(identityKeys(8), new Set(oracle.types.keys()), `${label}: every field owner`);
        for (const [id, want] of oracle.nodes) {
            const found = byId.get(id);
            assert(found, `${label}: authored node ${JSON.stringify(want)} committed`);
            assert.deepEqual({node_kind: found.node_kind, span: found.span}, want, label);
            referenced.add(id);
        }
        assert.deepEqual(new Set(nodes.filter((n) => n.node_kind === 13).map((n) => n.id)),
            new Set([...oracle.nodes].filter(([, n]) => n.node_kind === 13).map(([id]) => id)), `${label}: exactly the authored expressions`);
    } else {
        for (const n of nodes) if (oracle.nodes.has(n.id)) referenced.add(n.id);
    }
    for (const n of nodes) assert(referenced.has(n.id) || n === module, `${label}: node ${n.id} is used`);
}

// Only identities, fixed vocabulary, the logical path and bounded fallback
// text may appear as sidecar strings: no display, name, path or host value.
const VOCABULARY = new Set(['kofun.typed-sidecar/v2', 'kofun.stage2-analysis/scoped-captures/v1', 'default-v2', 'kofun-2026',
    'stage2-semantic-v1', 'checked', 'failed', 'cancelled', 'complete', 'partial', 'validated', 'error', 'stage2',
    'module.root', 'function.declaration', 'parameter.binding', 'lexical.scope', 'local.binding', 'adt.declaration',
    'call.expression', 'analysis.expression', 'PackageId', 'ModuleId', 'FileId', 'ScopeId', 'BindingId', 'TypeId',
    'read', 'edit', 'take', 'place', 'unknown', 'field', 'slice', 'constant', 'node',
    'unresolved-call', 'projection-depth-exceeded', 'unnameable-place']);
function checkPrivacy(value, logicalPath, label, key = '') {
    if (Array.isArray(value)) return value.forEach((item) => checkPrivacy(item, logicalPath, label, key));
    if (value !== null && typeof value === 'object') {
        for (const [name, item] of Object.entries(value)) {
            assert(!['display', 'name', 'label', 'text'].includes(name), `${label}: no ${name} field`);
            checkPrivacy(item, logicalPath, label, name);
        }
        return;
    }
    if (typeof value !== 'string') return;
    if (/^[0-9a-f]+$/.test(value) || /^-?[0-9]+$/.test(value) || VOCABULARY.has(value) || value === logicalPath) return;
    if (['code', 'template_id', 'fallback_text'].includes(key)) return;
    assert.fail(`${label}: unexpected sidecar string ${JSON.stringify(value)} at ${key}`);
}

function sidecar(stream, input, label) {
    const events = path.join(work, `${serial++}.kse2`), destination = `${events}.json`;
    fs.writeFileSync(events, stream);
    const result = run(process.execPath, [emitter, events, destination, input]);
    assert.equal(result.status, 0, `${label}: ${result.stderr}`);
    assert.equal(result.stdout + result.stderr, '');
    const bytes = fs.readFileSync(destination);
    const read = readTypedSidecar(bytes);
    assert.equal(read.ok, true, `${label}: ${JSON.stringify(read.error)}`);
    const text = bytes.toString('utf8');
    for (const forbidden of [work, root.replace(/\/$/, '')]) assert(!text.includes(forbidden), `${label}: no host path`);
    return {bytes, document: read.document};
}

function produce(binary, input, output, logicalPath = logical, extra = []) {
    return run(binary, [...extra, input, logicalPath, output, '7']);
}

// ------------------------------------------------------------------ positive

function positive(test, binaries = producers, logicalPath = logical) {
    const oracle = {...expected(test, logicalPath), logical: logicalPath};
    const input = writeSource(test.name, test.source);
    let first;
    for (const [index, binary] of binaries.entries()) for (let repeat = 0; repeat < (index === 1 ? 2 : 1); repeat++) {
        const output = `${input}.${index}.${repeat}.kse2`;
        const result = produce(binary, input, output, logicalPath);
        assert.equal(result.status, 0, `${test.name}: ${result.stdout}${result.stderr}`);
        assert.equal(result.stdout + result.stderr, '', test.name);
        const bytes = fs.readFileSync(output);
        first ??= bytes;
        assert.equal(Buffer.compare(bytes, first), 0, `${test.name}: identical across O0/O2/sanitizers and repeats`);
    }
    for (const forbidden of [work, root.replace(/\/$/, '')]) assert.equal(first.indexOf(Buffer.from(forbidden)), -1, `${test.name}: no host path`);
    const events = decode(first, test.name);
    const mids = moduleIds(logicalPath);
    assert.deepEqual(events[0], {kind: 'source', package_id: mids.package, module_id: mids.module, file_id: oracle.ids.file,
        logical_path: logicalPath, source_bytes: oracle.source.length, source_sha256: sha(oracle.source), edition: '2026',
        semantic_compatibility: 'stage2-semantic-v1', generation: 7, compiler_exit_class: 0}, test.name);
    assert.deepEqual(events.at(-1), {kind: 'end', source_status: 1, completeness: 1}, test.name);
    assert.equal(events.filter((e) => ['reference', 'fact', 'diagnostic'].includes(e.kind)).length, 0, test.name);
    assert.equal(sectionHex(first), projectKse2CaptureSection(oracle.document).capture_frames_hex, `${test.name}: section equals the model projection of the oracle`);
    checkNodes(events, oracle, test.name);
    const one = sidecar(first, input, test.name), two = sidecar(first, input, test.name);
    assert.equal(Buffer.compare(one.bytes, two.bytes), 0, `${test.name}: sidecar repeat`);
    const plain = (value) => JSON.parse(JSON.stringify(value));
    assert.deepEqual(plain(one.document.captures), plain(projectTypedSidecarCaptures(oracle.document)), `${test.name}: sidecar captures`);
    assert.deepEqual([one.document.schema, one.document.source_status, one.document.completeness], ['kofun.typed-sidecar/v2', 'checked', 'complete']);
    checkPrivacy(one.document, logicalPath, test.name);
    // Analysis leaves ordinary compilation's refusal untouched.
    const c = `${input}.c`, ir = `${input}.ir`, tokens = `${input}.tokens`;
    const compiled = run(compilerBinary, ['--compile-outcome', input, c, ir, tokens]);
    assert.equal(compiled.status, 1, `${test.name}: ordinary compilation still refuses`);
    assert.match(compiled.stdout, /^error\[E2S[0-9]+\]:/, test.name);
    assert(!fs.existsSync(c), `${test.name}: no C output`);
    return {input, bytes: first, events, oracle};
}

const results = new Map();
for (const test of fixtures.positive) results.set(test.name, positive(test));
console.log(`PASS: ${fixtures.positive.length} complete transactions: O0/O2/ASan/UBSan repeat bytes, #1224 re-encoding, model section, authored nodes and identities, sidecar, privacy, ordinary refusal`);
positive(fixtures.positive.find((t) => t.name === 'same-unit-field-effect'), [O2], 'src/capture:日本.kofun');
{
    const boundary = maximumRecordsFixture({functions: 64, pars_per_function: 1, tasks_per_par: 1, index_accesses_per_task: 64, expected_records: 8384});
    const {events} = positive(boundary, [O2]);
    assert.equal(events.filter((e) => typeof e.kind === 'number').length, 8384);
    console.log(`PASS: the full 8,384-record section fits one ${events.length}-event KSE2 transaction`);
}
{
    const file = path.join(root, 'tests/diagnostics/stage2/e2s154_scoped_parallelism.kofun');
    const output = path.join(work, 'e2s154.kse2');
    const result = produce(O2, file, output, 'src/e2s154.kofun');
    assert.equal(result.status, 0, result.stdout);
    decode(fs.readFileSync(output), 'e2s154');
    const compiled = run(compilerBinary, ['--compile-outcome', file, `${output}.c`, `${output}.ir`, `${output}.tokens`]);
    assert.deepEqual([compiled.status, compiled.stdout], [1, 'error[E2S154]: scoped parallelism `par` is specified but not implemented at byte 88\n']);
    console.log('PASS: after successful analysis ordinary compilation still refuses E2S154 at byte 88');
}

// ------------------------------------------------------------------ refusal

const refusalByte = (line) => Number((line.match(/ at byte ([0-9]+)$/) ?? line.match(/\(byte ([0-9]+)\)/) ?? [0, 0])[1]);
const fallback = (line) => line.replace(/[^\x20-\x7e]+/g, '?').slice(0, 1024);
function failed(test, label = test.name) {
    const input = writeSource(label, test.source);
    const json = run(compilerBinary, ['--emit-complete-capture-hir-v2', input, `${input}.json`, logical]);
    assert.equal(json.status, 1, label);
    const lifecycle = run(compilerBinary, ['--emit-scope-hir-v2', input, `${input}.lifecycle.json`, logical]);
    const prefix = lifecycle.status === 0 ? projectKse2CaptureSection(JSON.parse(fs.readFileSync(`${input}.lifecycle.json`, 'utf8'))).capture_frames_hex : '';
    let first;
    for (const [index, binary] of [O2, sanitized].entries()) {
        const output = `${input}.${index}.kse2`;
        const result = produce(binary, input, output);
        assert.deepEqual([result.status, result.stdout, result.stderr], [1, json.stdout, ''], `${label}: same refusal as the JSON entry`);
        const bytes = fs.readFileSync(output);
        first ??= bytes;
        assert.equal(Buffer.compare(bytes, first), 0, label);
    }
    const events = decode(first, label);
    const line = json.stdout.split('\n')[0], code = line.match(/^error\[([A-Z][A-Z0-9]*)\]/)[1];
    if (test.diagnostic_code) assert.equal(code, test.diagnostic_code, label);
    assert.equal(events[0].compiler_exit_class, 1, label);
    assert.deepEqual(events.at(-1), {kind: 'end', source_status: 2, completeness: 2}, label);
    const diagnostics = events.filter((e) => e.kind === 'diagnostic');
    assert.equal(diagnostics.length, 1, label);
    const at = refusalByte(line);
    assert.deepEqual(diagnostics[0], {kind: 'diagnostic', id: framedHash('kofun.semantic.diagnostic/v1', Buffer.concat([Buffer.from(events[0].file_id, 'hex'), Buffer.from(`${code}:${at}:${at}`)])),
        code, category: 'stage2', severity: 1, template_id: `stage2/${code}`, primary_file_id: events[0].file_id,
        primary_span: {start: at, end: at}, fallback_text: fallback(line), affected_ids: [events[1].id], remedy_ids: [],
        truncated: 0, related: [], edits: []}, `${label}: the compiler's own refusal`);
    assert.equal(sectionHex(first), prefix, `${label}: exactly the committed lifecycle prefix`);
    const ids = identities(logical), nodes = events.filter((e) => e.kind === 'node');
    assert.deepEqual([...nodes].sort(ORDER), nodes, `${label}: canonical node order`);
    assert.deepEqual([nodes[0].node_kind, nodes[0].span], [1, {start: 0, end: Buffer.byteLength(test.source)}], label);
    for (const n of nodes) assert.equal(n.id, n.node_kind === 13 ? ids.expression([n.span.start, n.span.end]) : ids.node(n.node_kind, [n.span.start, n.span.end]), label);
    assert.equal(nodes.some((n) => n.node_kind === 13), false, `${label}: no capture expression without captures`);
    const {document} = sidecar(first, input, label);
    assert.deepEqual([document.source_status, document.completeness, document.diagnostics.length], ['failed', 'partial', 1], label);
    checkPrivacy(document, logical, label);
    return {input, prefix};
}
let lifecycleRefusals = 0;
for (const test of fixtures.negative) if (failed(test).prefix !== '') lifecycleRefusals++;
assert(lifecycleRefusals > 0);
const sample = fixtures.positive.find((t) => t.name === 'same-unit-field-effect');
for (const [name, source] of [['nul', `${sample.source}\0`], ['non-nfc', sample.source.replaceAll('outer', 'café')],
    ['malformed', sample.source.slice(0, -4)]]) {
    assert.equal(failed({name, source}).prefix, '', `${name}: refused before lifecycle facts`);
}
console.log(`PASS: ${fixtures.negative.length + 3} refusals publish failed/partial streams with the compiler's own code and span; ${lifecycleRefusals} retain exactly the lifecycle prefix`);

// ------------------------------------------------------------------ cancel

{
    const base = results.get('same-unit-field-effect');
    const lifecycle = projectKse2CaptureSection({...base.oracle.document,
        records: base.oracle.document.records.filter((r) => ['par', 'task', 'join'].includes(r.record))}).capture_frames_hex;
    const full = sectionHex(base.bytes);
    const checkedNodes = new Set(base.events.filter((e) => e.kind === 'node').map((e) => e.id));
    for (const [phase, want] of [['source', ''], ['lifecycle', lifecycle], ['captures', full]]) {
        const output = `${base.input}.cancel-${phase}.kse2`;
        const result = produce(O2, base.input, output, logical, ['--cancel-after', phase]);
        assert.deepEqual([result.status, result.stdout, result.stderr], [1, '', ''], phase);
        const bytes = fs.readFileSync(output), events = decode(bytes, phase);
        assert.equal(events[0].compiler_exit_class, 0);
        assert.deepEqual(events.at(-1), {kind: 'end', source_status: 3, completeness: 2}, phase);
        assert.equal(events.filter((e) => e.kind === 'diagnostic').length, 0, phase);
        assert.equal(sectionHex(bytes), want, `${phase}: committed prefix`);
        assert(events.filter((e) => e.kind === 'node').every((e) => checkedNodes.has(e.id)), `${phase}: nodes are a prefix of the checked transaction`);
        checkNodes(events, base.oracle, `cancel ${phase}`, {section: phase === 'captures'});
        const {document} = sidecar(bytes, base.input, phase);
        assert.deepEqual([document.source_status, document.completeness], ['cancelled', 'partial']);
    }
    // A refusal before the cancellation point is still a failure.
    const late = fixtures.negative.find((t) => t.name === 'complete-captures-66');
    const input = writeSource('late', late.source);
    const lateResult = produce(O2, input, `${input}.kse2`, logical, ['--cancel-after', 'captures']);
    assert.equal(lateResult.status, 1);
    assert.equal(decode(fs.readFileSync(`${input}.kse2`), 'late').at(-1).source_status, 2);
    const early = produce(O2, input, `${input}.early.kse2`, logical, ['--cancel-after', 'lifecycle']);
    assert.deepEqual([early.status, early.stdout], [1, '']);
    assert.equal(decode(fs.readFileSync(`${input}.early.kse2`), 'early').at(-1).source_status, 3);
    console.log('PASS: cancellation after source, lifecycle and captures publishes exactly the committed prefix');
}

// ------------------------------------------------------------------ bounds

{
    const input = writeSource('pre-source', sample.source);
    for (const [label, args, status, pattern] of [
        ['same file', [input, logical, input, '1'], 1, /^error\[E2S35\]: capture event input and output must be distinct\n$/],
        ['empty path', [input, '', `${input}.out`, '1'], 1, /^error\[E2S35\]: capture event logical path/],
        ['parent path', [input, '../capture.kofun', `${input}.out`, '1'], 1, /^error\[E2S35\]:/],
        ['scheme path', [input, 'https:captures.kofun', `${input}.out`, '1'], 1, /^error\[E2S35\]:/],
        ['non-NFC path', [input, 'src/é.kofun', `${input}.out`, '1'], 1, /^error\[E2S35\]:/],
        ['missing input', [`${input}.missing`, logical, `${input}.out`, '1'], 2, /^error\[E2S35\]: stage2_same_file: file lookup failed/],
    ]) {
        for (const existing of [false, true]) {
            const destination = args[2];
            if (destination !== input) {
                if (existing) fs.writeFileSync(destination, sentinel); else fs.rmSync(destination, {force: true});
            }
            const result = run(O2, args);
            assert.equal(result.status, status, label);
            assert.match(result.stdout, pattern, label);
            assert.equal(result.stderr, '', label);
            if (destination === input) assert.equal(fs.readFileSync(input, 'utf8'), sample.source, label);
            else if (existing) assert.equal(Buffer.compare(fs.readFileSync(destination), sentinel), 0, label);
            else assert(!fs.existsSync(destination), label);
        }
    }
    fs.rmSync(`${input}.out`, {force: true});
    for (const args of [[], [input, logical, `${input}.out`], [input, logical, `${input}.out`, '-1'], [input, logical, `${input}.out`, 'x'],
        [input, logical, `${input}.out`, '9007199254740992'], ['--cancel-after', 'end', input, logical, `${input}.out`, '1']]) {
        const result = run(O2, args);
        assert.equal(result.status, 2, JSON.stringify(args));
        assert.equal(result.stdout, '');
        assert(!fs.existsSync(`${input}.out`));
    }
    // A real 16,385-event source costs minutes of analysis, so a lowered event
    // bound proves the same fail-closed path: overflow refuses, never truncates.
    const producerSource = fs.readFileSync(path.join(root, 'bootstrap/stage2/capture_events_producer.c'), 'utf8');
    const anchor = '    CE_MAX_EVENTS = 16384,';
    assert.equal(producerSource.split(anchor).length - 1, 1, 'event bound anchor');
    const bounded = compile('producer-event-bound', ['-O0'], process.env.CC || 'cc', producerSource.replace(anchor, '    CE_MAX_EVENTS = 16,'));
    for (const existing of [false, true]) {
        const destination = `${input}.overflow.${existing}.kse2`;
        if (existing) fs.writeFileSync(destination, sentinel);
        const result = run(bounded, [input, logical, destination, '1']);
        assert.deepEqual([result.status, result.stdout], [3, ''], result.stderr);
        assert.match(result.stderr, /^ETS04: semantic event count exceeds the v2 limit\n$/);
        if (existing) assert.equal(Buffer.compare(fs.readFileSync(destination), sentinel), 0);
        else assert(!fs.existsSync(destination));
    }
    // The emitter re-reads the source before publication.
    const base = results.get('same-unit-field-effect');
    const events = path.join(work, 'stale.kse2'), destination = `${events}.json`, copy = writeSource('stale', sample.source);
    fs.writeFileSync(events, base.bytes);
    fs.writeFileSync(destination, sentinel);
    fs.appendFileSync(copy, '\n');
    const stale = run(process.execPath, [emitter, events, destination, copy]);
    assert.equal(stale.status, 3);
    assert.match(stale.stderr, /^ETS05: /);
    assert.equal(Buffer.compare(fs.readFileSync(destination), sentinel), 0);
    console.log('PASS: pre-source, usage, event-overflow and stale-source refusals preserve absent and prior destinations');
}

// ------------------------------------------------------------------ kind 13

{
    // Kind 13 exists only in KSE2: the same node frame is refused by KSE1.
    const field = (tag, wire, payload) => Buffer.concat([Buffer.from([tag, wire, 0, 0]), uint(payload.length, 4), payload]);
    const frame = (kind, fields) => { const p = Buffer.concat(fields); return Buffer.concat([Buffer.from([kind, 0]), uint(fields.length, 2), uint(p.length, 4), p]); };
    const base = results.get('same-unit-field-effect').events;
    const src = base[0], node = base.find((e) => e.kind === 'node' && e.node_kind === 13);
    const id = (hex) => Buffer.from(hex, 'hex');
    const frames = [
        frame(1, [field(1, 3, id(src.package_id)), field(2, 3, id(src.module_id)), field(3, 3, id(src.file_id)), field(4, 2, Buffer.from(src.logical_path)),
            field(5, 6, uint(src.source_bytes, 8)), field(6, 3, id(src.source_sha256)), field(7, 2, Buffer.from(src.edition)),
            field(8, 2, Buffer.from(src.semantic_compatibility)), field(9, 6, uint(src.generation, 8)), field(10, 4, uint(0, 1))]),
        frame(2, [field(1, 3, id(node.id)), field(2, 4, uint(13, 1)), field(3, 7, Buffer.concat([uint(node.span.start, 4), uint(node.span.end, 4)])),
            field(4, 4, uint(1, 1)), field(5, 8, Buffer.alloc(0)), field(6, 8, Buffer.alloc(0))]),
        frame(7, [field(1, 4, uint(1, 1)), field(2, 4, uint(1, 1))]),
    ];
    const envelope = (major) => {
        const payload = Buffer.concat(frames);
        const unsigned = Buffer.concat([Buffer.from('KSE\0', 'latin1'), uint(major, 2), uint(0, 2), uint(frames.length, 4), uint(payload.length, 4), payload]);
        return Buffer.concat([unsigned, Buffer.from(sha(unsigned), 'hex')]);
    };
    assert.equal(readStage2SemanticEventsV2(envelope(2)).ok, true);
    const v1 = readStage2SemanticEvents(envelope(1));
    assert.deepEqual([v1.ok, v1.error?.message], [false, 'unknown node kind']);
    console.log('PASS: analysis.expression (kind 13) is a KSE2-only node kind');
}

// ------------------------------------------------------------------ controls

// Each defect yields a stream the #1224 reader accepts; only the authored
// oracle above can reject it, so it must.
{
    const producer = fs.readFileSync(path.join(root, 'bootstrap/stage2/capture_events_producer.c'), 'utf8');
    const controls = [
        ['binding-kind', 'strcmp(scope_kind, "parameters") == 0 ? CE_NODE_PARAMETER : CE_NODE_LOCAL', 'CE_NODE_LOCAL', 'typed-unavailable-call'],
        ['scope-span', 'return ce_node(tx, CE_NODE_SCOPE, ce_integer(hir, row, 4),', 'return ce_node(tx, CE_NODE_SCOPE, ce_integer(hir, row, 4) + (strcmp(number, "0") != 0),', 'same-unit-field-effect'],
        ['node-order', 'if (left->end != right->end) return left->end > right->end ? -1 : 1;', 'if (left->end != right->end) return left->end < right->end ? -1 : 1;', 'same-unit-field-effect'],
    ];
    for (const [name, before, after, fixture] of controls) {
        assert.equal(producer.split(before).length - 1, 1, `${name}: unique mutation anchor`);
        const binary = compile(`control-${name}`, ['-O0'], process.env.CC || 'cc', producer.replace(before, after));
        let caught = null;
        try {
            positive(fixtures.positive.find((t) => t.name === fixture), [binary]);
        } catch (error) {
            caught = error;
        }
        assert(caught instanceof assert.AssertionError, `${name}: the oracle must reject the defect`);
        assert.doesNotMatch(caught.message, /C producer and #1224 encoder|: \{"code"/, `${name}: rejected by the oracle, not the reader`);
    }
    console.log(`PASS: ${controls.length} producer defects the #1224 reader accepts are rejected by the authored oracle`);
}
fs.rmSync(work, {recursive: true, force: true});

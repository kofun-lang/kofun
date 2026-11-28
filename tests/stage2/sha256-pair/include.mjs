// Run the actual paired compiler entry points. The Kofun source executes
// under the canonical interpreter and receives only the listed input files.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {HostOperationError, loadCompiler, text} from '../../../bootstrap/stage2/host-driver.mjs';

const [compilerSource, binary, shaEntry, work, root] = process.argv.slice(2);
const drivers = [
  'bootstrap/stage2/build.sh', 'tests/stage2/sha256-pair/check.sh',
  'tests/conformance/bytes-read-file/run.sh', 'tests/conformance/bytes-read-stream/run.sh',
];
const marker = spawnSync('git', ['-C', root, 'grep', '-nF', '^# ---* SHA-256$', '--', ...drivers],
  {encoding: 'utf8'});
assert.ifError(marker.error);
assert.equal(marker.status, 1, marker.stdout + marker.stderr + ' (old SHA-256 marker lookup)');
const canonical = fs.readFileSync(compilerSource, 'utf8');
const pinned = fs.readFileSync(path.join(root, 'bootstrap/stage2/includes/sha256.kofun'), 'utf8');
assert(canonical.includes(pinned), 'included SHA functions differ from the canonical compiler');
assert.equal((pinned.match(/^fn sha256_/gm) ?? []).length, 21);
let printed = '';
const argv = [];
const compiler = loadCompiler({source: canonical, argv, validate: () => '',
  print: value => { printed += text(value) + '\n'; }});
const scratch = path.join(work, 'include-pair');
fs.mkdirSync(scratch, {recursive: true});

function catalog(records) {
  const chunks = [Buffer.from('KOFUN-INCLUDES-1\n')];
  for (const [name, bytes] of records) {
    const data = Buffer.from(bytes);
    chunks.push(Buffer.from(name + '\t' + data.length + '\n'), data, Buffer.from('\n'));
  }
  return Buffer.concat(chunks);
}

function nativeOutcome(args) {
  const result = spawnSync(binary, args, {encoding: 'utf8'});
  assert.ifError(result.error);
  assert.equal(result.stderr, '');
  return {status: result.status, stdout: result.stdout};
}

function kofunOutcome(args) {
  argv.splice(0, argv.length, ...args);
  printed = '';
  try {
    return {status: Number(compiler.main()), stdout: printed};
  } catch (error) {
    if (!(error instanceof HostOperationError)) throw error;
    return {status: 2, stdout: printed + error.message + '\n'};
  }
}

function compare(name, input, bundle, expected) {
  const output = path.join(scratch, name + '.c');
  const args = ['--include-bundle', bundle, '--compile-outcome', input, output, output + '.ir', output + '.tokens'];
  const paths = args.slice(-3);
  const initial = Buffer.from('prior artifact\n');
  const reset = () => paths.forEach(file => fs.writeFileSync(file, initial));
  reset();
  const native = nativeOutcome(args);
  const artifacts = paths.map(file => fs.readFileSync(file));
  reset();
  assert.deepEqual(kofunOutcome(args), native, name);
  assert.equal(native.status, expected ? 1 : 0, name + ' ' + native.stdout);
  if (expected) assert(native.stdout.startsWith('error[' + expected + ']'), name + ' ' + native.stdout);
  for (let i = 0; i < paths.length; i++) {
    assert.deepEqual(fs.readFileSync(paths[i]), artifacts[i], paths[i]);
    if (expected) assert.deepEqual(artifacts[i], initial, paths[i]);
  }
}

const fixed = path.join(work, 'includes-v1.bundle');
const input = path.join(scratch, 'input.kofun');
const bundle = path.join(scratch, 'input.bundle');
const entry = 'fn main() -> Int { return shared() }\n';
function fixture(name, includes, data, expected) {
  fs.writeFileSync(input, includes + '\n' + entry);
  fs.writeFileSync(bundle, data);
  compare(name, input, bundle, expected);
}
const one = catalog([['block', 'fn shared() -> Int { return 0 }\n']]);
fixture('basic', '# include "missing"\ninclude "block"', one);
fixture('multiple', 'include "a"\ninclude "b"', catalog([
  ['a', 'let VALUE = 0\n'], ['b', 'fn shared() -> Int { return VALUE }\n']]));
fixture('unknown', 'include "missing"', one, 'E2S224');
fixture('path', 'include "../block"', one, 'E2S224');
fixture('empty', 'include ""', one, 'E2S224');
fixture('malformed', 'include block', one, 'E2S224');
fixture('duplicate', 'include "block"\ninclude "block"', one, 'E2S224');
fixture('nested', 'include "block"', catalog([['block', 'fn f() -> Int { return 0 }\ninclude "other"']]), 'E2S227');
fixture('decls', 'include "block"', catalog([['block', 'module private.unit\n']]), 'E2S02');
fixture('framing', 'include "block"', Buffer.from('KOFUN-INCLUDES-1\nblock\t65537\n'), 'E2S226');
fixture('nul', 'include "block"', catalog([['block', 'fn f() -> Int { return 0 }\u0000']]), 'E2S226');
fixture('noncanonical', 'include "block"', Buffer.from('KOFUN-INCLUDES-1\nblock\t00\n\n'), 'E2S226');
fixture('duplicate-record', 'include "block"', catalog([['block',''],['block','']]), 'E2S226');
compare('sha256', shaEntry, fixed);
assert.deepEqual(fs.readFileSync(path.join(work, 'block.c')), fs.readFileSync(path.join(scratch, 'sha256.c')));

const alias = path.join(scratch, 'catalog-hardlink');
const prior = path.join(scratch, 'prior-output');
const fresh = path.join(scratch, 'absent-output');
const invalid = path.join(input, 'child');
fs.writeFileSync(input, 'fn main() -> Int { return 0 }\n');
fs.writeFileSync(bundle, one);
fs.linkSync(bundle, alias);
fs.writeFileSync(prior, 'existing output\n');
const preserved = [input, bundle, alias, prior].map(file => [file, fs.readFileSync(file)]);
const same = 'error[E2S35]: compiler input and output must be distinct\n';
const lookup = 'error[E2S35]: stage2_same_file: file lookup failed before output open\n';
for (const [name, catalogPath, destinations, stdout] of [
  ['catalog alias before invalid IR', bundle, [alias, invalid, prior], same],
  ['invalid C output before source alias', bundle, [invalid, input, prior], lookup],
  ['catalog alias at IR before invalid tokens', bundle, [fresh, alias, invalid], same],
  ['source alias before empty catalog lookup', '', [input, prior, fresh], same],
  ['explicit empty catalog operand', '', [fresh, prior, fresh + '-tokens'], lookup],
]) {
  const args = ['--include-bundle', catalogPath, '--compile-outcome', input, ...destinations];
  for (const invoke of [nativeOutcome, kofunOutcome]) {
    assert.deepEqual(invoke(args), {status: 2, stdout}, name);
    for (const [file, contents] of preserved) assert.deepEqual(fs.readFileSync(file), contents, name);
    assert(!fs.existsSync(fresh), name);
    assert(!fs.existsSync(fresh + '-tokens'), name);
  }
}
console.log('PASS: both compiler entry points agree on include results, C, token tape, IR and preservation of prior outputs');

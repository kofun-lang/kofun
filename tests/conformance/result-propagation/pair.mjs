// Both halves of the Stage 2 pair on the result-propagation corpus (#1662).
//
// usage: node pair.mjs STAGE2-BINARY WORK SOURCE.kofun...
//
// The C half is the built binary; the Kofun half is bootstrap/stage2/
// compiler.kofun under the canonical interpreter. For every source both must
// agree on the compile outcome (exit status, printed diagnostic, which
// checkpoints exist and their bytes) and on the scope HIR, which is where the
// typed `propagate` nodes live. A refusal that only one half emits is the
// defect this exists to catch: the C half is what `bin/kofun` runs, and the
// Kofun half is the source of truth.
//
// The corpus is ASCII by construction, so the interpreter's Unicode source
// validator hook is answered here instead of through a native driver; a
// non-ASCII source is refused rather than half-validated.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadCompiler, bytes, text} from '../../../bootstrap/stage2/host-driver.mjs';

const [binary, work, ...sources] = process.argv.slice(2);
assert(binary && work && sources.length > 0, 'usage: pair.mjs STAGE2-BINARY WORK SOURCE.kofun...');
const root = fileURLToPath(new URL('../../../', import.meta.url));
fs.mkdirSync(work, {recursive: true});

let printed = '';
const kofun = loadCompiler({
  source: fs.readFileSync(path.join(root, 'bootstrap/stage2/compiler.kofun'), 'utf8'),
  print: value => { printed += text(value) + '\n'; },
  validate(value) {
    assert(!/[^\x00-\x7f]/.test(value), 'the result-propagation corpus is ASCII');
    return '';
  },
});

function artifacts(directory, stem) {
  const paths = {c: `${stem}.c`, ir: `${stem}.ir`, tokens: `${stem}.tokens`};
  for (const name of Object.values(paths)) fs.rmSync(path.join(directory, name), {force: true});
  return Object.fromEntries(Object.entries(paths).map(([key, name]) => [key, path.join(directory, name)]));
}

function read(file) {
  return fs.existsSync(file) ? fs.readFileSync(file, 'latin1') : null;
}

let compared = 0;
for (const source of sources) {
  const stem = path.basename(source, '.kofun');
  const cDirectory = path.join(work, 'c');
  const kDirectory = path.join(work, 'kofun');
  fs.mkdirSync(cDirectory, {recursive: true});
  fs.mkdirSync(kDirectory, {recursive: true});

  const cOut = artifacts(cDirectory, stem);
  const c = spawnSync(binary, ['--compile-outcome', source, cOut.c, cOut.ir, cOut.tokens], {encoding: 'latin1'});
  assert.equal(c.error, undefined, `${stem}: the C half did not run`);
  assert.equal(c.stderr, '', `${stem}: the C half wrote internal stderr`);

  const kOut = artifacts(kDirectory, stem);
  printed = '';
  const kStatus = Number(kofun.compile_file(bytes(source), bytes(kOut.c), bytes(kOut.ir), bytes(kOut.tokens)));

  assert.equal(kStatus, c.status, `${stem}: exit status differs between the halves`);
  // A successful compile prints its own output path; nothing in this corpus
  // succeeds, but the comparison should not depend on that.
  assert.equal(printed.split(kOut.c).join('OUTPUT.c'), text(c.stdout).split(cOut.c).join('OUTPUT.c'),
    `${stem}: printed outcome differs between the halves`);
  for (const key of ['ir', 'tokens']) {
    assert.equal(read(kOut[key]), read(cOut[key]), `${stem}: ${key} checkpoint differs between the halves`);
  }
  assert.equal(fs.existsSync(kOut.c), fs.existsSync(cOut.c), `${stem}: C output presence differs`);

  const cHir = path.join(cDirectory, `${stem}.scope-hir`);
  const kHir = path.join(kDirectory, `${stem}.scope-hir`);
  fs.rmSync(cHir, {force: true});
  fs.rmSync(kHir, {force: true});
  const cScope = spawnSync(binary, ['--emit-scope-hir', source, cHir], {encoding: 'latin1'});
  assert.equal(cScope.error, undefined, `${stem}: the C scope-HIR run did not start`);
  printed = '';
  const kScope = kofun.emit_scope_hir_file(bytes(source), bytes(kHir)) ? 0 : 1;
  assert.equal(kScope, cScope.status, `${stem}: scope-HIR status differs between the halves`);
  assert.equal(printed, text(cScope.stdout), `${stem}: scope-HIR diagnostic differs between the halves`);
  assert.equal(read(kHir), read(cHir), `${stem}: scope HIR differs between the halves`);
  compared += 1;
}
console.log(`PASS: ${compared} sources compile and build scope HIR identically in both halves of the pair`);

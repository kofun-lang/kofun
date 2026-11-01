// Both halves of the Stage 2 pair on the one place the record payload is NOT
// carried: the checked-capture HIR emitters (#1697).
//
// usage: node capture.mjs STAGE2-BINARY WORK SOURCE.kofun...
//
// The capture HIR types a constructor's formal as `Int`. A flat record payload
// is a different formal, and typing it as `Int` would hand the capture analysis
// a value of the wrong kind, so both halves refuse it instead of carrying it:
// `E2S154`, no output file, and the same printed diagnostic. This is a stated
// boundary of the carve-out (spec/adt-record-payload-v1.md), held on both sides.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadCompiler, bytes, text} from '../../../bootstrap/stage2/host-driver.mjs';

const [binary, work, ...sources] = process.argv.slice(2);
assert(binary && work && sources.length > 0, 'usage: capture.mjs STAGE2-BINARY WORK SOURCE.kofun...');
const root = fileURLToPath(new URL('../../../', import.meta.url));
fs.mkdirSync(work, {recursive: true});

let printed = '';
const kofun = loadCompiler({
  source: fs.readFileSync(path.join(root, 'bootstrap/stage2/compiler.kofun'), 'utf8'),
  print: value => { printed += text(value) + '\n'; },
  validate(value) {
    assert(!/[^\x00-\x7f]/.test(value), 'the corpus is ASCII');
    return '';
  },
});

const EXPECTED = /^error\[E2S154\]: checked capture: enum record payload profile is unavailable at byte \d+\n$/;
let refused = 0;
for (const source of sources) {
  const stem = path.basename(source, '.kofun');
  const cOut = path.join(work, `${stem}.c.json`);
  const kOut = path.join(work, `${stem}.kofun.json`);
  fs.rmSync(cOut, {force: true});
  fs.rmSync(kOut, {force: true});

  const c = spawnSync(binary, ['--emit-capture-hir-v2', source, cOut, `src/${stem}.kofun`], {encoding: 'latin1'});
  assert.equal(c.error, undefined, `${stem}: the C half did not run`);
  assert.equal(c.stderr, '', `${stem}: the C half wrote internal stderr`);
  printed = '';
  const kStatus = kofun.emit_capture_hir_v2_file(bytes(source), bytes(kOut), bytes(`src/${stem}.kofun`)) ? 0 : 1;

  assert.equal(kStatus, c.status, `${stem}: exit status differs between the halves`);
  assert.equal(printed, text(c.stdout), `${stem}: printed diagnostic differs between the halves`);
  assert.notEqual(c.status, 0, `${stem}: the capture HIR carried a record payload`);
  assert.match(printed, EXPECTED, `${stem}: not the record-payload refusal`);
  assert(!fs.existsSync(cOut) && !fs.existsSync(kOut), `${stem}: a refused capture left an artifact`);
  refused += 1;
}
console.log(`PASS: ${refused} record-payload sources are refused E2S154 by the capture HIR emitter in both halves`);

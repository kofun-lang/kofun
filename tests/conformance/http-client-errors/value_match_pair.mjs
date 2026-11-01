// Both halves of the Stage 2 pair on the value-position match fixture, compared
// on what they agree on (#1697).
//
// usage: node value_match_pair.mjs STAGE2-BINARY WORK SOURCE.kofun
//
// On origin/main the two halves already disagree about value-position matches,
// independently of any record payload: the Kofun half refuses `return match`
// with E2S03, and for `let x: Int = match ...` it records the end of the whole
// match as the binding's `visible_start` where the C half records an earlier
// byte. So record-list/pair.mjs, which compares the IR byte for byte, cannot be
// pointed at a source with a value match. This compares everything that is not
// that: the exit status, the printed outcome, the emitted C (which is where the
// record payload is lowered), and requires the IR to differ only in `binding|`
// rows, so nothing but the known `visible_start` column can diverge unseen.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadCompiler, bytes, text} from '../../../bootstrap/stage2/host-driver.mjs';

const [binary, work, source] = process.argv.slice(2);
assert(binary && work && source, 'usage: value_match_pair.mjs STAGE2-BINARY WORK SOURCE.kofun');
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

const stem = path.basename(source, '.kofun');
const files = side => ({c: path.join(work, `${stem}.${side}.c`), ir: path.join(work, `${stem}.${side}.ir`), tokens: path.join(work, `${stem}.${side}.tokens`)});
const cFiles = files('c');
const kFiles = files('kofun');
for (const name of [...Object.values(cFiles), ...Object.values(kFiles)]) fs.rmSync(name, {force: true});

const c = spawnSync(binary, ['--compile-outcome', source, cFiles.c, cFiles.ir, cFiles.tokens], {encoding: 'latin1'});
assert.equal(c.error, undefined, 'the C half did not run');
assert.equal(c.stderr, '', 'the C half wrote internal stderr');
const kStatus = Number(kofun.compile_file(bytes(source), bytes(kFiles.c), bytes(kFiles.ir), bytes(kFiles.tokens)));

assert.equal(kStatus, c.status, 'exit status differs between the halves');
assert.equal(c.status, 0, 'the value-match fixture must compile in both halves');
assert.equal(printed.split(kFiles.c).join('OUTPUT.c'), text(c.stdout).split(cFiles.c).join('OUTPUT.c'),
  'printed outcome differs between the halves');
const read = file => fs.readFileSync(file, 'latin1');
assert.equal(read(kFiles.c), read(cFiles.c), 'emitted C differs between the halves');
assert.equal(read(kFiles.tokens), read(cFiles.tokens), 'tokens differ between the halves');

const irLines = file => read(file).split('\n');
const left = irLines(cFiles.ir);
const right = irLines(kFiles.ir);
assert.equal(left.length, right.length, 'IR row count differs between the halves');
let bindingRows = 0;
left.forEach((line, index) => {
  if (line === right[index]) return;
  assert(line.startsWith('binding|') && right[index].startsWith('binding|'),
    `IR differs outside a binding row at line ${index + 1}`);
  assert.equal(line.split('|').slice(0, -1).join('|'), right[index].split('|').slice(0, -1).join('|'),
    `a binding row differs in more than its visible_start at line ${index + 1}`);
  bindingRows += 1;
});
console.log(`PASS: ${stem} agrees in both halves on outcome, emitted C, and tokens; the IR differs only in ${bindingRows} binding visible_start columns`);

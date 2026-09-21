// Refresh the two derived pair artifacts from the project's digest tool.
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));
if (process.argv.length !== 2) throw new Error('usage: node bootstrap/stage2/refresh-pair.mjs');
const files = ['bootstrap/stage2/compiler.kofun', 'bootstrap/stage2/compiler.c'];
const result = spawnSync(`${root}bin/kofun-digest`, files, {cwd:root, encoding:'utf8'});
if (result.error) throw result.error;
if (result.status !== 0) throw new Error(`pair digest failed: ${result.stderr}`);
const rows = result.stdout.trimEnd().split('\n');
for (const [index, row] of rows.entries()) {
  if (!/^[0-9a-f]{64}  /.test(row) || row.slice(66) !== files[index]) throw new Error('unexpected pair digest record');
}
if (rows.length !== files.length) throw new Error('incomplete pair digest record');
const manifestPath = `${root}bootstrap/manifest.json`;
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
if (manifest.fixed_point_closure.trusted_seed !== files[1]) throw new Error('manifest trusted seed moved');
manifest.fixed_point_closure.trusted_seed_sha256 = rows[1].slice(0,64);
fs.writeFileSync(`${root}bootstrap/stage2/SHA256SUMS`, `${rows.join('\n')}\n`);
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
console.log('Refreshed Stage 2 pair digests and manifest trusted seed.');

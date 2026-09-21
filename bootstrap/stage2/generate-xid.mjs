// Project the pinned C Unicode authority into the compiler's byte-wise Text
// range table. No network and no host Unicode-version dependency.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));
const tables = fs.readFileSync(`${root}unicode/kofun_unicode_tables.inc`, 'utf8');
const path = `${root}bootstrap/stage2/compiler.kofun`;
let generated = '# BEGIN GENERATED XID RANGES\n# Unicode 17.0.0; regenerate with node bootstrap/stage2/generate-xid.mjs.\n';
for (const kind of ['start', 'continue']) {
  const body = tables.match(new RegExp(`kofun_xid_${kind}_ranges\\[\\] = \\{([\\s\\S]*?)\\n\\};`))?.[1];
  if (!body) throw new Error(`missing pinned XID ${kind} table`);
  const ranges = [];
  for (const m of body.matchAll(/0x([0-9A-F]+)\), UINT32_C\(0x([0-9A-F]+)/g)) {
    const [lo, hi] = [parseInt(m[1], 16), parseInt(m[2], 16)];
    const previous = ranges.at(-1);
    if (previous && lo === previous[1] + 1) previous[1] = hi;
    else ranges.push([lo, hi]);
  }
  if (!ranges.length) throw new Error(`empty XID ${kind} table`);
  const packed = ranges.map(r => r.map(x => x.toString(16).toUpperCase().padStart(6, '0')).join('')).join('');
  generated += `fn unicode_xid_${kind}_ranges() -> Text {\n    return "${packed}"\n}\n\n`;
}
generated += '# END GENERATED XID RANGES';
const source = fs.readFileSync(path, 'utf8');
const updated = source.replace(/# BEGIN GENERATED XID RANGES[\s\S]*?# END GENERATED XID RANGES/, generated);
if (process.argv[2] === '--check') {
  if (source !== updated) throw new Error('Kofun XID tables differ from the pinned Unicode authority');
} else if (process.argv.length === 2) fs.writeFileSync(path, updated);
else throw new Error('usage: generate-xid.mjs [--check]');

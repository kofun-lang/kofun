#!/usr/bin/env node

/*
 * Refuse a gate that nothing runs.
 *
 *     node tooling/gate-reachability/check.mjs
 *     node tooling/gate-reachability/check.mjs --count
 *
 * `task task-help` proves every visible task is *classified* into exactly one
 * help group. Nothing proved any of them was ever *run*, and the difference is
 * not academic: thirteen gates were defined, given mutation proofs, and invoked
 * by nothing (#1424). Three of those were added by an author who watched
 * `task-help` go green and read it as coverage.
 *
 * A task counts as reachable when any of these names it:
 *
 *   1. the `verify` runner list;
 *   2. a `.github/workflows/*.yml` step;
 *   3. another task's `deps:` or `- task:`;
 *   4. any executable `.sh` or `.mjs` in the tree.
 *
 * Step 4 is the one a naive search omits, and omitting it produces false
 * positives rather than false negatives — `bootstrap/stage2/verify-runner.sh`
 * runs `task roadmap` explicitly, so a Taskfile-only search reports `roadmap`
 * as an orphan when it runs on every verify.
 *
 * `unreachable.tsv` is a ledger, not a suppression list, and it fails in BOTH
 * directions: a gate that becomes unreachable must be added with a reason, and
 * a listed gate that is now reachable must be removed. The second direction is
 * what makes it shrink instead of accumulating.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const LEDGER = join(ROOT, "tooling", "gate-reachability", "unreachable.tsv");

const read = (p) => readFileSync(p, "utf8");

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    if (entry === ".git" || entry === "node_modules" || entry === "build") continue;
    const full = join(dir, entry);
    let st;
    try {
      st = statSync(full);
    } catch {
      continue;
    }
    if (st.isDirectory()) walk(full, out);
    else if (entry.endsWith(".sh") || entry.endsWith(".mjs")) out.push(full);
  }
  return out;
}

const taskfile = read(join(ROOT, "Taskfile.yml"));
const lines = taskfile.split("\n");

/* Every task the file defines. */
const defined = new Set(
  [...taskfile.matchAll(/^ {2}([a-z][a-z0-9-]*):\s*$/gm)].map((m) => m[1]),
);

/* 1. The verify runner list. */
const verifyStart = lines.findIndex((l) => l === "  verify:");
if (verifyStart < 0) {
  process.stderr.write("FAIL: gate reachability: Taskfile.yml defines no `verify` task\n");
  process.exit(1);
}
let verifyEnd = lines.length;
for (let i = verifyStart + 1; i < lines.length; i += 1) {
  if (/^ {2}[a-z][a-z0-9-]*:\s*$/.test(lines[i])) {
    verifyEnd = i;
    break;
  }
}
const verifyBlock = lines.slice(verifyStart, verifyEnd).join("\n");
const reachable = new Map();
const note = (name, how) => {
  if (defined.has(name) && !reachable.has(name)) reachable.set(name, how);
};
for (const m of verifyBlock.matchAll(/^\s{10,}([a-z][a-z0-9-]+)\s*\\?$/gm)) note(m[1], "verify");

/* 2. Workflow steps. */
const workflows = join(ROOT, ".github", "workflows");
for (const entry of readdirSync(workflows)) {
  if (!entry.endsWith(".yml") && !entry.endsWith(".yaml")) continue;
  const body = read(join(workflows, entry));
  for (const m of body.matchAll(/\btask\s+([a-z][a-z0-9-]+)/g)) note(m[1], `.github/workflows/${entry}`);
}

/* 3. Another task's deps or `- task:`. */
for (const m of taskfile.matchAll(/-\s*task:\s*([a-z][a-z0-9-]+)/g)) note(m[1], "another task");
for (const m of taskfile.matchAll(/deps:\s*\[([^\]]*)\]/g)) {
  for (const name of m[1].split(",")) note(name.trim(), "another task's deps");
}

/* 4. Any executable script. */
/*
 * Comments are stripped before matching. #1428 wrote `task kif-module-trust-profile`
 * inside a comment explaining why that task used to check nothing, and this
 * reader counted the sentence as a caller — reporting the gate as reachable
 * because its own documentation mentioned it.
 *
 * That is the false-positive shape a rule with a near-miss has to be tested
 * against, and it cost a green here before it was noticed. Line comments and
 * block comments only; a `task foo` inside a string literal is still counted,
 * because a script building a command in a string genuinely runs it.
 *
 * Measured, because "still counted" is a claim: stripping strings too changes
 * no verdict today, since `git grep -nE '"[^"]*\btask [a-z-]+'` over `*.sh` and
 * `*.mjs` finds no caller building one. So that half is unprotected by any
 * current fixture and is written here as intent rather than as something the
 * suite would catch. A future caller of that shape is the case to add a test
 * with.
 */
function withoutComments(body) {
  return body
    .replace(/\/\*[^]*?\*\//g, " ")
    .replace(/^\s*#.*$/gm, " ")
    .replace(/^\s*\/\/.*$/gm, " ");
}

for (const file of walk(ROOT)) {
  let body;
  try {
    body = withoutComments(read(file));
  } catch {
    continue;
  }
  for (const m of body.matchAll(/\btask\s+([a-z][a-z0-9-]+)/g)) {
    note(m[1], file.slice(ROOT.length + 1));
  }
}

/*
 * The ledger. Each row is a gate nobody runs and the reason it is tolerated,
 * which is a written record rather than silence.
 */
const ledger = new Map();
for (const raw of read(LEDGER).split("\n")) {
  const line = raw.trim();
  if (!line || line.startsWith("#")) continue;
  const [name, reason] = raw.split("\t");
  if (!name || !reason || !reason.trim()) {
    process.stderr.write(`FAIL: gate reachability: ledger row has no reason: ${raw}\n`);
    process.exit(1);
  }
  ledger.set(name.trim(), reason.trim());
}

const unreachable = [...defined].filter((t) => !reachable.has(t)).sort();

if (process.argv.includes("--count")) {
  for (const t of unreachable) {
    process.stdout.write(`${t}\t${ledger.get(t) ?? "REASON REQUIRED"}\n`);
  }
  process.exit(0);
}

const undeclared = unreachable.filter((t) => !ledger.has(t));
const improved = [...ledger.keys()].filter((t) => !unreachable.includes(t)).sort();
const gone = [...ledger.keys()].filter((t) => !defined.has(t)).sort();

let failed = false;
for (const t of undeclared) {
  process.stderr.write(
    `FAIL: gate reachability: \`${t}\` is defined and nothing runs it. ` +
      "Add it to the verify list, name it from a workflow or a script, or " +
      "record it in tooling/gate-reachability/unreachable.tsv with the reason.\n",
  );
  failed = true;
}
for (const t of improved) {
  if (gone.includes(t)) continue;
  process.stderr.write(
    `FAIL: gate reachability: \`${t}\` is listed as unreachable but ` +
      `${reachable.get(t)} runs it now; remove its row so the improvement is recorded.\n`,
  );
  failed = true;
}
for (const t of gone) {
  process.stderr.write(
    `FAIL: gate reachability: \`${t}\` is listed as unreachable but Taskfile.yml no longer defines it; remove its row.\n`,
  );
  failed = true;
}
if (failed) process.exit(1);

process.stdout.write(
  `PASS: ${defined.size - ledger.size} of ${defined.size} tasks are reachable from verify, CI, another task, or a script\n` +
    `PASS: ${ledger.size} recorded unreachable gates all still describe a gate nothing runs\n`,
);

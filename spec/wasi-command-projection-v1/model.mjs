/*
 * The wasm32-wasi-command1 source/runtime projection, as a pure model.
 *
 * #1098 froze the host-facing side: which imports exist, which capability each
 * needs, and what the manifest looks like. It deliberately changed no Kofun
 * source rule, so nothing said which *checked source operation* reaches which
 * import, or how a program's imports are derived. That is what this file
 * models.
 *
 * It compiles nothing and emits no module. Given a program described as a set
 * of reachable operations and a manifest, it answers the two questions the
 * projection has to answer identically to a real implementation: what does
 * this refuse, and which imports does it emit.
 *
 * The direction that matters is one-way: imports come from *checked
 * operations that are reachable*, intersected with what the manifest grants.
 * Source spelling never grants anything, so an operation named but not
 * reachable emits nothing, and a grant with no operation emits nothing either.
 */

import { CAPABILITIES, IMPORTS, IMPORT_MODULE } from "../wasi-command-profile-v1/contract.mjs";

/*
 * Sub-decision 2: one checked source operation per import family, each
 * requiring an authority value attenuated from the root. The authority column
 * is what makes "source spelling alone never grants anything" checkable — an
 * operation with no authority cannot appear here at all.
 */
export const OPERATIONS = Object.freeze([
  { op: "CommandContext.arguments", authority: "command-context", capability: "arguments", yields: "List[Bytes]" },
  { op: "CommandContext.environment", authority: "command-context", capability: "environment", yields: "List[Bytes] pairs" },
  { op: "Stdin.read", authority: "stdin-handle", capability: "stdin", yields: "Result[Bytes, IoError]" },
  { op: "Stdout.write", authority: "stdout-handle", capability: "stdout", yields: "Result[Unit, IoError]" },
  { op: "Stderr.write", authority: "stderr-handle", capability: "stderr", yields: "Result[Unit, IoError]" },
  { op: "MonotonicClock.now", authority: "clock-authority", capability: "monotonic-clock", yields: "Result[Int, ClockError]" },
  { op: "Random.fill", authority: "random-authority", capability: "random", yields: "Result[Bytes, RandomError]" },
  { op: "Preopen.open", authority: "preopen-directory", capability: "preopen-read", yields: "Result[File, IoError]" },
  { op: "Preopen.read", authority: "preopen-directory", capability: "preopen-read", yields: "Result[Bytes, IoError]" },
  { op: "Exit.exit", authority: "exit-authority", capability: "exit", yields: "Never" },
]);

/* Sub-decision 1. The profile quotes the existing mapping rather than
 * inventing a second one; the model records only that the status is
 * observable and bounded, which is the part an implementation can get wrong. */
export const ENTRYPOINTS = Object.freeze({
  plain: "fn main() -> Int",
  rootAware: "fn main(take root: RootAuthority) -> Int",
});

export const EXIT_STATUS_MIN = 0;
export const EXIT_STATUS_MAX = 255;

/* Sub-decision 7. */
export const MEMORY = Object.freeze({
  exportedMemories: 1,
  importedMemories: 0,
  retainsBorrowedGuestMemory: false,
});

const capabilityOf = (imp) => imp.capability.split("|");

export function importsFor(capability) {
  return IMPORTS.filter((imp) => capabilityOf(imp).includes(capability)).map((imp) => imp.field);
}

export class Refusal extends Error {
  constructor(code, detail) {
    super(`${code}: ${detail}`);
    this.code = code;
    this.detail = detail;
  }
}

/*
 * `program` is { reachable: [operation names] }, `manifest` is
 * { capabilities: {name: boolean}, memoryPages: n }.
 *
 * Returning the derived import set rather than a boolean is deliberate: the
 * interesting failures are emitting an import nothing needs and omitting one
 * something does, and neither is visible in a yes/no answer.
 */
export function project(program, manifest) {
  for (const name of Object.keys(manifest.capabilities ?? {})) {
    if (!CAPABILITIES.includes(name)) {
      throw new Refusal("UnknownCapabilityKey", name);
    }
  }
  for (const name of CAPABILITIES) {
    if (typeof manifest.capabilities?.[name] !== "boolean") {
      throw new Refusal("IncompleteManifest", `capability \`${name}\` is absent or not a Boolean`);
    }
  }
  if (!Number.isInteger(manifest.memoryPages) || manifest.memoryPages <= 0) {
    throw new Refusal("InvalidMemoryCeiling", String(manifest.memoryPages));
  }

  const known = new Map(OPERATIONS.map((o) => [o.op, o]));
  const emitted = new Set();
  const used = new Set();

  for (const opName of program.reachable ?? []) {
    const operation = known.get(opName);
    if (operation === undefined) throw new Refusal("UnknownOperation", opName);

    /*
     * Sub-decision 5. A reachable operation without its grant is a
     * compile-time refusal at that operation, not a silently dropped import
     * and not a runtime error.
     */
    if (manifest.capabilities[operation.capability] !== true) {
      throw new Refusal("MissingGrant", `${opName} needs \`${operation.capability}\``);
    }
    used.add(operation.capability);
    for (const field of importsFor(operation.capability)) emitted.add(field);
  }

  /*
   * A grant with no reachable operation emits nothing. This is the half an
   * implementation is most likely to get wrong by deriving imports from the
   * manifest, which is the easier direction to write.
   */
  const grantedButUnused = CAPABILITIES.filter(
    (c) => manifest.capabilities[c] === true && !used.has(c),
  );

  return {
    module: IMPORT_MODULE,
    imports: [...emitted].sort(),
    usedCapabilities: [...used].sort(),
    grantedButUnused,
    memoryPages: manifest.memoryPages,
  };
}

/*
 * Sub-decision 3. Preview 1's `environ_sizes_get` yields a count, so an absent
 * environment and an empty one are the same observation. The model refuses to
 * offer a distinction rather than inventing one, and this function exists so
 * that refusal is a thing a test can call rather than a sentence in a document.
 */
export function environmentDistinguishesAbsentFromEmpty() {
  return false;
}

export function exitStatusFor(returned) {
  if (!Number.isInteger(returned)) throw new Refusal("NonIntegerExit", String(returned));
  if (returned < EXIT_STATUS_MIN || returned > EXIT_STATUS_MAX) {
    throw new Refusal("ExitStatusOutOfRange", String(returned));
  }
  return returned;
}

export function vectors() {
  const full = Object.fromEntries(CAPABILITIES.map((c) => [c, true]));
  const none = Object.fromEntries(CAPABILITIES.map((c) => [c, false]));
  const cases = [];
  const record = (name, run) => {
    try {
      cases.push({ name, result: run() });
    } catch (error) {
      if (!(error instanceof Refusal)) throw error;
      cases.push({ name, refusal: { code: error.code, detail: error.detail } });
    }
  };

  record("no operations, all grants: nothing is emitted", () =>
    project({ reachable: [] }, { capabilities: full, memoryPages: 16 }));

  record("stdout only", () =>
    project({ reachable: ["Stdout.write"] }, { capabilities: full, memoryPages: 16 }));

  record("every operation", () =>
    project({ reachable: OPERATIONS.map((o) => o.op) }, { capabilities: full, memoryPages: 16 }));

  for (const operation of OPERATIONS) {
    record(`missing grant refuses: ${operation.op}`, () =>
      project({ reachable: [operation.op] }, { capabilities: none, memoryPages: 16 }));
  }

  record("unknown capability key in the manifest", () =>
    project({ reachable: [] }, { capabilities: { ...full, telepathy: true }, memoryPages: 16 }));

  record("absent capability key", () => {
    const partial = { ...full };
    delete partial.random;
    return project({ reachable: [] }, { capabilities: partial, memoryPages: 16 });
  });

  record("zero memory pages", () =>
    project({ reachable: [] }, { capabilities: full, memoryPages: 0 }));

  record("unknown operation", () =>
    project({ reachable: ["Filesystem.unlink"] }, { capabilities: full, memoryPages: 16 }));

  record("exit status 0", () => exitStatusFor(0));
  record("exit status 255", () => exitStatusFor(255));
  record("exit status 256 refuses", () => exitStatusFor(256));
  record("exit status -1 refuses", () => exitStatusFor(-1));

  return cases;
}

/*
 * The wasm32-wasi-command1 projection contract gate.
 *
 *     node spec/wasi-command-projection-v1/check.mjs
 *     node spec/wasi-command-projection-v1/check.mjs --vectors
 *
 * Properties first, then mutations that must break them. The mutations are the
 * point: this profile will be implemented by someone reading the document, and
 * the two mistakes it invites — deriving imports from the manifest instead of
 * from reachable operations, and letting a missing grant fail at runtime
 * instead of at compile time — both produce something that works on the happy
 * path.
 */

import { CAPABILITIES, IMPORTS } from "../wasi-command-profile-v1/contract.mjs";
import {
  OPERATIONS,
  ENTRYPOINTS,
  MEMORY,
  Refusal,
  project,
  importsFor,
  exitStatusFor,
  environmentDistinguishesAbsentFromEmpty,
  vectors,
} from "./model.mjs";

class Broken extends Error {}
const require_ = (claim, ok) => {
  if (!ok) throw new Broken(claim);
};

const full = () => Object.fromEntries(CAPABILITIES.map((c) => [c, true]));
const none = () => Object.fromEntries(CAPABILITIES.map((c) => [c, false]));

const refusalOf = (run) => {
  try {
    run();
  } catch (error) {
    if (error instanceof Refusal) return error.code;
    throw error;
  }
  return null;
};

const PROPERTIES = {
  "every capability has at least one source operation": (m) => {
    for (const capability of CAPABILITIES) {
      require_(
        `${capability} has an operation`,
        m.OPERATIONS.some((o) => o.capability === capability),
      );
    }
  },

  "every source operation requires an authority": (m) => {
    for (const operation of m.OPERATIONS) {
      require_(`${operation.op} names an authority`, Boolean(operation.authority));
    }
  },

  "every frozen import is reachable from some operation": (m) => {
    const emitted = new Set();
    for (const operation of m.OPERATIONS) for (const f of m.importsFor(operation.capability)) emitted.add(f);
    for (const imp of IMPORTS) {
      require_(`${imp.field} is reachable`, emitted.has(imp.field));
    }
  },

  "grants without reachable operations emit nothing": (m) => {
    const out = m.project({ reachable: [] }, { capabilities: full(), memoryPages: 16 });
    require_("no imports", out.imports.length === 0);
    require_("all grants unused", out.grantedButUnused.length === CAPABILITIES.length);
  },

  "one operation emits only its own capability's imports": (m) => {
    const out = m.project({ reachable: ["Stdout.write"] }, { capabilities: full(), memoryPages: 16 });
    require_("stdout emits fd_write", out.imports.includes("fd_write"));
    require_("stdout emits no clock import", !out.imports.includes("clock_time_get"));
    require_("stdout emits no exit import", !out.imports.includes("proc_exit"));
  },

  "a missing grant refuses at the operation": (m) => {
    for (const operation of m.OPERATIONS) {
      require_(
        `${operation.op} without its grant refuses`,
        refusalOf(() => m.project({ reachable: [operation.op] }, { capabilities: none(), memoryPages: 16 })) ===
          "MissingGrant",
      );
    }
  },

  "an unknown manifest key refuses": (m) =>
    require_(
      "unknown key",
      refusalOf(() =>
        m.project({ reachable: [] }, { capabilities: { ...full(), telepathy: true }, memoryPages: 16 }),
      ) === "UnknownCapabilityKey",
    ),

  "an incomplete manifest refuses": (m) => {
    const partial = full();
    delete partial.random;
    require_(
      "absent key",
      refusalOf(() => m.project({ reachable: [] }, { capabilities: partial, memoryPages: 16 })) ===
        "IncompleteManifest",
    );
  },

  "a non-positive memory ceiling refuses": (m) =>
    require_(
      "zero pages",
      refusalOf(() => m.project({ reachable: [] }, { capabilities: full(), memoryPages: 0 })) ===
        "InvalidMemoryCeiling",
    ),

  "an unknown operation refuses": (m) =>
    require_(
      "unknown op",
      refusalOf(() => m.project({ reachable: ["Filesystem.unlink"] }, { capabilities: full(), memoryPages: 16 })) ===
        "UnknownOperation",
    ),

  "the exit status is bounded 0..255": (m) => {
    require_("0 accepted", m.exitStatusFor(0) === 0);
    require_("255 accepted", m.exitStatusFor(255) === 255);
    require_("256 refused", refusalOf(() => m.exitStatusFor(256)) === "ExitStatusOutOfRange");
    require_("-1 refused", refusalOf(() => m.exitStatusFor(-1)) === "ExitStatusOutOfRange");
  },

  "absent and empty environments are not distinguished": (m) =>
    require_("no distinction claimed", m.environmentDistinguishesAbsentFromEmpty() === false),

  "memory is exported once and imported never": (m) => {
    require_("one export", m.MEMORY.exportedMemories === 1);
    require_("no import", m.MEMORY.importedMemories === 0);
    require_("no retention", m.MEMORY.retainsBorrowedGuestMemory === false);
  },

  "only one entrypoint is root-aware": (m) => {
    require_("plain form has no root", !m.ENTRYPOINTS.plain.includes("RootAuthority"));
    require_("root form takes it", m.ENTRYPOINTS.rootAware.includes("take root: RootAuthority"));
  },
};

const MODULE = {
  OPERATIONS,
  ENTRYPOINTS,
  MEMORY,
  project,
  importsFor,
  exitStatusFor,
  environmentDistinguishesAbsentFromEmpty,
};

/* Each mutation is a way a reader of the profile could implement it wrongly. */
const MUTATIONS = {
  "derive imports from the manifest instead of reachable operations": (m) => ({
    ...m,
    project: (program, manifest) => {
      const out = m.project(program, manifest);
      const all = new Set();
      for (const capability of CAPABILITIES) {
        if (manifest.capabilities[capability] === true) {
          for (const f of m.importsFor(capability)) all.add(f);
        }
      }
      return { ...out, imports: [...all].sort() };
    },
  }),
  "let a missing grant pass and fail later": (m) => ({
    ...m,
    project: (program, manifest) => {
      const granted = { ...manifest, capabilities: full() };
      return m.project(program, granted);
    },
  }),
  "accept an unknown manifest key": (m) => ({
    ...m,
    project: (program, manifest) => {
      const known = Object.fromEntries(
        Object.entries(manifest.capabilities).filter(([k]) => CAPABILITIES.includes(k)),
      );
      return m.project(program, { ...manifest, capabilities: known });
    },
  }),
  "default an absent capability key to false": (m) => ({
    ...m,
    project: (program, manifest) => {
      const filled = { ...full(), ...manifest.capabilities };
      for (const c of CAPABILITIES) if (typeof filled[c] !== "boolean") filled[c] = false;
      return m.project(program, { ...manifest, capabilities: filled });
    },
  }),
  "allow an unbounded exit status": (m) => ({ ...m, exitStatusFor: (n) => n }),
  "claim an absent/empty environment distinction": (m) => ({
    ...m,
    environmentDistinguishesAbsentFromEmpty: () => true,
  }),
  "import the memory instead of exporting it": (m) => ({
    ...m,
    MEMORY: { ...m.MEMORY, exportedMemories: 0, importedMemories: 1 },
  }),
  "make the plain entrypoint root-aware": (m) => ({
    ...m,
    ENTRYPOINTS: { ...m.ENTRYPOINTS, plain: "fn main(take root: RootAuthority) -> Int" },
  }),
  "drop an operation's authority requirement": (m) => ({
    ...m,
    OPERATIONS: m.OPERATIONS.map((o) => (o.capability === "random" ? { ...o, authority: "" } : o)),
  }),
};

function runProperties(module) {
  const failures = [];
  for (const [claim, check] of Object.entries(PROPERTIES)) {
    try {
      check(module);
    } catch (error) {
      if (!(error instanceof Broken)) throw error;
      failures.push(claim);
    }
  }
  return failures;
}

function main(argv) {
  if (argv.includes("--vectors")) {
    process.stdout.write(JSON.stringify(vectors(), null, 2) + "\n");
    return;
  }

  const failures = runProperties(MODULE);
  if (failures.length > 0) {
    for (const failure of failures) process.stderr.write(`FAIL: ${failure}\n`);
    process.exit(1);
  }

  const caughtBy = new Map();
  for (const [label, mutate] of Object.entries(MUTATIONS)) {
    const broken = runProperties(mutate(MODULE));
    if (broken.length === 0) {
      process.stderr.write(`FAIL: mutation \`${label}\` was caught by no property\n`);
      process.exit(1);
    }
    const signature = broken.sort().join(" + ");
    if (caughtBy.has(signature)) {
      process.stderr.write(
        `FAIL: mutations \`${caughtBy.get(signature)}\` and \`${label}\` are caught by the same properties (${signature})\n`,
      );
      process.exit(1);
    }
    caughtBy.set(signature, label);
  }

  process.stdout.write(
    `PASS: ${Object.keys(PROPERTIES).length} projection properties hold, over ${OPERATIONS.length} operations and ${IMPORTS.length} frozen imports\n` +
      `PASS: ${Object.keys(MUTATIONS).length} implementation mistakes are each caught, by a distinct property set\n`,
  );
}

main(process.argv.slice(2));

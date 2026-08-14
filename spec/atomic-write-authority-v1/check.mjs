/*
 * The AtomicWriteAuthority v1 contract gate.
 *
 *     node spec/atomic-write-authority-v1/check.mjs
 *     node spec/atomic-write-authority-v1/check.mjs --vectors
 *
 * Two halves. The assertions below state the profile's properties directly, so
 * a reader can see what is claimed without running anything. The mutations
 * then damage the model one rule at a time and require the assertions to
 * notice — a property nobody can break is a property nobody is checking, and
 * this file exists before any of the implementation does, so that is the only
 * kind of confidence available here.
 */

import {
  ADMITTED_FILESYSTEMS,
  REFUSED_FILESYSTEMS,
  TEMP_NAMESPACE,
  MAX_BASENAME_BYTES,
  MAX_CONSECUTIVE_EINTR,
  ISSUANCE_OUTCOMES,
  REPLACEMENT_OUTCOMES,
  World,
  issue,
  replace,
  release,
  validateBasename,
  vectors,
} from "./model.mjs";

const name = (s) => new TextEncoder().encode(s);

class Broken extends Error {}
const require_ = (claim, ok) => {
  if (!ok) throw new Broken(claim);
};

/*
 * Each property is a function so the mutation runner can re-run all of them
 * against a damaged model. They take the module's exports as an argument for
 * exactly that reason.
 */
const PROPERTIES = {
  "an admitted filesystem issues": (m) => {
    const w = new m.World();
    w.registerDirectory("d");
    require_("ext4 issues", m.issue(w, "d", name("r.json")).outcome === "Issued");
  },

  "a refused filesystem reserves nothing": (m) => {
    for (const fs of Object.keys(REFUSED_FILESYSTEMS)) {
      const w = new m.World();
      w.registerDirectory("d", { filesystem: fs });
      const out = m.issue(w, "d", name("r.json"));
      require_(`${fs} refuses`, out.outcome === "UnsupportedFilesystem");
      require_(
        `${fs} takes no reservation`,
        w.directories.get("d").reservationHolder === null,
      );
    }
  },

  "one directory carries one live reservation": (m) => {
    const w = new m.World();
    w.registerDirectory("d");
    require_("first issues", m.issue(w, "d", name("a.json")).outcome === "Issued");
    require_(
      "a second target in the same directory is busy",
      m.issue(w, "d", name("b.json")).outcome === "ReservationBusy",
    );
  },

  "a consumed authority frees the namespace": (m) => {
    const w = new m.World();
    w.registerDirectory("d");
    const a = m.issue(w, "d", name("a.json"));
    require_("declining consumes", m.release(w, a.authority).outcome === "Declined");
    require_("the next issuance succeeds", m.issue(w, "d", name("b.json")).outcome === "Issued");
  },

  "an authority is one-shot": (m) => {
    const w = new m.World();
    w.registerDirectory("d");
    const a = m.issue(w, "d", name("a.json"));
    m.replace(w, a.authority, new Uint8Array([1]));
    require_(
      "a second replace is refused",
      m.replace(w, a.authority, new Uint8Array([2])).outcome === "UseAfterTake",
    );
    const b = m.issue(w, "d", name("b.json"));
    m.release(w, b.authority);
    require_(
      "release after release is refused",
      m.release(w, b.authority).outcome === "UseAfterTake",
    );
  },

  "a committed rename is never relabelled a failure": (m) => {
    const w = new m.World();
    w.registerDirectory("d");
    const a = m.issue(w, "d", name("a.json"), { cleanup: "EIO" });
    const out = m.replace(w, a.authority, new Uint8Array([1]));
    require_("cleanup failure has its own outcome", out.outcome === "CleanupFailed");
    require_("and is still committed", out.committed === true);
  },

  "a failed rename is not committed": (m) => {
    const w = new m.World();
    w.registerDirectory("d");
    const a = m.issue(w, "d", name("a.json"), { rename: "EIO" });
    const out = m.replace(w, a.authority, new Uint8Array([1]));
    require_("rename failure", out.outcome === "RenameFailed");
    require_("not committed", out.committed === false);
    require_("target unchanged", w.directories.get("d").entries.size === 0);
  },

  "every reserved temp name is refused as a target": (m) => {
    const w = new m.World();
    w.registerDirectory("d");
    for (const reserved of TEMP_NAMESPACE) {
      require_(
        `${reserved} refused`,
        m.issue(w, "d", name(reserved)).outcome === "InvalidTargetName",
      );
    }
  },

  "dot, dot-dot, slash, and NUL are refused": (m) => {
    const w = new m.World();
    w.registerDirectory("d");
    for (const bad of [".", "..", "a/b"]) {
      require_(`${bad} refused`, m.issue(w, "d", name(bad)).outcome === "InvalidTargetName");
    }
    require_(
      "NUL refused",
      m.issue(w, "d", new Uint8Array([0x61, 0x00])).outcome === "InvalidTargetName",
    );
  },

  "the basename bound is 255 bytes": (m) => {
    const w = new m.World();
    w.registerDirectory("d");
    require_(
      "255 accepted",
      m.issue(w, "d", new Uint8Array(255).fill(0x61)).outcome === "Issued",
    );
    const w2 = new m.World();
    w2.registerDirectory("d");
    require_(
      "256 refused",
      m.issue(w2, "d", new Uint8Array(256).fill(0x61)).outcome === "InvalidTargetName",
    );
  },

  "the EINTR bound is 128 retries": (m) => {
    const w = new m.World();
    w.registerDirectory("d");
    require_(
      "128 still issues",
      m.issue(w, "d", name("a.json"), { eintrRuns: MAX_CONSECUTIVE_EINTR }).outcome === "Issued",
    );
    const w2 = new m.World();
    w2.registerDirectory("d");
    require_(
      "129 is interrupted",
      m.issue(w2, "d", name("a.json"), { eintrRuns: MAX_CONSECUTIVE_EINTR + 1 }).outcome ===
        "InterruptedIssuance",
    );
  },

  "a stray reserved name needs provenance to be recovered": (m) => {
    const w = new m.World();
    w.registerDirectory("d", { strayTempNames: [TEMP_NAMESPACE[7]], provenance: false });
    require_(
      "without provenance it refuses",
      m.issue(w, "d", name("a.json")).outcome === "EnrollmentConflict",
    );
    const w2 = new m.World();
    w2.registerDirectory("d", { strayTempNames: [TEMP_NAMESPACE[7]], provenance: true });
    require_(
      "with provenance it issues",
      m.issue(w2, "d", name("a.json")).outcome === "Issued",
    );
  },

  "there is no path input to traverse": (m) => {
    /*
     * The profile's symlink and `..` safety is by construction: issuance takes
     * a directory the provider already opened, so there is nothing to resolve.
     * The check is that the API has no path parameter — a model that grew one
     * would have to be re-argued, not re-tested.
     */
    require_("issue takes (world, directoryId, basename, provider)", m.issue.length <= 4);
    require_("a slash in the basename is refused", m.validateBasename(name("a/b")) !== null);
  },
};

/* Each mutation is a plausible implementation mistake, not an arbitrary edit. */
const MUTATIONS = {
  "reserve per target instead of per directory": (m) => ({
    ...m,
    issue: (w, d, b, p) => {
      const dir = w.directories.get(d);
      const held = dir.reservationHolder;
      dir.reservationHolder = null;
      const out = m.issue(w, d, b, p);
      if (out.outcome !== "Issued") dir.reservationHolder = held;
      return out;
    },
  }),
  "admit NFS": (m) => ({
    ...m,
    issue: (w, d, b, p) => {
      const dir = w.directories.get(d);
      const was = dir.filesystem;
      if (was === "nfs") dir.filesystem = "ext4";
      const out = m.issue(w, d, b, p);
      dir.filesystem = was;
      return out;
    },
  }),
  "relabel a cleanup failure as a failure": (m) => ({
    ...m,
    replace: (w, a, bytes) => {
      const out = m.replace(w, a, bytes);
      return out.outcome === "CleanupFailed" ? { ...out, committed: false } : out;
    },
  }),
  "let an authority be used twice": (m) => ({
    ...m,
    replace: (w, a, bytes) => {
      const authority = w.authorities.get(a);
      if (authority) authority.consumed = false;
      return m.replace(w, a, bytes);
    },
  }),
  "allow a reserved temp name as a target": (m) => ({
    ...m,
    issue: (w, d, b, p) => {
      const text = new TextDecoder().decode(b);
      if (TEMP_NAMESPACE.includes(text)) {
        return { outcome: "Issued", authority: -1 };
      }
      return m.issue(w, d, b, p);
    },
  }),
  "raise the basename bound to 256": (m) => ({
    ...m,
    issue: (w, d, b, p) => (b.length === 256 ? { outcome: "Issued", authority: -1 } : m.issue(w, d, b, p)),
  }),
  "retry EINTR forever": (m) => ({
    ...m,
    issue: (w, d, b, p) => m.issue(w, d, b, { ...p, eintrRuns: 0 }),
  }),
  "recover a stray name without provenance": (m) => ({
    ...m,
    issue: (w, d, b, p) => {
      const dir = w.directories.get(d);
      const was = dir.provenance;
      dir.provenance = true;
      const out = m.issue(w, d, b, p);
      dir.provenance = was;
      return out;
    },
  }),
};

function runProperties(module) {
  const failures = [];
  for (const [claim, check] of Object.entries(PROPERTIES)) {
    try {
      check(module);
    } catch (error) {
      if (!(error instanceof Broken)) throw error;
      failures.push(`${claim}: ${error.message}`);
    }
  }
  return failures;
}

const MODULE = { World, issue, replace, release, validateBasename };

function main(argv) {
  if (argv.includes("--vectors")) {
    process.stdout.write(JSON.stringify(vectors(), null, 2) + "\n");
    return;
  }

  const outcomeSets = new Set([...ISSUANCE_OUTCOMES, ...REPLACEMENT_OUTCOMES]);
  if (outcomeSets.size !== ISSUANCE_OUTCOMES.length + REPLACEMENT_OUTCOMES.length) {
    process.stderr.write("FAIL: an outcome name is shared between issuance and replacement\n");
    process.exit(1);
  }
  if (TEMP_NAMESPACE.length !== 32 || new Set(TEMP_NAMESPACE).size !== 32) {
    process.stderr.write("FAIL: the temporary namespace is not 32 distinct names\n");
    process.exit(1);
  }
  if (Object.keys(ADMITTED_FILESYSTEMS).length === 0) {
    process.stderr.write("FAIL: the admitted filesystem allowlist is empty\n");
    process.exit(1);
  }

  const failures = runProperties(MODULE);
  if (failures.length > 0) {
    for (const failure of failures) process.stderr.write(`FAIL: ${failure}\n`);
    process.exit(1);
  }

  /*
   * Every mutation must be caught, and each must be caught by a *different*
   * property. Two mutations answered by one property means one of them is not
   * being distinguished from the other.
   */
  const caughtBy = new Map();
  for (const [label, mutate] of Object.entries(MUTATIONS)) {
    const broken = runProperties(mutate(MODULE));
    if (broken.length === 0) {
      process.stderr.write(`FAIL: mutation \`${label}\` was not caught by any property\n`);
      process.exit(1);
    }
    const signature = broken.map((b) => b.split(":")[0]).sort().join(" + ");
    if (caughtBy.has(signature)) {
      process.stderr.write(
        `FAIL: mutations \`${caughtBy.get(signature)}\` and \`${label}\` are caught by the same properties (${signature})\n`,
      );
      process.exit(1);
    }
    caughtBy.set(signature, label);
  }

  process.stdout.write(
    `PASS: ${Object.keys(PROPERTIES).length} profile properties hold on the model\n` +
      `PASS: ${Object.keys(MUTATIONS).length} implementation mistakes are each caught, by a distinct property set\n`,
  );
}

main(process.argv.slice(2));

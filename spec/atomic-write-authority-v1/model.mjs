/*
 * AtomicWriteAuthority v1, as a pure executable model.
 *
 * This file implements no syscall and opens no file. It is the state machine
 * the trusted adapter must implement, written so the contested parts — one
 * live reservation per directory namespace, one-shot consumption, and the rule
 * that a committed rename is never relabelled a failure — can be exercised and
 * mutated before any of it exists in the compiler.
 *
 * The provider is injected and deterministic. It fakes the *inputs* a real
 * provider would read — the filesystem magic, whether a lock is available,
 * which errno a syscall returned — and never the decisions made from them.
 * That boundary is the whole reason this model is worth running: a model that
 * faked the decision would agree with itself no matter what the profile said.
 */

/* Section 1 of PROFILE.md. Widening this is a profile revision, and it is data
 * here so the model and the document cannot drift. */
export const ADMITTED_FILESYSTEMS = Object.freeze({
  ext4: 0xef53,
  xfs: 0x58465342,
  btrfs: 0x9123683e,
  tmpfs: 0x01021994,
});

export const REFUSED_FILESYSTEMS = Object.freeze({
  nfs: 0x6969,
  fuse: 0x65735546,
  overlayfs: 0x794c7630,
});

export const TEMP_NAMESPACE = Object.freeze(
  Array.from({ length: 32 }, (_, i) => `.kofun-atomic-${String(i).padStart(2, "0")}.tmp`),
);

export const MAX_BASENAME_BYTES = 255;
export const MAX_CONSECUTIVE_EINTR = 128;

export const ISSUANCE_OUTCOMES = Object.freeze([
  "Issued",
  "ReservationBusy",
  "UnsupportedLockService",
  "InterruptedIssuance",
  "UnsupportedFilesystem",
  "InvalidTargetName",
  "EnrollmentConflict",
  "ProviderFailure",
]);

export const REPLACEMENT_OUTCOMES = Object.freeze([
  "Replaced",
  "WriteFailed",
  "SyncFailed",
  "RenameFailed",
  "CleanupFailed",
  "Declined",
]);

/*
 * A basename is bytes, not text. Passing a string would quietly decide the
 * UTF-8 question the profile deliberately leaves to `Bytes`, so the model
 * takes bytes and says so.
 */
export function validateBasename(bytes) {
  if (!(bytes instanceof Uint8Array)) return "InvalidTargetName:not-bytes";
  if (bytes.length === 0) return "InvalidTargetName:empty";
  if (bytes.length > MAX_BASENAME_BYTES) return "InvalidTargetName:too-long";
  for (const byte of bytes) {
    if (byte === 0x00) return "InvalidTargetName:nul";
    if (byte === 0x2f) return "InvalidTargetName:slash";
  }
  const text = new TextDecoder("utf-8", { fatal: false }).decode(bytes);
  if (text === "." || text === "..") return "InvalidTargetName:dot";
  if (TEMP_NAMESPACE.includes(text)) return "InvalidTargetName:reserved";
  return null;
}

/*
 * The directory registry is the model's stand-in for "the kernel plus the
 * process registry". One live reservation per directory, because all 32 temp
 * names are shared by every target in that directory — two different targets
 * in one directory contend even though their basenames differ, and that is the
 * property most likely to be got wrong by an implementation that reserves per
 * target.
 */
export class World {
  constructor() {
    this.directories = new Map();
    this.authorities = new Map();
    this.nextAuthorityId = 1;
  }

  registerDirectory(id, { filesystem = "ext4", enrolled = true, strayTempNames = [], provenance = true } = {}) {
    this.directories.set(id, {
      id,
      filesystem,
      enrolled,
      provenance,
      strayTempNames: new Set(strayTempNames),
      reservationHolder: null,
      entries: new Map(),
    });
    return id;
  }
}

/*
 * `provider` is the injected, deterministic half. Each field answers one thing
 * a real provider would learn from the kernel.
 */
const DEFAULT_PROVIDER = Object.freeze({
  lock: "available", // available | busy | unsupported | interrupted-forever
  eintrRuns: 0,
  errno: null,
  write: "ok",
  sync: "ok",
  rename: "ok",
  cleanup: "ok",
});

export function issue(world, directoryId, basename, provider = {}) {
  const p = { ...DEFAULT_PROVIDER, ...provider };
  const directory = world.directories.get(directoryId);
  if (directory === undefined) return { outcome: "ProviderFailure", detail: "unknown-directory" };

  /*
   * Order is normative, not incidental. The filesystem is proved before the
   * name is validated and before anything is reserved, so a refused
   * filesystem never creates a temporary or takes a lock — "refuse before
   * reservation or temporary creation" is a property of the sequence, and a
   * model that checked them in a different order would pass while permitting
   * the thing the profile forbids.
   */
  if (!(directory.filesystem in ADMITTED_FILESYSTEMS)) {
    return { outcome: "UnsupportedFilesystem", detail: directory.filesystem };
  }

  const nameProblem = validateBasename(basename);
  if (nameProblem !== null) {
    const [outcome, detail] = nameProblem.split(":");
    return { outcome, detail };
  }

  if (!directory.enrolled) {
    return { outcome: "EnrollmentConflict", detail: "directory-not-enrolled" };
  }
  if (directory.strayTempNames.size > 0 && !directory.provenance) {
    return { outcome: "EnrollmentConflict", detail: "reserved-name-without-provenance" };
  }

  if (p.lock === "unsupported") return { outcome: "UnsupportedLockService", detail: "ENOLCK" };
  if (p.eintrRuns > MAX_CONSECUTIVE_EINTR) {
    return { outcome: "InterruptedIssuance", detail: `EINTR x${p.eintrRuns}` };
  }
  if (p.lock === "busy" || directory.reservationHolder !== null) {
    return { outcome: "ReservationBusy", detail: "EWOULDBLOCK" };
  }
  if (p.errno !== null) return { outcome: "ProviderFailure", detail: p.errno };

  const id = world.nextAuthorityId++;
  directory.reservationHolder = id;
  world.authorities.set(id, {
    id,
    directoryId,
    basename,
    consumed: false,
    provider: p,
  });
  return { outcome: "Issued", authority: id };
}

function consume(world, authorityId) {
  const authority = world.authorities.get(authorityId);
  if (authority === undefined) return { error: "unknown-authority" };
  if (authority.consumed) return { error: "use-after-take" };
  authority.consumed = true;
  const directory = world.directories.get(authority.directoryId);
  directory.reservationHolder = null;
  return { authority, directory };
}

export function replace(world, authorityId, bytes) {
  const taken = consume(world, authorityId);
  if (taken.error) return { outcome: "UseAfterTake", detail: taken.error };
  const { authority, directory } = taken;
  const p = authority.provider;

  if (p.write !== "ok") return { outcome: "WriteFailed", detail: p.write, committed: false };
  if (p.sync !== "ok") return { outcome: "SyncFailed", detail: p.sync, committed: false };
  if (p.rename !== "ok") return { outcome: "RenameFailed", detail: p.rename, committed: false };

  directory.entries.set(new TextDecoder().decode(authority.basename), bytes);

  /*
   * The rename has committed. A cleanup failure after it is reported as its
   * own outcome and still carries `committed: true`, because the caller's
   * question — did the target change — has already been answered yes. Folding
   * this into a failure is the specific mistake the profile names.
   */
  if (p.cleanup !== "ok") {
    return { outcome: "CleanupFailed", detail: p.cleanup, committed: true };
  }
  return { outcome: "Replaced", committed: true };
}

export function release(world, authorityId) {
  const taken = consume(world, authorityId);
  if (taken.error) return { outcome: "UseAfterTake", detail: taken.error };
  return { outcome: "Declined", committed: false };
}

/* Vectors. Each one is a sentence from PROFILE.md that can be run. */
export function vectors() {
  const cases = [];
  const record = (name, run) => {
    const world = new World();
    cases.push({ name, result: run(world) });
  };

  record("issue on ext4 succeeds", (w) => {
    w.registerDirectory("d");
    return issue(w, "d", new TextEncoder().encode("report.json"));
  });

  for (const fs of Object.keys(REFUSED_FILESYSTEMS)) {
    record(`refuse ${fs} before reserving`, (w) => {
      w.registerDirectory("d", { filesystem: fs });
      const first = issue(w, "d", new TextEncoder().encode("report.json"));
      return { ...first, reservationHolder: w.directories.get("d").reservationHolder };
    });
  }

  record("two targets in one directory contend", (w) => {
    w.registerDirectory("d");
    const a = issue(w, "d", new TextEncoder().encode("a.json"));
    const b = issue(w, "d", new TextEncoder().encode("b.json"));
    return { first: a.outcome, second: b.outcome };
  });

  record("two cooperating processes contend", (w) => {
    w.registerDirectory("d");
    issue(w, "d", new TextEncoder().encode("a.json"));
    return issue(w, "d", new TextEncoder().encode("b.json"), { lock: "busy" });
  });

  record("release frees the namespace", (w) => {
    w.registerDirectory("d");
    const a = issue(w, "d", new TextEncoder().encode("a.json"));
    const declined = release(w, a.authority);
    const b = issue(w, "d", new TextEncoder().encode("b.json"));
    return { declined: declined.outcome, second: b.outcome };
  });

  record("use after take is refused", (w) => {
    w.registerDirectory("d");
    const a = issue(w, "d", new TextEncoder().encode("a.json"));
    replace(w, a.authority, new Uint8Array([1]));
    return replace(w, a.authority, new Uint8Array([2]));
  });

  record("cleanup failure after a committed rename stays committed", (w) => {
    w.registerDirectory("d");
    const a = issue(w, "d", new TextEncoder().encode("a.json"), { cleanup: "EIO" });
    return replace(w, a.authority, new Uint8Array([1]));
  });

  record("rename failure is not committed", (w) => {
    w.registerDirectory("d");
    const a = issue(w, "d", new TextEncoder().encode("a.json"), { rename: "EIO" });
    return replace(w, a.authority, new Uint8Array([1]));
  });

  record("process death frees the reservation", (w) => {
    w.registerDirectory("d");
    issue(w, "d", new TextEncoder().encode("a.json"));
    w.directories.get("d").reservationHolder = null; // the kernel closes the last OFD
    return issue(w, "d", new TextEncoder().encode("b.json"));
  });

  record("a stray reserved name without provenance refuses", (w) => {
    w.registerDirectory("d", { strayTempNames: [TEMP_NAMESPACE[7]], provenance: false });
    return issue(w, "d", new TextEncoder().encode("a.json"));
  });

  record("a stray reserved name with provenance is recovered", (w) => {
    w.registerDirectory("d", { strayTempNames: [TEMP_NAMESPACE[7]], provenance: true });
    return issue(w, "d", new TextEncoder().encode("a.json"));
  });

  record("129 consecutive EINTR is an interrupted issuance", (w) => {
    w.registerDirectory("d");
    return issue(w, "d", new TextEncoder().encode("a.json"), { eintrRuns: 129 });
  });

  record("128 consecutive EINTR still issues", (w) => {
    w.registerDirectory("d");
    return issue(w, "d", new TextEncoder().encode("a.json"), { eintrRuns: 128 });
  });

  const badNames = {
    empty: new Uint8Array([]),
    dot: new TextEncoder().encode("."),
    dotdot: new TextEncoder().encode(".."),
    slash: new TextEncoder().encode("a/b"),
    nul: new Uint8Array([0x61, 0x00, 0x62]),
    reserved: new TextEncoder().encode(TEMP_NAMESPACE[0]),
    tooLong: new Uint8Array(256).fill(0x61),
  };
  for (const [why, bytes] of Object.entries(badNames)) {
    record(`refuse basename: ${why}`, (w) => {
      w.registerDirectory("d");
      return issue(w, "d", bytes);
    });
  }

  record("255 bytes is accepted", (w) => {
    w.registerDirectory("d");
    return issue(w, "d", new Uint8Array(255).fill(0x61));
  });

  return cases;
}

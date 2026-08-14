/*
 * The offline validator for the wasm32-wasi-command1 host matrix.
 *
 *     node spec/wasi-host-matrix-v1/check.mjs [MANIFEST]
 *
 * Offline is the requirement, not a limitation: #1294 asks the CI lane to be
 * allowed to reuse cached binaries while the validator still proves the
 * manifest, the digests, the role separation, and the no-silent-skip policy.
 * So this file never fetches. It decides whether the manifest *pins* something
 * a fetcher could verify, which is a different and checkable question.
 *
 * Every rule below is one the policy states and one a mutation can break.
 * `--mutations` runs those mutations and requires each to be refused.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_MANIFEST = join(HERE, "hosts.json");

export const SCHEMA = "kofun.wasi-host-matrix/v1";
export const TARGET = "wasm32-wasi-command1";
export const MAINTAINED_HOSTS_REQUIRED = 2;
export const ORACLES_REQUIRED = 1;
const SHA256 = /^[0-9a-f]{64}$/;
const EXACT_VERSION = /^[0-9]+\.[0-9]+\.[0-9]+$/;

class Refusal extends Error {}

const refuse = (why) => {
  throw new Refusal(why);
};

/*
 * A floating version is anything that can resolve to different bytes tomorrow.
 * Listing the spellings rather than testing "is it exact" is deliberate: the
 * failure this rule exists for is somebody writing `latest` because it is
 * convenient, and a reader of the refusal should see their own word in it.
 */
const FLOATING = ["latest", "stable", "current", "lts", "*", "main", "head"];

export function validate(manifest) {
  if (manifest.schema !== SCHEMA) {
    refuse(`schema is \`${manifest.schema}\`, not \`${SCHEMA}\``);
  }
  if (manifest.target !== TARGET) {
    refuse(`target is \`${manifest.target}\`, not \`${TARGET}\``);
  }
  if (typeof manifest.retirement_trigger !== "string" || manifest.retirement_trigger.length < 40) {
    refuse("no retirement trigger recorded; POLICY.md 8 requires one");
  }
  if (!Array.isArray(manifest.hosts) || manifest.hosts.length === 0) {
    refuse("no hosts");
  }

  const ids = new Set();
  const implementations = new Set();
  let maintained = 0;
  let oracles = 0;

  for (const host of manifest.hosts) {
    if (!host.id) refuse("a host has no id");
    if (ids.has(host.id)) refuse(`duplicate host id \`${host.id}\``);
    ids.add(host.id);

    if (host.role !== "maintained-host" && host.role !== "differential-oracle") {
      refuse(`host \`${host.id}\` has unknown role \`${host.role}\``);
    }

    /*
     * Absence of a required host is a failure, and there is no field that can
     * turn it into a skip. Refusing `required: false` outright is what makes
     * that true — otherwise the policy is a sentence and the escape is a flag.
     */
    if (host.required !== true) {
      refuse(`host \`${host.id}\` is not \`required: true\`; the matrix has no optional hosts and no silent skip`);
    }

    if (host.role === "differential-oracle") {
      oracles += 1;
      if (host.evidence_kind !== "differential-oracle") {
        refuse(`the oracle \`${host.id}\` must carry \`evidence_kind: differential-oracle\``);
      }
      continue;
    }

    maintained += 1;

    if (host.evidence_kind !== "compatibility-only") {
      refuse(`maintained host \`${host.id}\` must carry \`evidence_kind: compatibility-only\``);
    }
    if (!host.implementation) refuse(`host \`${host.id}\` names no implementation`);
    if (implementations.has(host.implementation)) {
      refuse(
        `hosts \`${host.id}\` and an earlier one share implementation \`${host.implementation}\`; ` +
          "two maintained hosts of one implementation are not two implementations",
      );
    }
    implementations.add(host.implementation);

    const version = String(host.version ?? "");
    if (FLOATING.includes(version.toLowerCase())) {
      refuse(`host \`${host.id}\` pins the floating version \`${version}\``);
    }
    if (!EXACT_VERSION.test(version)) {
      refuse(`host \`${host.id}\` version \`${version}\` is not an exact MAJOR.MINOR.PATCH pin`);
    }

    if (!Array.isArray(host.artifacts) || host.artifacts.length === 0) {
      refuse(`maintained host \`${host.id}\` has no acquisition artifacts`);
    }
    const platforms = new Set();
    for (const artifact of host.artifacts) {
      if (!artifact.platform) refuse(`an artifact of \`${host.id}\` names no platform`);
      if (platforms.has(artifact.platform)) {
        refuse(`host \`${host.id}\` lists platform \`${artifact.platform}\` twice`);
      }
      platforms.add(artifact.platform);
      if (typeof artifact.url !== "string" || !artifact.url.startsWith("https://")) {
        refuse(`artifact ${host.id}/${artifact.platform} has no https URL`);
      }
      /*
       * Absent and malformed are separate refusals. They were one until the
       * mutation runner reported two mutations sharing a reason — a reader who
       * saw the shared message could not tell whether the digest was forgotten
       * or typed wrong, and those have different fixes.
       */
      if (artifact.sha256 === undefined) {
        refuse(`artifact ${host.id}/${artifact.platform} records no sha256`);
      }
      if (!SHA256.test(String(artifact.sha256))) {
        refuse(
          `artifact ${host.id}/${artifact.platform} sha256 \`${artifact.sha256}\` is not 64 hex characters`,
        );
      }
      if (artifact.url.includes(version) === false) {
        refuse(`artifact ${host.id}/${artifact.platform} URL does not contain the pinned version \`${version}\``);
      }
    }
    if (!platforms.has(manifest.required_lane)) {
      refuse(`host \`${host.id}\` has no artifact for the required lane \`${manifest.required_lane}\``);
    }
  }

  if (maintained !== MAINTAINED_HOSTS_REQUIRED) {
    refuse(
      `${maintained} maintained host(s); #26 requires exactly ${MAINTAINED_HOSTS_REQUIRED}, and the oracle is not one of them`,
    );
  }
  if (oracles !== ORACLES_REQUIRED) {
    refuse(`${oracles} differential oracle(s); exactly ${ORACLES_REQUIRED} is required`);
  }

  /*
   * Security is checked as a **field**, not by scanning prose for forbidden
   * words. The first version of this rule scanned, and it refused the shipped
   * manifest: Node's note says its WASI is "not a secure sandbox", which
   * contains both words the scan forbade. A rule that fires on the sentence
   * disclaiming the claim is worse than no rule — it teaches the author to
   * delete the disclaimer.
   *
   * So each host declares `security_claim`, the only accepted value is
   * `none`, and the prose is free to say why.
   */
  for (const host of manifest.hosts) {
    if (host.security_claim !== "none") {
      refuse(
        `host \`${host.id}\` declares \`security_claim: ${host.security_claim}\`; ` +
          "passing this matrix is compatibility evidence and the only accepted value is `none`",
      );
    }
  }

  const compared = manifest.compared_observations ?? [];
  for (const required of ["stdout", "stderr-guest", "exit-status", "trap-class", "manifest-refusal", "artifact-digest"]) {
    if (!compared.includes(required)) {
      refuse(`the compared-observation set omits \`${required}\``);
    }
  }

  return {
    maintained,
    oracles,
    hosts: manifest.hosts.length,
    artifacts: manifest.hosts.reduce((n, h) => n + (h.artifacts?.length ?? 0), 0),
  };
}

/* Each mutation names the policy rule it attacks, so a refusal that stops
 * being specific is visible as two mutations sharing one reason. */
const MUTATIONS = [
  ["unknown host role", (m) => { m.hosts[1].role = "occasional-host"; }],
  ["floating version", (m) => { m.hosts[1].version = "latest"; }],
  ["range version", (m) => { m.hosts[1].version = "24.x"; }],
  ["missing digest", (m) => { delete m.hosts[1].artifacts[0].sha256; }],
  ["short digest", (m) => { m.hosts[1].artifacts[0].sha256 = "abc123"; }],
  ["duplicate role", (m) => { m.hosts[0].role = "maintained-host"; m.hosts[0].evidence_kind = "compatibility-only"; }],
  ["no second implementation", (m) => { m.hosts[2].implementation = m.hosts[1].implementation; }],
  ["optional host", (m) => { m.hosts[1].required = false; }],
  ["oracle counted as a host", (m) => { m.hosts.splice(0, 1); }],
  ["missing required lane", (m) => { m.hosts[1].artifacts = m.hosts[1].artifacts.filter((a) => a.platform !== m.required_lane); }],
  ["http URL", (m) => { m.hosts[1].artifacts[0].url = m.hosts[1].artifacts[0].url.replace("https://", "http://"); }],
  ["URL not matching the pin", (m) => { m.hosts[1].artifacts[0].url = "https://nodejs.org/dist/v1.2.3/node-v1.2.3-linux-x64.tar.xz"; }],
  ["duplicate host id", (m) => { m.hosts[2].id = m.hosts[1].id; }],
  ["security claim", (m) => { m.hosts[1].security_claim = "sandboxed"; }],
  ["dropped comparison", (m) => { m.compared_observations = m.compared_observations.filter((o) => o !== "trap-class"); }],
  ["no retirement trigger", (m) => { delete m.retirement_trigger; }],
  ["wrong schema", (m) => { m.schema = "kofun.wasi-host-matrix/v2"; }],
];

function main(argv) {
  const path = argv.find((a) => !a.startsWith("--")) ?? DEFAULT_MANIFEST;
  const source = readFileSync(path, "utf8");
  const summary = validate(JSON.parse(source));

  if (!argv.includes("--mutations")) {
    process.stdout.write(
      `PASS: ${path} pins ${summary.maintained} maintained hosts, ${summary.oracles} oracle, ${summary.artifacts} digested artifacts\n`,
    );
    return;
  }

  const reasons = new Map();
  for (const [name, mutate] of MUTATIONS) {
    const copy = JSON.parse(source);
    mutate(copy);
    let refusal = null;
    try {
      validate(copy);
    } catch (error) {
      if (!(error instanceof Refusal)) throw error;
      refusal = error.message;
    }
    if (refusal === null) {
      process.stderr.write(`FAIL: mutation \`${name}\` was accepted\n`);
      process.exit(1);
    }
    if (reasons.has(refusal)) {
      process.stderr.write(
        `FAIL: mutations \`${reasons.get(refusal)}\` and \`${name}\` share one refusal: ${refusal}\n`,
      );
      process.exit(1);
    }
    reasons.set(refusal, name);
  }
  process.stdout.write(
    `PASS: ${MUTATIONS.length} manifest mutations are refused, each by its own reason\n`,
  );
}

if (process.argv[1] && process.argv[1].endsWith("check.mjs")) {
  main(process.argv.slice(2));
}

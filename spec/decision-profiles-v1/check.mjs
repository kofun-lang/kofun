#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "../..");

const PROFILES = {
  "stdlib-partial-target-support": {
    contract: "spec/stdlib-partial-target-support-v1/contract.json",
    document: "spec/stdlib-partial-target-support-v1/PROFILE.md",
    option: "A-universal-only",
    properties: [
      ["row-subject", "row.subject", "capability-on-every-declared-toolchain"],
      ["target-authority", "targets.authority", "tests/conformance/backends"],
      ["zero-state", "states.zero_of_n", "planned"],
      ["partial-state", "states.partial", "planned"],
      ["full-state", "states.full", "implemented"],
      ["partial-release", "partial_publication.release_claim", "checkpoint-with-exact-executing-targets"],
      ["partial-mvp", "partial_publication.mvp", "bounded-checkpoint-only"],
      ["unadapted-target", "target_disposition.unadapted", "explicit-unsupported-refusal"],
      ["unsupported-proof", "target_disposition.unsupported", "diagnostic-and-no-runnable-artifact"],
      ["concurrency-owner", "concurrency.until_full_support", 1167],
      ["concurrency-close", "concurrency.close_condition", "all-declared-targets-execute-focused-gate"],
      ["future-target", "future_target", "reopen-portable-row-until-supported-or-refusing-adapter-executes"],
      ["claim-boundary", "claims_advance", false],
    ],
  },
  "workspace-upgrade-transaction": {
    contract: "spec/workspace-upgrade-transaction-v1/contract.json",
    document: "docs/research/workspace-upgrade-transaction.md",
    option: "A-single-file-automatic-v1",
    properties: [
      ["scope", "transaction.files", 1],
      ["multi-file", "transaction.multifile", "preview-only"],
      ["observer", "transaction.observers", "all-direct-path-readers-for-the-one-target"],
      ["linearization", "transaction.linearization", "same-directory-atomic-rename"],
      ["commit-reporting", "transaction.post_rename_failure", "committed-durability-unknown"],
      ["phase-count", "recovery.phases.length", 7],
      ["prepared-recovery", "recovery.prepublication", "rollback-if-old-bytes-otherwise-refuse"],
      ["published-recovery", "recovery.postpublication", "roll-forward-if-new-bytes-otherwise-refuse"],
      ["fresh-authority", "authorization.fresh_for", "apply-recover-and-undo"],
      ["journal-not-authority", "authorization.journal_alone", false],
      ["git-authority", "authorization.git_or_remote", false],
      ["path-resolution", "filesystem.path_resolution", "openat2-beneath-no-magiclinks-no-symlinks"],
      ["hard-links", "filesystem.hard_links", "refuse-link-count-not-one"],
      ["lock-threat", "filesystem.lock", "advisory-cooperating-writers-only"],
      ["source-limit", "limits.source_bytes", 16777216],
      ["path-limit", "limits.path_bytes", 1024],
      ["history-limit", "limits.retained_transactions", 32],
      ["undo", "undo", "fresh-authorized-single-file-transaction-with-current-new-digest"],
      ["claim-boundary", "claims_advance", false],
    ],
  },
  "process-capture-carrier": {
    contract: "spec/process-capture-carrier-v1/contract.json",
    document: "spec/process-capture-carrier-v1/PROFILE.md",
    option: "A-bounded-singular-Bytes-checkpoint",
    properties: [
      ["backend", "target.backend", "c11-stage2"],
      ["release-target", "target.release", "linux-x86_64"],
      ["unsupported-targets", "target.others", "refuse-before-artifact-publication"],
      ["carrier", "output.carrier", "Bytes"],
      ["stream-limit", "output.bytes_per_stream", 65536],
      ["independent-streams", "output.streams", 2],
      ["partial-output", "output.partial_success", false],
      ["combined-bound", "resources.total_working_bytes", 151552],
      ["authority-return", "authority.return", "Ready-or-Revoked-on-every-outcome"],
      ["cancellation", "cancellation", "unreachable-and-absent-from-checkpoint-ADT"],
      ["exec-identity", "adapter.exec_identity", "open-digest-execveat-same-file-description"],
      ["drain", "adapter.drain", "pipe2-nonblocking-epoll-dual-drain"],
      ["termination", "adapter.termination", "dedicated-process-group-SIGKILL-then-exactly-one-reap"],
      ["writer-bound", "adapter.descendant_writer", "eight-terminal-polls-then-terminate-group"],
      ["equal-cut", "precedence.equal_stream_cut", "stdout-before-stderr"],
      ["capability-row", "release.capability_row", "process-capture"],
      ["claim-id", "release.claim", "authorized-process-capture-v1"],
      ["claim-boundary", "claims_advance", false],
    ],
  },
  "directory-enumeration-carrier": {
    contract: "spec/directory-enumeration-carrier-v1/contract.json",
    document: "spec/directory-enumeration-carrier-v1/PROFILE.md",
    option: "C-packed-immutable-DirectorySnapshot",
    properties: [
      ["backend", "target.backend", "c11-stage2"],
      ["release-target", "target.release", "linux-x86_64"],
      ["carrier", "snapshot.carrier", "packed-immutable-name-arena-plus-u32-u16-index"],
      ["entry-limit", "limits.entries", 65536],
      ["name-limit", "limits.name_bytes", 255],
      ["total-limit", "limits.total_name_bytes", 16711680],
      ["metadata-bound", "limits.index_bytes", 524288],
      ["working-bound", "limits.total_working_bytes", 17567744],
      ["authority-return", "authority.return", "Ready-or-Revoked-on-every-outcome"],
      ["snapshot-provider", "snapshot.change_detector", "trusted-monotonic-128-bit-provider-generation"],
      ["retry", "snapshot.retry_count", 1],
      ["unsupported-provider", "snapshot.no_provider", "typed-refusal-before-enumeration"],
      ["lookup", "linux.lookup", "openat2"],
      ["fallback", "linux.fallback", "none-refuse-ENOSYS-or-unsupported-flags"],
      ["openat2-size", "linux.open_how_size", 24],
      ["eagain", "linux.eagain_retries", 8],
      ["decoder", "linux.decoder", "linux_dirent64-strict-v1"],
      ["capability-row", "release.capability_row", "directory-listing"],
      ["claim-id", "release.claim", "authorized-directory-listing-v1"],
      ["claim-boundary", "claims_advance", false],
    ],
  },
  "stage2-pair-host-primitives": {
    contract: "spec/stage2-pair-host-primitives-v1/contract.json",
    document: "spec/stage2-pair-host-primitives-v1/PROFILE.md",
    option: "A-compiler-private-host-primitives",
    properties: [
      ["visibility", "visibility", "compiler-private-not-user-callable"],
      ["scalar-operation", "unicode.operation", "stage2_unicode_scalar_at"],
      ["scalar-input", "unicode.input", "validated-utf8-Text-and-byte-offset"],
      ["scalar-semantics", "unicode.semantics", "decode-one-scalar-at-a-code-point-boundary"],
      ["scalar-result", "unicode.result", "UnicodeScalar-or-typed-index-error"],
      ["scalar-consumer", "unicode.consumer", "identifier_start_at-and-c_identifier_name"],
      ["file-operation", "file_identity.operation", "stage2_same_file"],
      ["file-input", "file_identity.input", "two-driver-authorized-paths"],
      ["file-identity", "file_identity.identity", "text-equality-or-followed-final-symlink-st_dev-and-st_ino"],
      ["missing-output", "file_identity.missing_output", "Different"],
      ["lookup-failure", "file_identity.lookup_failure", "typed-refusal-before-output-open"],
      ["normalization", "file_identity.normalization_substitute", false],
      ["host-boundary", "authority.source", "compiler-driver-host-boundary"],
      ["user-access", "authority.ordinary_program_access", false],
      ["pair-gate", "pair.gate", "stage2-pair-host-primitives"],
      ["serialization", "pair.serialization_owner", 1483],
      ["unicode-fixture", "pair.unicode_fixture", "non-ASCII-declaration-and-call-spelling-byte-identical"],
      ["file-fixture", "pair.file_fixture", "alias-output-refused-before-source-replacement"],
      ["claim-boundary", "claims_advance", false],
    ],
  },
  "native-cli-action-binding": {
    contract: "spec/native-cli-action-binding-v1/contract.json",
    document: "spec/native-cli-action-binding-v1/PROFILE.md",
    option: "A-static-typed-action-table",
    properties: [
      ["backend", "target.backend", "native-x86_64-framework-template"],
      ["release-target", "target.release", "linux-x86_64"],
      ["unsupported-targets", "target.others", "refuse-before-application-publication"],
      ["action-reference", "binding.reference", "current-file-top-level-FunctionId"],
      ["signature", "binding.signature", "fn(take-context-CliActionContext,read-invocation-CliInvocation)-to-CliActionResult"],
      ["table", "binding.table", "declaration-order-command-id-plus-resolved-FunctionId"],
      ["binding-refusal", "binding.missing_or_incompatible", "build-time-refusal-naming-command-and-target"],
      ["position-limit", "invocation.position_limit", 4],
      ["positions", "invocation.positions", "declaration-order-Text-values"],
      ["option-limit", "invocation.option_limit", 8],
      ["options", "invocation.options", "declaration-order-tagged-Bool-or-Text-values"],
      ["raw-argv", "invocation.raw_argv_access", false],
      ["result-carrier", "result.carrier", "CliActionResult-with-Ready-or-Revoked-context"],
      ["status-min", "result.status_min", 0],
      ["status-max", "result.status_max", 125],
      ["stdout-limit", "result.stdout_bytes", 65536],
      ["stderr-limit", "result.stderr_bytes", 65536],
      ["partial-output", "result.partial_output", false],
      ["authority-source", "authority.source", "explicit-CliActionContext-derived-from-RootAuthority"],
      ["ambient-host", "authority.ambient_host_access", false],
      ["fixed-actions", "compatibility.fixed_actions", "migrate-to-private-functions-on-the-same-ABI"],
      ["publication", "publication.link", "internal-static-code-image-composition"],
      ["final-toolchain", "publication.final_build_toolchain", "none"],
      ["claim-boundary", "claims_advance", false],
    ],
  },
  "live-https-get-adapter": {
    contract: "spec/live-https-get-adapter-v1/contract.json",
    document: "spec/live-https-get-adapter-v1/PROFILE.md",
    option: "A-explicit-Network-plus-TlsProvider",
    properties: [
      ["backend", "target.backend", "c11-stage2"],
      ["release-target", "target.release", "linux-x86_64"],
      ["unsupported-targets", "target.others", "refuse-before-artifact-publication"],
      ["method", "request.method", "GET-only"],
      ["scheme", "request.scheme", "https-only"],
      ["success-status", "request.success_status", "200-only"],
      ["redirect-policy", "request.redirect_policy", "caller-origin-allowlist-max-five"],
      ["http-core", "composition.http", "accepted-HTTP-1.1-core"],
      ["network", "composition.network", "explicit-affine-Network-authority"],
      ["tls", "composition.tls", "pinned-independently-versioned-TlsProvider"],
      ["roots", "composition.roots", "explicit-digested-root-bundle-authority"],
      ["libcurl", "composition.libcurl", false],
      ["dns-limit", "limits.dns_answers", 16],
      ["connect-limit", "limits.connect_attempts", 4],
      ["redirect-limit", "limits.redirect_hops", 5],
      ["header-limit", "limits.header_bytes", 65536],
      ["body-limit", "limits.body_bytes", 67108864],
      ["chunk-limit", "limits.chunk_bytes", 65536],
      ["total-deadline", "limits.total_deadline_seconds", 300],
      ["idle-deadline", "limits.idle_deadline_seconds", 30],
      ["peer-policy", "security.peer_policy", "authorize-DNS-answer-and-connected-peer-each-hop"],
      ["ambient-host", "security.ambient_proxy_credentials_roots", false],
      ["verification", "security.hostname_and_chain_verification", "mandatory-no-insecure-fallback"],
      ["cancellation", "cancellation", "explicit-authority-checked-at-DNS-connect-TLS-headers-and-each-body-read"],
      ["output", "output", "owned-bounded-Bytes-chunks-with-complete-metadata"],
      ["claim-boundary", "claims_advance", false],
    ],
  },
  "atomic-publish-if-absent": {
    contract: "spec/atomic-publish-if-absent-v1/contract.json",
    document: "spec/atomic-publish-if-absent-v1/PROFILE.md",
    option: "A-linux-renameat2-noreplace",
    properties: [
      ["backend", "target.backend", "c11-stage2"],
      ["release-target", "target.release", "linux-x86_64"],
      ["unsupported-targets", "target.others", "refuse-before-publication"],
      ["syscall", "operation.syscall", "renameat2"],
      ["flag", "operation.flags", "RENAME_NOREPLACE"],
      ["directory", "operation.directory", "one-preopened-admitted-directory"],
      ["temporary", "operation.temporary", "caller-verified-synced-regular-file-handle"],
      ["basename-limit", "operation.basename_bytes", 255],
      ["filesystem", "filesystem.policy", "ext4-xfs-btrfs-tmpfs-only"],
      ["same-directory", "filesystem.same_directory_and_device", true],
      ["symlink", "filesystem.symlink_target", "AlreadyExists-without-follow"],
      ["fallback", "filesystem.fallback", "none"],
      ["cross-device", "filesystem.cross_device", "typed-refusal-with-temporary-returned"],
      ["preflight-cancel", "cancellation.preflight", "explicit-cancellation-returns-temporary"],
      ["post-entry-cancel", "cancellation.after_syscall_entry", "unreachable-no-ambiguous-cancelled-outcome"],
      ["published", "outcomes.published", "temporary-consumed-final-entry-created-once"],
      ["already-exists", "outcomes.already_exists", "temporary-returned-existing-entry-untouched"],
      ["postcommit", "outcomes.postcommit_sync_failure", "CommittedDurabilityUnknown-temporary-consumed"],
      ["authority-return", "authority.return", "Ready-or-Revoked-on-every-outcome"],
      ["ambient-path", "authority.ambient_path_access", false],
      ["claim-boundary", "claims_advance", false],
    ],
  },
};

function fail(message) {
  throw new Error(message);
}

function at(value, path) {
  return path.split(".").reduce((current, part) => {
    if (part === "length") return current?.length;
    return current?.[part];
  }, value);
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function validate(contract, definition) {
  const failures = [];
  if (contract.schema !== `kofun.${definition.contract.split("/").at(-2)}/v1`) {
    failures.push("schema");
  }
  if (contract.selected_option !== definition.option) failures.push("selected-option");
  for (const [name, path, expected] of definition.properties) {
    if (!same(at(contract, path), expected)) failures.push(name);
  }
  return failures;
}

function damage(value) {
  if (typeof value === "boolean") return !value;
  if (typeof value === "number") return value + 1;
  if (typeof value === "string") return `${value}-mutated`;
  fail(`cannot damage ${JSON.stringify(value)}`);
}

function setAt(root, path, replacement) {
  const parts = path.split(".");
  let current = root;
  for (const part of parts.slice(0, -1)) current = current[part];
  const last = parts.at(-1);
  if (last === "length") {
    current.pop();
  } else {
    current[last] = replacement;
  }
}

function main(argv) {
  if (argv.length !== 1 || !(argv[0] in PROFILES)) {
    fail(`usage: node spec/decision-profiles-v1/check.mjs ${Object.keys(PROFILES).join("|")}`);
  }
  const requested = argv[0];
  const definition = PROFILES[requested];
  const contract = JSON.parse(readFileSync(join(ROOT, definition.contract), "utf8"));
  const document = readFileSync(join(ROOT, definition.document), "utf8");

  const baseline = validate(contract, definition);
  if (baseline.length !== 0) fail(`committed contract fails: ${baseline.join(", ")}`);
  if (!document.includes(contract.schema) || !document.includes(`Option ${definition.option[0]}`)) {
    fail(`${definition.document} does not name ${contract.schema} and Option ${definition.option[0]}`);
  }
  if (!document.includes(`Issue #${contract.issue}`)) {
    fail(`${definition.document} does not name Issue #${contract.issue}`);
  }

  const signatures = new Map();
  for (const [name, path] of definition.properties) {
    const copy = structuredClone(contract);
    const before = at(copy, path);
    setAt(copy, path, damage(before));
    const caught = validate(copy, definition);
    if (caught.length !== 1 || caught[0] !== name) {
      fail(`mutation ${name} was caught as ${caught.join(", ") || "nothing"}`);
    }
    const signature = caught.join(",");
    if (signatures.has(signature)) fail(`mutations ${signatures.get(signature)} and ${name} alias`);
    signatures.set(signature, name);
  }

  process.stdout.write(
    `PASS: ${requested} pins ${definition.properties.length} independently named decision properties\n`,
  );
  process.stdout.write(
    `PASS: ${definition.properties.length} one-property mutations each fail at its owning boundary\n`,
  );
  process.stdout.write("PASS: the decision advances no implementation capability or release claim\n");
}

try {
  main(process.argv.slice(2));
} catch (error) {
  process.stderr.write(`decision-profiles-v1: ${error.message}\n`);
  process.exit(1);
}

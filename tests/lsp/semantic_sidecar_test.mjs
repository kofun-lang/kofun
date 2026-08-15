import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { encodeTypedSidecar } from "../../tooling/typed-sidecar/codec.mjs";
import {
  analyzeDocument,
  byteToPosition,
  definitionAt,
  hoverAt,
  positionToByte,
  publishDiagnostics,
  semanticSnapshotFromBytes,
  shutdownSemanticAnalysis,
} from "../../tooling/lsp/semantic-sidecar.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const EXAMPLES = path.join(ROOT, "spec/typed-sidecar/examples");
const RESULTS = path.join(ROOT, "build/lsp/semantic-adapter-performance.json");

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function example(name, sourceText, generation) {
  const document = JSON.parse(fs.readFileSync(path.join(EXAMPLES, `${name}.json`)));
  const bytes = Buffer.from(sourceText, "utf8");
  document.file.byte_length = bytes.length;
  document.file.content_sha256 = sha256(bytes);
  document.generation.sequence = generation;
  const encoded = encodeTypedSidecar(document);
  assert.equal(encoded.ok, true, encoded.error?.message);
  return { document, bytes: Buffer.from(encoded.bytes) };
}

function metadata(sourceText, generation, overrides = {}) {
  return {
    uri: "file:///workspace/main.kofun",
    version: generation,
    generation,
    sessionEpoch: 1,
    logicalPath: "src/main.kofun",
    sourceText,
    ...overrides,
  };
}

function snapshot(input, bytes) {
  const result = semanticSnapshotFromBytes(input, bytes);
  assert.equal(result.ok, true, result.detail);
  return result.snapshot;
}

function milliseconds(start) {
  return Number(process.hrtime.bigint() - start) / 1e6;
}

function percentile(values, fraction) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

async function main() {
  // Exactly 80 UTF-8 bytes: ASCII + CRLF + BMP + astral + combining text.
  const unicodePrefix = "a\r\né😀e\u0301";
  const completeSource = unicodePrefix +
    "x".repeat(80 - Buffer.byteLength(unicodePrefix, "utf8"));
  assert.equal(Buffer.byteLength(completeSource, "utf8"), 80);
  const complete = example("complete", completeSource, 7);
  const completeMetadata = metadata(completeSource, 7);
  const completeSnapshot = snapshot(completeMetadata, complete.bytes);
  assert.equal(Object.isFrozen(completeSnapshot), true);
  assert.deepEqual(publishDiagnostics(completeSnapshot), []);

  assert.equal(positionToByte(completeSnapshot, { line: 0, character: 1 }), 1);
  assert.equal(byteToPosition(completeSnapshot, 2), null,
    "the middle of CRLF is not an LSP location");
  assert.equal(positionToByte(completeSnapshot, { line: 1, character: 1 }), 5);
  assert.equal(positionToByte(completeSnapshot, { line: 1, character: 2 }), null,
    "a UTF-16 position inside an astral scalar is rejected");
  assert.equal(positionToByte(completeSnapshot, { line: 1, character: 3 }), 9);
  assert.equal(positionToByte(completeSnapshot, { line: 1, character: 5 }), 12);
  assert.equal(byteToPosition(completeSnapshot, 6), null,
    "a byte inside an astral UTF-8 sequence is rejected");
  assert.equal(byteToPosition(completeSnapshot, 11), null,
    "a byte inside a combining scalar is rejected");
  assert.deepEqual(byteToPosition(completeSnapshot, 12), { line: 1, character: 5 });

  const referencePosition = byteToPosition(completeSnapshot, 61);
  const completeHover = hoverAt(completeSnapshot, referencePosition);
  assert.match(completeHover.contents.value, /type: MaybeInt/);
  assert.doesNotMatch(completeHover.contents.value, /last move:/,
    "a binding without a linked move diagnostic gained a move line");
  const completeDefinition = definitionAt(completeSnapshot, referencePosition);
  assert.deepEqual(completeDefinition.range, {
    start: byteToPosition(completeSnapshot, 30),
    end: byteToPosition(completeSnapshot, 35),
  });

  // All five freshness dimensions fail closed before a SemanticSnapshot exists.
  assert.equal(semanticSnapshotFromBytes(
    metadata(completeSource, 8), complete.bytes).ok, false);
  assert.equal(semanticSnapshotFromBytes(
    metadata(`${completeSource.slice(0, -1)}y`, 7), complete.bytes).ok, false);
  assert.equal(semanticSnapshotFromBytes(
    metadata(completeSource, 7, { logicalPath: "src/other.kofun" }), complete.bytes).ok, false);
  assert.equal(semanticSnapshotFromBytes(metadata(completeSource, 7, {
    expectedFileId: "0".repeat(64),
  }), complete.bytes).ok, false);

  const duplicateKey = Buffer.from(
    '{"schema":"kofun.typed-sidecar/v1","schema":"kofun.typed-sidecar/v1"}\n',
  );
  assert.equal(semanticSnapshotFromBytes(completeMetadata, duplicateKey).ok, false);
  const wrongSchema = structuredClone(complete.document);
  wrongSchema.schema = "kofun.typed-sidecar/v2";
  assert.equal(semanticSnapshotFromBytes(
    completeMetadata, Buffer.from(`${JSON.stringify(wrongSchema)}\n`)).ok, false);
  assert.equal(semanticSnapshotFromBytes(
    completeMetadata, Buffer.alloc(16 * 1024 * 1024 + 1, 0x20)).ok, false);

  const partialSource = "x".repeat(20);
  const partial = example("partial", partialSource, 8);
  const partialSnapshot = snapshot(metadata(partialSource, 8), partial.bytes);
  const diagnostics = publishDiagnostics(partialSnapshot);
  assert.deepEqual(diagnostics.map((item) => item.code), ["E2S57"]);
  assert.deepEqual(diagnostics[0].data, {
    category: "name-resolution",
    templateId: "unresolved-name",
    remedyIds: ["remove-reference"],
    truncated: false,
  });
  const provisional = hoverAt(partialSnapshot, { line: 0, character: 10 });
  assert.match(provisional.contents.value, /type\\\.provisional/);
  assert.match(provisional.contents.value, /provisional/);
  assert.match(provisional.contents.value, /E2S57/);
  assert.equal(hoverAt(partialSnapshot, { line: 0, character: 5 }), null);
  assert.equal(hoverAt(partialSnapshot, { line: 0, character: 16 }), null);
  assert.equal(definitionAt(partialSnapshot, { line: 0, character: 5 }), null);
  assert.equal(definitionAt(partialSnapshot, { line: 0, character: 10 }), null,
    "a hidden target never navigates");

  const maliciousDocument = structuredClone(partial.document);
  maliciousDocument.nodes[2].type.display = "**owned** <script> `tick`";
  maliciousDocument.diagnostics[0].fallback_text = "unsafe\u0001fallback";
  const maliciousEncoded = encodeTypedSidecar(maliciousDocument);
  assert.equal(maliciousEncoded.ok, true, maliciousEncoded.error?.message);
  const maliciousSnapshot = snapshot(
    metadata(partialSource, 8), Buffer.from(maliciousEncoded.bytes));
  const maliciousHover = hoverAt(maliciousSnapshot, { line: 0, character: 10 });
  assert.doesNotMatch(maliciousHover.contents.value, /<script>/);
  assert.match(maliciousHover.contents.value, /\\\*\\\*owned\\\*\\\*/);
  assert.doesNotMatch(publishDiagnostics(maliciousSnapshot)[0].message, /\u0001/);

  const fixturePath = path.join(ROOT, "tests/typed-sidecar/fixtures/stage2_events.kofun");
  const fixtureSource = fs.readFileSync(fixturePath, "utf8");
  const before = new AbortController();
  before.abort();
  assert.equal((await analyzeDocument(metadata(fixtureSource, 40), before.signal)).cancelled, true);

  const during = new AbortController();
  const obsolete = analyzeDocument(metadata(fixtureSource, 41), during.signal);
  during.abort();
  assert.equal((await obsolete).cancelled, true);

  const afterCommit = await analyzeDocument(
    metadata(fixtureSource, 42, { cancelAfterCommit: true }),
    new AbortController().signal,
  );
  assert.equal(afterCommit.cancelled, true,
    "a producer result marked cancelled is never exposed");

  const recovered = await analyzeDocument(
    metadata(fixtureSource, 43), new AbortController().signal);
  assert.equal(recovered.ok, true, recovered.detail);
  assert.deepEqual(publishDiagnostics(recovered.snapshot), []);

  // The production compiler's use-after-move path, not a hand-built sidecar:
  // E2S123 owns the use span and carries the original `take` span as related
  // information. Hover must render that same validated location rather than
  // reconstructing one from the fallback diagnostic text.
  const moveFixturePath = path.join(
    ROOT, "tests/conformance/records/production_use_after_move.kofun");
  const moveSource = fs.readFileSync(moveFixturePath, "utf8");
  const moveResult = await analyzeDocument(metadata(moveSource, 44, {
    uri: "file:///workspace/use-after-move.kofun",
    logicalPath: "src/use-after-move.kofun",
  }), new AbortController().signal);
  assert.equal(moveResult.ok, true, moveResult.detail);
  const moveDiagnostics = publishDiagnostics(moveResult.snapshot);
  assert.equal(moveDiagnostics.length, 1);
  assert.equal(moveDiagnostics[0].code, "E2S123");
  assert.deepEqual(moveDiagnostics[0].range, {
    start: { line: 19, character: 11 },
    end: { line: 19, character: 16 },
  });
  assert.deepEqual(moveDiagnostics[0].relatedInformation, [{
    location: {
      uri: "file:///workspace/use-after-move.kofun",
      range: {
        start: { line: 18, character: 4 },
        end: { line: 18, character: 14 },
      },
    },
    message: "moved-by-take",
  }]);
  const moveHover = hoverAt(
    moveResult.snapshot, { line: 19, character: 12 });
  assert.deepEqual(moveHover.range, moveDiagnostics[0].range);
  assert.match(moveHover.contents.value,
    /last move: line 19, characters 5-15 \(moved-by-take\)/);

  const decodeMilliseconds = [];
  for (let sample = 0; sample < 120; sample += 1) {
    const start = process.hrtime.bigint();
    const result = semanticSnapshotFromBytes(completeMetadata, complete.bytes);
    decodeMilliseconds.push(milliseconds(start));
    assert.equal(result.ok, true);
  }
  const hoverMilliseconds = [];
  const definitionMilliseconds = [];
  for (let sample = 0; sample < 500; sample += 1) {
    let start = process.hrtime.bigint();
    assert.ok(hoverAt(completeSnapshot, referencePosition));
    hoverMilliseconds.push(milliseconds(start));
    start = process.hrtime.bigint();
    assert.ok(definitionAt(completeSnapshot, referencePosition));
    definitionMilliseconds.push(milliseconds(start));
  }
  const decodeP95Ms = percentile(decodeMilliseconds, 0.95);
  const hoverP95Ms = percentile(hoverMilliseconds, 0.95);
  const definitionP95Ms = percentile(definitionMilliseconds, 0.95);
  /*
   * decode/index is RECORDED, not asserted at its typical cost (#1471).
   *
   * It was `< 75`, and `tooling/machine-dependent/ledger.tsv` records four
   * observations of it in one day: 9.93, 16.77, 80.70, 92.14 ms. An 8x spread,
   * two failures, both inside `task verify` and neither reproducible when the
   * gate runs alone. A threshold that is meaningful at 9.93 and passing at
   * 92.14 does not exist, so asserting one decided how busy the machine was.
   *
   * The clock is not the variable, which is why this is not fixed by measuring
   * CPU time instead: `hover p95 < 2` three lines below reads the same clock
   * with 66x headroom and has never failed, and `DIAGNOSTIC_MAX_CPU_MS` in
   * tests/lsp/performance_test.js reads a CPU clock and failed anyway at
   * 148.91 against 145. Classify by margin, not by clock.
   *
   * 750 ms is a backstop, an order of magnitude above the worst observation,
   * so a decoder that regresses in its algorithm still fails while a decoder
   * competing for cache does not. The number itself continues to be written to
   * RESULTS and printed below on every run.
   */
  const DECODE_P95_REGRESSION_MS = 750;
  assert.ok(decodeP95Ms < DECODE_P95_REGRESSION_MS,
    `decode/index p95 ${decodeP95Ms.toFixed(2)}ms exceeds the ${DECODE_P95_REGRESSION_MS}ms ` +
    'regression backstop — this is an order of magnitude over the recorded range, ' +
    'so it is a decoder regression rather than a busy machine');
  assert.ok(hoverP95Ms < 2, `hover p95 ${hoverP95Ms.toFixed(2)}ms`);
  assert.ok(definitionP95Ms < 2, `definition p95 ${definitionP95Ms.toFixed(2)}ms`);

  let rssGrowthBytes = null;
  if (typeof global.gc === "function") {
    global.gc();
    const beforeRss = process.memoryUsage().rss;
    const snapshots = [];
    for (let index = 0; index < 100; index += 1) {
      snapshots.push(snapshot(metadata(completeSource, 7, {
        uri: `file:///workspace/fixture-${index}.kofun`,
        sessionEpoch: index + 2,
      }), complete.bytes));
    }
    global.gc();
    rssGrowthBytes = Math.max(0, process.memoryUsage().rss - beforeRss);
    assert.ok(rssGrowthBytes < 64 * 1024 * 1024,
      `100 snapshots grew RSS by ${rssGrowthBytes} bytes`);
    snapshots.length = 0;
  }

  fs.mkdirSync(path.dirname(RESULTS), { recursive: true });
  fs.writeFileSync(RESULTS, `${JSON.stringify({
    schemaVersion: 1,
    decodeIndexP95Ms: decodeP95Ms,
    hoverP95Ms,
    definitionP95Ms,
    hundredSnapshotRssGrowthBytes: rssGrowthBytes,
  }, null, 2)}\n`);

  await shutdownSemanticAnalysis();
  process.stdout.write(
    `PASS: semantic adapter guards/status/disclosure/UTF/cancellation; ` +
    `decode p95=${decodeP95Ms.toFixed(2)}ms (recorded, backstop ${DECODE_P95_REGRESSION_MS}ms), ` +
    `hover p95=${hoverP95Ms.toFixed(3)}ms (asserted <2ms), ` +
    `definition p95=${definitionP95Ms.toFixed(3)}ms (asserted <2ms), ` +
    `100-doc RSS=${rssGrowthBytes ?? "n/a"} bytes\n`,
  );
}

main().catch(async (caught) => {
  await shutdownSemanticAnalysis();
  process.stderr.write(`${caught.stack}\n`);
  process.exitCode = 1;
});

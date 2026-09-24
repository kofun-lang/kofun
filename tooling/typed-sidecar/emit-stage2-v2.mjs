#!/usr/bin/env node

// KSE2 counterpart of `emit-stage2.mjs`: validate one complete compiler
// capture transaction, then atomically publish its typed-sidecar v2
// projection. The transaction producer is
// `bootstrap/stage2/capture_events_producer.c` (#1225).

import fs from "node:fs";

import {
  STAGE2_SEMANTIC_EVENT_V2_LIMITS,
  emitStage2TypedSidecarV2,
} from "./from-stage2.mjs";

function stop(message) {
  process.stderr.write(`ETS03: ${message}\n`);
  process.exit(3);
}

if (process.argv.length !== 5) {
  stop("internal Stage 2 sidecar v2 emitter usage error");
}

const [, , eventPath, destination, sourcePath] = process.argv;
let stat;
try {
  stat = fs.statSync(eventPath);
} catch {
  stop("semantic event stream is unavailable");
}
if (!stat.isFile() || stat.size > STAGE2_SEMANTIC_EVENT_V2_LIMITS.streamBytes) {
  process.stderr.write("ETS04: semantic event stream exceeds the v2 byte cap\n");
  process.exit(3);
}

let eventBytes;
try {
  eventBytes = fs.readFileSync(eventPath);
} catch {
  stop("semantic event stream cannot be read");
}
const result = await emitStage2TypedSidecarV2(
  eventBytes,
  destination,
  { sourcePath },
);
if (!result.ok) {
  process.stderr.write(`${result.error.code}: ${result.error.message}\n`);
  process.exit(3);
}

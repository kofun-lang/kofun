#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Client } = require('./client');

function elapsedMilliseconds(start) {
  return Number(process.hrtime.bigint() - start) / 1e6;
}

function percentile(values, fraction) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

function residentBytes(pid) {
  if (process.platform !== 'linux') return null;
  const status = fs.readFileSync(`/proc/${pid}/status`, 'utf8');
  const match = /^VmRSS:\s+(\d+)\s+kB$/m.exec(status);
  return match ? Number(match[1]) * 1024 : null;
}

// CPU time the SERVER has actually spent running, in milliseconds.
//
// This is what the budgets assert on, and wall clock is what they used to
// assert on. Seven observations of the same unchanged assertion on this
// repository span 30.52 ms to 570.24 ms — a 12x spread — and the slowest was a
// standalone run while the fastest was CI, so the wall-clock number did not
// even order by load (#1379). It was measuring the machine.
//
// `process.cpuUsage()` cannot be used: it reports THIS process, and the work
// being measured happens in the language server child.
//
// The obvious source, utime+stime from /proc/<pid>/stat, is unusable here for a
// reason worth recording: it is counted in 10 ms clock ticks, and a single
// request costs a few milliseconds. Every per-request delta would quantise to 0
// or 10, and a p95 over such a set measures the quantiser. /proc/<pid>/task/*/
// schedstat reports nanoseconds — its first field is time spent ON the cpu,
// which excludes runqueue wait and is therefore exactly the load-independent
// quantity wanted. Summing over `task/*` rather than reading the process entry
// catches the server's worker threads, which node has seven of.
function cpuMilliseconds(pid) {
  if (process.platform !== 'linux') return null;
  let nanoseconds = 0;
  let threads;
  try {
    threads = fs.readdirSync(`/proc/${pid}/task`);
  } catch {
    return null;
  }
  for (const thread of threads) {
    let line;
    try {
      line = fs.readFileSync(`/proc/${pid}/task/${thread}/schedstat`, 'utf8');
    } catch {
      // A thread that exited between readdir and read contributes nothing.
      continue;
    }
    const onCpu = Number(line.split(' ')[0]);
    if (!Number.isFinite(onCpu)) return null;
    nanoseconds += onCpu;
  }
  return nanoseconds / 1e6;
}

// A request's own CPU cost. The harness issues requests serially and waits for
// each reply before sending the next, so the server's CPU delta across one
// request window is attributable to that request.
//
// This is summed across threads, so it can EXCEED the wall clock for the same
// request when the sidecar worker runs concurrently with the main thread -- at
// low load a diagnostic measured 82.73 ms of CPU against 67.10 ms of wall. That
// is not an error: the budget bounds total computation, not the interval a user
// waits. The two answer different questions, which is why both are recorded.
function cpuDelta(pid, before) {
  const after = cpuMilliseconds(pid);
  return after === null || before === null ? null : after - before;
}

// CPU budgets, in milliseconds of server on-cpu time per request.
//
// CALIBRATION, measured on this repository at 30f18e4d across three runs while
// the 1-minute load average climbed from 17.85 to 31.07. That range is
// deliberate: it is the condition the wall-clock budgets could not survive, so
// it is where a load-independent measure has to be shown to hold.
//
//   quantity                run 1    run 2    run 3   spread   budget
//   diagnostic p95          94.39    98.85    96.18    1.05x      130
//   diagnostic max          99.03   106.43   111.83    1.13x      145
//   definition p95           1.35     1.69     1.07    1.57x        4
//   hover p95                1.48     1.60     1.29    1.24x        4
//   cold completion p95     10.36    12.55    10.69    1.21x       18
//   warm completion p95      6.51     5.94     6.60    1.11x       10
//
// Wall clock over the same three runs, for contrast: 332.34, 795.28, 639.63 ms
// diagnostic p95 -- a 2.4x spread, and every one of them 3x to 8x over the
// 100 ms budget this replaces. The CPU number moved by 5%.
//
// Headroom is ~1.3x on the two diagnostic budgets, which carry the real cost
// and discriminate tightly. Definition and hover sit near 1.5 ms where ordinary
// jitter is a larger fraction, so their 4 ms is looser in ratio and still far
// below any plausible regression. A budget with 10x headroom would gate
// nothing, which is the failure mode of simply raising the old wall-clock
// numbers until they stopped flaking.
const DIAGNOSTIC_P95_CPU_MS = 130;
const DIAGNOSTIC_MAX_CPU_MS = 145;
const DEFINITION_P95_CPU_MS = 4;
const HOVER_P95_CPU_MS = 4;
const COMPLETION_COLD_P95_CPU_MS = 18;
const COMPLETION_WARM_P95_CPU_MS = 10;

function fnv1a64(text) {
  let hash = 0xcbf29ce484222325n;
  const bytes = Buffer.from(text, 'utf8');
  for (const byte of bytes) {
    hash ^= BigInt(byte);
    hash = BigInt.asUintN(64, hash * 0x100000001b3n);
  }
  return hash.toString(16).padStart(16, '0');
}

function generateSource(count) {
  const lines = ['fn huge(seed: Int) -> Int {'];
  for (let index = 0; index < count; index += 1) {
    const name = `value${String(index).padStart(5, '0')}`;
    const value = index === 0
      ? '0' : `value${String(index - 1).padStart(5, '0')}`;
    lines.push(`    let ${name}: Int = ${value}`);
  }
  lines.push(`    return value${String(count - 1).padStart(5, '0')}`);
  lines.push('}', '');
  return lines.join('\n');
}

async function main() {
  const server = path.resolve(process.argv[2] || 'tooling/lsp/kofun-lsp');
  const output = path.resolve(process.argv[3] || 'build/lsp/performance.json');
  const client = new Client(server);
  const uri = 'file:///workspace/generated-10000.kofun';
  const source = generateSource(10000);
  const lines = source.split('\n');
  let id = 1;
  let stopped = false;

  try {
  client.send({ jsonrpc: '2.0', id, method: 'initialize', params: {
    rootUri: 'file:///workspace',
    capabilities: { general: { positionEncodings: ['utf-16'] } }
  } });
  await client.waitFor((message) => message.id === id, 10000);
  id += 1;
  client.send({ jsonrpc: '2.0', method: 'initialized', params: {} });
  client.send({
    jsonrpc: '2.0', method: 'textDocument/didOpen',
    params: { textDocument: { uri, languageId: 'kofun', version: 1, text: source } }
  });
  const opened = await client.waitFor((message) =>
    message.method === 'textDocument/publishDiagnostics' &&
    message.params.version === 1, 10000);
  assert.deepStrictEqual(opened.params.diagnostics, []);

  const nearLine = 2;
  const farLine = 10000;
  const nearCharacter = lines[nearLine].lastIndexOf('0');
  const farCharacter = lines[farLine].lastIndexOf('8');

  // One unmeasured range edit warms the parser, index, and allocator.
  client.send({
    jsonrpc: '2.0', method: 'textDocument/didChange',
    params: {
      textDocument: { uri, version: 2 },
      contentChanges: [{
        range: {
          start: { line: nearLine, character: nearCharacter },
          end: { line: nearLine, character: nearCharacter + 1 }
        },
        text: '1'
      }]
    }
  });
  await client.waitFor((message) =>
    message.method === 'textDocument/publishDiagnostics' &&
    message.params.version === 2, 10000);
  // The baseline used to be sampled here, one edit in. At that point V8 has
  // not finished growing its heap, so the ratio below charged ordinary warm-up
  // allocation to "growth" — it measured 9.35% to 13.58% against a 10% budget
  // on an unmodified tree, i.e. the gate's verdict came from where in the
  // warm-up the sample happened to land rather than from the server's
  // behaviour (#713). Warm up first, then measure: growth across a steady
  // state is what actually distinguishes retention from start-up.
  const WARMUP_EDITS = 25;
  let firstRss = null;

  const diagnosticMs = [];
  const diagnosticCpuMs = [];
  let nearDigit = '1';
  let farDigit = '8';
  for (let edit = 0; edit < WARMUP_EDITS + 100; edit += 1) {
    const version = edit + 3;
    const near = edit % 2 === 0;
    let line;
    let character;
    let text;
    if (near) {
      nearDigit = nearDigit === '1' ? '0' : '1';
      line = nearLine;
      character = nearCharacter;
      text = nearDigit;
    } else {
      farDigit = farDigit === '8' ? '7' : '8';
      line = farLine;
      character = farCharacter;
      text = farDigit;
    }
    const startCpu = cpuMilliseconds(client.child.pid);
    const start = process.hrtime.bigint();
    client.send({
      jsonrpc: '2.0', method: 'textDocument/didChange',
      params: {
        textDocument: { uri, version },
        contentChanges: [{
          range: {
            start: { line, character },
            end: { line, character: character + 1 }
          },
          text
        }]
      }
    });
    const publication = await client.waitFor((message) =>
      message.method === 'textDocument/publishDiagnostics' &&
      message.params.version === version, 10000);
    // Warm-up edits are still asserted for correctness; they are only excluded
    // from the latency sample and from the growth baseline.
    if (edit >= WARMUP_EDITS) {
      diagnosticMs.push(elapsedMilliseconds(start));
      diagnosticCpuMs.push(cpuDelta(client.child.pid, startCpu));
    }
    assert.deepStrictEqual(publication.params.diagnostics, []);
    if (edit === WARMUP_EDITS - 1) {
      firstRss = residentBytes(client.child.pid);
    }
  }
  const lastRss = residentBytes(client.child.pid);

  const definitionMs = [];
  const definitionCpuMs = [];
  const hoverMs = [];
  const hoverCpuMs = [];
  const nearReferenceCharacter = lines[nearLine].lastIndexOf('value');
  const farReferenceCharacter = lines[farLine].lastIndexOf('value');
  for (let request = 0; request < 100; request += 1) {
    const position = request % 2 === 0
      ? { line: nearLine, character: nearReferenceCharacter }
      : { line: farLine, character: farReferenceCharacter };
    let startCpu = cpuMilliseconds(client.child.pid);
    let start = process.hrtime.bigint();
    client.send({
      jsonrpc: '2.0', id, method: 'textDocument/definition',
      params: { textDocument: { uri }, position }
    });
    const definition = await client.waitFor((message) => message.id === id, 10000);
    id += 1;
    definitionMs.push(elapsedMilliseconds(start));
    definitionCpuMs.push(cpuDelta(client.child.pid, startCpu));
    assert.ok(definition.result && definition.result.uri === uri);

    startCpu = cpuMilliseconds(client.child.pid);
    start = process.hrtime.bigint();
    client.send({
      jsonrpc: '2.0', id, method: 'textDocument/hover',
      params: { textDocument: { uri }, position }
    });
    const hover = await client.waitFor((message) => message.id === id, 10000);
    id += 1;
    hoverMs.push(elapsedMilliseconds(start));
    hoverCpuMs.push(cpuDelta(client.child.pid, startCpu));
    assert.ok(hover.result && /: Int/.test(hover.result.contents.value));
  }

  // Completion is the only request that has to build the lexical index, which
  // the semantic path never builds otherwise. Measuring only a cached request
  // would hide that cost, so each sample edits first and times the rebuild.
  const completionColdMs = [];
  const completionColdCpuMs = [];
  const completionWarmMs = [];
  const completionWarmCpuMs = [];
  // Sampled at the far end of the file, where the whole scope's 9,999 earlier
  // bindings are visible and the bound actually applies.
  const completionCharacter = lines[farLine].indexOf('let') + 4;
  let coldDigit = '1';
  for (let sample = 0; sample < 25; sample += 1) {
    const version = WARMUP_EDITS + 103 + sample;
    coldDigit = coldDigit === '1' ? '0' : '1';
    client.send({
      jsonrpc: '2.0', method: 'textDocument/didChange',
      params: {
        textDocument: { uri, version },
        contentChanges: [{
          range: {
            start: { line: nearLine, character: nearCharacter },
            end: { line: nearLine, character: nearCharacter + 1 }
          },
          text: coldDigit
        }]
      }
    });
    await client.waitFor((message) =>
      message.method === 'textDocument/publishDiagnostics' &&
      message.params.version === version, 10000);

    const position = { line: farLine, character: completionCharacter };
    let startCpu = cpuMilliseconds(client.child.pid);
    let start = process.hrtime.bigint();
    client.send({
      jsonrpc: '2.0', id, method: 'textDocument/completion',
      params: { textDocument: { uri }, position }
    });
    const cold = await client.waitFor((message) => message.id === id, 10000);
    id += 1;
    completionColdMs.push(elapsedMilliseconds(start));
    completionColdCpuMs.push(cpuDelta(client.child.pid, startCpu));
    // The corpus declares 10,000 bindings in one scope, so the bound applies
    // and the reply must say it is incomplete.
    assert.ok(cold.result.items.length <= 200);
    assert.strictEqual(cold.result.isIncomplete, true);
    assert.ok(cold.result.items.some((item) => item.label === 'print'));

    startCpu = cpuMilliseconds(client.child.pid);
    start = process.hrtime.bigint();
    client.send({
      jsonrpc: '2.0', id, method: 'textDocument/completion',
      params: { textDocument: { uri }, position }
    });
    await client.waitFor((message) => message.id === id, 10000);
    id += 1;
    completionWarmMs.push(elapsedMilliseconds(start));
    completionWarmCpuMs.push(cpuDelta(client.child.pid, startCpu));
  }

  const metrics = {
    schemaVersion: 1,
    serverRevision: process.env.KOFUN_LSP_REVISION || 'working-tree',
    machine: {
      platform: `${os.platform()} ${os.release()} ${os.arch()}`,
      cpu: os.cpus()[0] ? os.cpus()[0].model : 'unknown',
      node: process.version
    },
    corpus: {
      declarations: 10000,
      utf8Bytes: Buffer.byteLength(source),
      digest: `fnv1a64:${fnv1a64(source)}`
    },
    memoryBytes: { afterWarmup: firstRss, afterEdit100: lastRss },
    // Recorded so an outlier is attributable after the fact rather than argued
    // about. The seven observations that motivated #1379 span 30.52ms to
    // 570.24ms of wall clock on unchanged code, and not one of them carries the
    // load it was taken under -- which is why it took four separate sessions to
    // establish that load did not even order them. A number without its
    // conditions cannot be compared with a later number.
    loadAverage: os.loadavg(),
    diagnosticMs,
    definitionMs,
    hoverMs,
    completionColdMs,
    completionWarmMs,
    diagnosticCpuMs,
    definitionCpuMs,
    hoverCpuMs,
    completionColdCpuMs,
    completionWarmCpuMs,
    summary: {
      // Wall clock stays recorded, and stays comparable across hosts. It just
      // no longer decides whether `verify` passes (#1379).
      diagnosticP95Ms: percentile(diagnosticMs, 0.95),
      diagnosticMaxMs: Math.max(...diagnosticMs),
      definitionP95Ms: percentile(definitionMs, 0.95),
      hoverP95Ms: percentile(hoverMs, 0.95),
      completionColdP95Ms: percentile(completionColdMs, 0.95),
      completionWarmP95Ms: percentile(completionWarmMs, 0.95),
      // CPU time is what the budgets below assert on.
      diagnosticP95CpuMs: percentile(diagnosticCpuMs, 0.95),
      diagnosticMaxCpuMs: Math.max(...diagnosticCpuMs),
      definitionP95CpuMs: percentile(definitionCpuMs, 0.95),
      hoverP95CpuMs: percentile(hoverCpuMs, 0.95),
      completionColdP95CpuMs: percentile(completionColdCpuMs, 0.95),
      completionWarmP95CpuMs: percentile(completionWarmCpuMs, 0.95),
      residentGrowthRatio: firstRss === null || lastRss === null
        ? null : (lastRss - firstRss) / firstRss
    }
  };

  // Keep raw evidence even when a host-dependent budget assertion fails.
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, `${JSON.stringify(metrics, null, 2)}\n`);

  // CPU sampling is REQUIRED, not optional. Degrading to "skip the budget when
  // /proc is unreadable" would produce a passing run that asserted nothing
  // about latency, which is the success-producing skip this repository already
  // has too many of. A host that cannot measure the server's CPU time cannot
  // run this gate, and says so.
  assert.ok(process.platform === 'linux',
    'LSP performance budget: CPU-time measurement requires Linux ' +
    `/proc/<pid>/task/*/schedstat; this host is ${process.platform}`);
  for (const [name, samples] of [
    ['diagnostic', diagnosticCpuMs], ['definition', definitionCpuMs],
    ['hover', hoverCpuMs], ['cold completion', completionColdCpuMs],
    ['warm completion', completionWarmCpuMs]
  ]) {
    assert.ok(samples.length > 0 && samples.every((value) => value !== null),
      `LSP performance budget: ${name} CPU samples are missing. ` +
      '/proc/<pid>/task/*/schedstat could not be read for the server; ' +
      'a kernel built without CONFIG_SCHEDSTATS cannot run this gate.');
    // Every sample zero means the clock is not advancing, which reads as
    // "infinitely fast" and would pass every budget. Refuse instead.
    assert.ok(samples.some((value) => value > 0),
      `LSP performance budget: every ${name} CPU sample is zero; ` +
      'schedstat is present but not counting, so the budget would assert nothing.');
  }

  // Budgets are CPU time attributable to the server, not wall clock (#1379).
  // Wall clock on this repository spanned 30.52ms to 570.24ms for the same
  // unchanged assertion across seven observations, and did not order by load,
  // so it was measuring the host. These are anchored on the environment that
  // actually gates merges.
  for (const [name, measured, budget] of [
    ['diagnostic p95', metrics.summary.diagnosticP95CpuMs, DIAGNOSTIC_P95_CPU_MS],
    ['diagnostic max', metrics.summary.diagnosticMaxCpuMs, DIAGNOSTIC_MAX_CPU_MS],
    ['definition p95', metrics.summary.definitionP95CpuMs, DEFINITION_P95_CPU_MS],
    ['hover p95', metrics.summary.hoverP95CpuMs, HOVER_P95_CPU_MS],
    ['cold completion p95', metrics.summary.completionColdP95CpuMs, COMPLETION_COLD_P95_CPU_MS],
    ['warm completion p95', metrics.summary.completionWarmP95CpuMs, COMPLETION_WARM_P95_CPU_MS]
  ]) {
    assert.ok(measured <= budget,
      `LSP performance budget: ${name} ${measured.toFixed(2)}ms of CPU ` +
      `exceeds ${budget}ms (wall clock for this run is in ${output}; ` +
      'wall clock is recorded evidence and is not asserted)');
  }
  if (metrics.summary.residentGrowthRatio !== null) {
    assert.ok(metrics.summary.residentGrowthRatio < 0.10,
      `resident growth ${(metrics.summary.residentGrowthRatio * 100).toFixed(2)}% is not below 10%`);
  }

  await client.stop(id);
  stopped = true;
  process.stdout.write(
    `PASS: LSP performance budget, 10k declarations. CPU (asserted): ` +
    `diagnostics p95=${metrics.summary.diagnosticP95CpuMs.toFixed(2)}ms ` +
    `max=${metrics.summary.diagnosticMaxCpuMs.toFixed(2)}ms, ` +
    `definition p95=${metrics.summary.definitionP95CpuMs.toFixed(2)}ms, ` +
    `hover p95=${metrics.summary.hoverP95CpuMs.toFixed(2)}ms, ` +
    `completion p95 cold=${metrics.summary.completionColdP95CpuMs.toFixed(2)}ms ` +
    `warm=${metrics.summary.completionWarmP95CpuMs.toFixed(2)}ms. ` +
    `Wall clock (recorded, not asserted): ` +
    `diagnostics p95=${metrics.summary.diagnosticP95Ms.toFixed(2)}ms ` +
    `max=${metrics.summary.diagnosticMaxMs.toFixed(2)}ms, ` +
    `definition p95=${metrics.summary.definitionP95Ms.toFixed(2)}ms, ` +
    `hover p95=${metrics.summary.hoverP95Ms.toFixed(2)}ms, ` +
    `completion p95 cold=${metrics.summary.completionColdP95Ms.toFixed(2)}ms ` +
    `warm=${metrics.summary.completionWarmP95Ms.toFixed(2)}ms, ` +
    `RSS growth=${metrics.summary.residentGrowthRatio === null ? 'n/a' :
      `${(metrics.summary.residentGrowthRatio * 100).toFixed(2)}%`}\n`
  );
  process.stdout.write(`raw measurements: ${output}\n`);
  } finally {
    if (!stopped && client.child.exitCode === null) client.child.kill('SIGTERM');
  }
}

main().catch((caught) => {
  process.stderr.write(`${caught.stack}\n`);
  process.exitCode = 1;
});

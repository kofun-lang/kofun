// Test-only independent corpus/oracle. Production serialization is Kofun.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {STAGE2_REPORT_FIELDS} from '../../../spec/benchmark-report-v1/contract.mjs';
import {decodeReport, encodeReport, toStage2Outcome, stage2ErrorOutcome, summarize, outlierFlags} from '../../../spec/benchmark-report-v1/model.mjs';
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const POSITIVE = path.join(ROOT, 'spec/benchmark-report-v1/vectors/positive');
function replaceOnce(bytes, search, replacement, label) {
  const needle = Buffer.from(search, "utf8");
  const first = bytes.indexOf(needle);
  assert.notEqual(first, -1, `${label}: search bytes are absent`);
  assert.equal(bytes.indexOf(needle, first + needle.length), -1, `${label}: search bytes are not unique`);
  return Buffer.concat([bytes.subarray(0, first), replacement, bytes.subarray(first + needle.length)]);
}

function materializeNegative(vector) {
  const basePath = path.join(POSITIVE, vector.base);
  const bytes = fs.readFileSync(basePath);
  if (vector.operation === "prepend-hex") {
    return Buffer.concat([Buffer.from(vector.hex, "hex"), bytes]);
  }
  if (vector.operation === "append-hex") {
    return Buffer.concat([bytes, Buffer.from(vector.hex, "hex")]);
  }
  if (vector.operation === "replace-hex") {
    return replaceOnce(bytes, vector.search, Buffer.from(vector.hex, "hex"), vector.name);
  }
  if (vector.operation === "replace") {
    return replaceOnce(bytes, vector.search, Buffer.from(vector.replacement, "utf8"), vector.name);
  }
  if (vector.operation === "truncate") {
    assert.ok(vector.count > 0 && vector.count < bytes.length, `${vector.name}: invalid truncation`);
    return bytes.subarray(0, bytes.length - vector.count);
  }
  if (vector.operation === "insert-before-root-close") {
    assert.ok(bytes.subarray(-2).equals(Buffer.from("}\n")), `${vector.name}: base has no canonical root close`);
    return Buffer.concat([
      bytes.subarray(0, -2),
      Buffer.from(vector.replacement, "utf8"),
      Buffer.from("}\n"),
    ]);
  }
  if (vector.operation === "repeat-replacement") {
    const replacement = `${vector.prefix}${vector.unit.repeat(vector.count)}${vector.suffix}`;
    return replaceOnce(bytes, vector.search, Buffer.from(replacement, "utf8"), vector.name);
  }
  if (vector.operation === "insert-nested-unknown") {
    assert.ok(Number.isInteger(vector.depth) && vector.depth > 0, `${vector.name}: invalid depth`);
    assert.ok(bytes.subarray(-2).equals(Buffer.from("}\n")), `${vector.name}: base has no canonical root close`);
    const nested = `${"[".repeat(vector.depth)}0${"]".repeat(vector.depth)}`;
    return Buffer.concat([
      bytes.subarray(0, -2),
      Buffer.from(`,"future":${nested}}\n`, "utf8"),
    ]);
  }
  assert.fail(`${vector.name}: unknown operation ${vector.operation}`);
}

function snapshot(outcome) {
  return STAGE2_REPORT_FIELDS.map(({name, type}) => {
    let value = outcome[name];
    if (type === 'Text') value = Buffer.from(value).toString('hex');
    if (type === 'Bool') value = Number(value);
    if (type === 'List[Int]') value = value.join(',');
    return `${name} ${value}\n`;
  }).join('');
}

function fieldsHeader() {
  const statements = STAGE2_REPORT_FIELDS.map(({name, type}) => {
    const field = `report.f_${name}`;
    const prefix = `    printf("${name} ");`;
    if (type === 'Text') return `${prefix}
    for (const unsigned char *p = (const unsigned char *)${field}; *p; ++p) printf("%02x", (unsigned)*p);
    putchar('\\n');`;
    if (type === 'List[Int]') return `${prefix}
    for (uint64_t i = 0; i < ${field}.length; ++i) {
        if (i) putchar(',');
        printf("%" PRId64, ${field}.elements[i]);
    }
    putchar('\\n');`;
    return `${prefix} printf("%" PRId64 "\\n", (int64_t)${field});`;
  });
  return `static void print_fields(KofunRecord_BenchReport report) {\n${statements.join('\n')}\n}\n`;
}

function prepare(work) {
  fs.mkdirSync(path.join(work, 'vectors'), {recursive: true});
  const cases = [];
  function add(name, input, expected) {
    const bytes = Buffer.from(input);
    let outcome;
    try { outcome = toStage2Outcome(decodeReport(bytes)); }
    catch (error) {
      assert.match(error.code ?? '', /^BR\d{3}$/, `${name}: oracle failed unexpectedly`);
      outcome = stage2ErrorOutcome(error.code);
    }
    if (expected !== undefined) assert.equal(outcome.status_tag, expected, `${name}: frozen status`);
    fs.writeFileSync(path.join(work, 'vectors', `${name}.json`), bytes);
    fs.writeFileSync(path.join(work, 'vectors', `${name}.expected`), snapshot(outcome));
    cases.push({name, status: outcome.status_tag});
  }
  for (const name of ['minimal', 'typical', 'maximum']) {
    const bytes = fs.readFileSync(path.join(POSITIVE, `${name}.json`));
    if (name === 'maximum') assert.ok(bytes.length > 4096, 'maximum must exceed 4 KiB');
    add(name, bytes, 0);
  }
  const negatives = JSON.parse(fs.readFileSync(path.join(ROOT, 'spec/benchmark-report-v1/vectors/negative.json'))).vectors;
  assert.equal(negatives.length, 44);
  for (const vector of negatives) {
    const bytes = materializeNegative(vector);
    assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), vector.sha256, vector.name);
    add(vector.name, bytes, Number(vector.error.slice(2)));
  }
  const extra = [
    ['near-wire-depth', '['.repeat(8000) + '0' + ']'.repeat(8000), 4],
    ['deep-incomplete', '['.repeat(8000) + '0' + ']'.repeat(7999), 1],
    ['duplicate-depth', '{"x":0,"x":1,"a":' + '['.repeat(17) + '0' + ']'.repeat(17) + '}', 4],
    ['duplicate-syntax', '{"x":0,"x":1,}', 1],
    ['quote-key-escape', '{"\\\"":0,"\\u0022":1}', 2],
    ['astral-key-escape', '{"😀":0,"\\ud83d\\ude00":1}', 2],
    ['array-trailing-comma', '[1,]', 1],
    ['empty', '', 1],
    ['invalid-escape', '"\\q"', 1],
    ['non-json-space', '\u00a0{}', 1],
    ['over-wire-malformed', '!'.repeat(16385), 4],
    ['missing-colon', '{"a" 1}', 1],
    ['incomplete-exponent', '[1e]', 1],
    ['incomplete-fraction', '[1.]', 1],
    ['literal-typo', '[tru]', 1],
    ['incomplete-unicode', '["\\u00"]', 1],
    ['root-null', 'null', 3],
    ['root-empty-object', '{}', 3],
    ['null-typo', 'nulx', 1],
    ['depth-boundary', '{"future":' + '['.repeat(16) + '0' + ']'.repeat(16) + '}', 3],
  ];
  for (const [name, bytes, status] of extra) add(name, bytes, status);
  const base = JSON.parse(fs.readFileSync(path.join(POSITIVE, 'minimal.json')));
  const minimalBytes = fs.readFileSync(path.join(POSITIVE, 'minimal.json'), 'utf8');
  const unicode = structuredClone(base);
  unicode.identity.parameter = 'cafe\u0301-😀/\\"';
  unicode.host.cpu = '矢印→';
  unicode.host.noise = '\tline\nend\r';
  const unicodeBytes = encodeReport(unicode);
  add('decomposed-unicode-controls', unicodeBytes, 0);
  add('noncanonical-surrogate-pair', unicodeBytes.toString().replace('😀', '\\ud83d\\ude00'), 2);
  add('noncanonical-slash', unicodeBytes.toString().replace('😀/', '😀\\/'), 2);
  for (const [name, mutate, status] of [
    ['identity-over-bound', value => { value.identity.suite = 'x'.repeat(97); }, 4],
    ['host-over-bound', value => { value.host.cpu = 'x'.repeat(129); }, 4],
    ['noise-over-bound', value => { value.host.noise = 'x'.repeat(256); }, 4],
    ['noise-control', value => { value.host.noise = '\u0001'; }, 5],
    ['digest-wrong-type', value => { value.digests.toolchain_sha256 = true; }, 5],
    ['digest-short', value => { value.digests.toolchain_sha256 = '0'; }, 5],
    ['integer-wrong-type', value => { value.budget.sample_cap = true; }, 3],
  ]) {
    const value = structuredClone(base);
    mutate(value);
    add(name, JSON.stringify(value) + '\n', status);
  }
  for (const [name, number, status] of [
    ['number-zero-exponent', '0e9999', 2],
    ['number-large-exponent', '1e9999', 4],
    ['number-underflow', '1e-400', 3],
    ['number-negative-underflow', '-1e-400', 3],
    ['number-rounded-fraction', '1.00000000000000001', 3],
    ['number-rounded-large-fraction', '9007199254740990.9', 3],
    ['number-integral-fraction', '0.0', 2],
    ['number-negative-zero', '-0', 2],
  ]) add(name, minimalBytes.replace('"samples":[0]', `"samples":[${number}]`), status);
  add('semantic-before-canonical', ' ' + JSON.stringify({...base, schema: 'wrong'}) + '\n', 3);
  const flagged = structuredClone(base);
  flagged.samples = [0, 0, 0, 100];
  flagged.outliers = outlierFlags(flagged.samples);
  flagged.summary = summarize(flagged.samples);
  flagged.budget.sample_cap = 4;
  flagged.measurement.sample_count = 4;
  assert.equal(flagged.outliers[3], true);
  add('positive-outlier', encodeReport(flagged), 0);
  for (let count = 1; count <= 100; ++count) {
    const report = structuredClone(base);
    report.samples = Array.from({length: count}, (_, i) => (i * 37 + count * 13) % 997);
    report.outliers = outlierFlags(report.samples);
    report.summary = summarize(report.samples);
    report.budget.sample_cap = count;
    report.measurement.sample_count = count;
    add(`samples-${count}`, encodeReport(report), 0);
  }
  fs.writeFileSync(path.join(work, 'cases.json'), JSON.stringify(cases));
  fs.writeFileSync(path.join(work, 'fields.h'), fieldsHeader());
  fs.writeFileSync(path.join(work, 'main.kofun'), `
fn main() -> Int {
    let input = stage2_bytes_empty()
    let output = stage2_bytes_empty()
    stage2_bytes_read_file(input, ${JSON.stringify(path.join(work, 'vectors/minimal.json'))})
    let report: BenchReport = decode_report(input)
    print(report.status_tag)
    print(encode_report(report, output))
    print(stage2_bytes_len(output))
    print(codec_matches(input, 0, output))
    return 0
}
`);
}

function check(work, binary, faults) {
  const cases = JSON.parse(fs.readFileSync(path.join(work, 'cases.json')));
  function run(operation, name, ...args) {
    const result = spawnSync(binary, [operation, path.join(work, 'vectors', `${name}.json`), ...args.map(String)],
      {encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024});
    assert.equal(result.error, undefined, `${operation}/${name}: ${result.error}`);
    assert.equal(result.status, 0, `${operation}/${name}: ${result.stderr}`);
    assert.equal(result.stderr, '', `${operation}/${name}: unexpected diagnostic`);
    return result.stdout;
  }
  for (const {name, status} of cases) {
    assert.equal(run('decode', name), fs.readFileSync(path.join(work, 'vectors', `${name}.expected`), 'utf8'), `${name}: all 49 fields`);
    if (status === 0) {
      const output = run('roundtrip', name);
      assert.match(output, /^status 0\nallocations \d+\n/);
      const bytes = output.replace(/^status 0\nallocations \d+\n/, '');
      assert.equal(bytes, fs.readFileSync(path.join(work, 'vectors', `${name}.json`), 'utf8'), `${name}: canonical bytes`);
    }
  }
  if (faults) {
    let encodeFaults = 0;
    let decodeFaults = 0;
    for (const name of ['minimal', 'typical', 'maximum']) {
      const length = fs.statSync(path.join(work, 'vectors', `${name}.json`)).size;
      assert.equal(run('repeat', name), fs.readFileSync(path.join(work, 'vectors', `${name}.expected`), 'utf8'), `${name}: 128 calls preserve bytes and report fields`);
      for (const seed of [0, 3, length, 32768]) {
        const baseline = run('encode-oom', name, -1, seed);
        const count = Number(baseline.match(/allocations (\d+)/)[1]);
        assert.match(baseline, /^status 0\n/);
        assert.ok(count > 0, `${name}: allocation injection must be exercised`);
        for (let fail = 1; fail <= count; ++fail) {
          assert.match(run('encode-oom', name, fail, seed), /^status 12\n/, `encode allocation ${fail}/${count}, seed ${seed}`);
          ++encodeFaults;
        }
        for (let status = 1; status <= 12; ++status) {
          assert.equal(run('outcome', name, status, seed), `status ${status}\nallocations 0\n`, `prior BR${status}`);
        }
        // A forged status-0 model is rechecked by #1311's producer, whose
        // segment_values_status classifies a negative sample as BR004. The
        // separately pinned wire-negative vector remains the decoder's BR006.
        for (const [mutation, status] of [4, 5, 5, 3, 6, 6, 3, 4, 4].entries()) {
          assert.match(run('invalid', name, mutation, seed), new RegExp(`^status ${status}\\n`), `invalid model ${mutation}, seed ${seed}`);
        }
      }
      const baseline = run('decode-oom', name, -1);
      const count = Number(baseline.match(/allocations (\d+)\n$/)[1]);
      assert.ok(count > 0, `${name}: decoder allocation injection must be exercised`);
      assert.equal(baseline.replace(/allocations \d+\n$/, ''), fs.readFileSync(path.join(work, 'vectors', `${name}.expected`), 'utf8'));
      const neutral = snapshot(stage2ErrorOutcome('BR012'));
      for (let fail = 1; fail <= count; ++fail) {
        const result = run('decode-oom', name, fail);
        assert.equal(result.replace(/allocations \d+\n$/, ''), neutral, `decode allocation ${fail}/${count}`);
        ++decodeFaults;
      }
    }
    for (const name of ['wire-limit', 'over-wire-malformed']) {
      assert.equal(run('decode-oom', name, 1), snapshot(stage2ErrorOutcome('BR004')) + 'allocations 0\n', `${name}: wire limit must precede parser allocation`);
    }
    console.log(`PASS: ${encodeFaults} encoder and ${decodeFaults} decoder allocation failures; exact input/destination preservation; all prior outcomes`);
  }
  console.log(`PASS: ${cases.length} documents, complete 49-field outcomes, canonical round trips, all sample counts 1..100`);
}

const [mode, work, binary, faults] = process.argv.slice(2);
if (mode === 'prepare') prepare(path.resolve(work));
else if (mode === 'check') check(path.resolve(work), path.resolve(binary), faults === 'faults');
else throw new Error('expected prepare WORK or check WORK BINARY [faults]');

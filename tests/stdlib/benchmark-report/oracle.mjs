import assert from 'node:assert/strict';
import fs from 'node:fs';
import {STAGE2_REPORT_FIELDS} from '../../../spec/benchmark-report-v1/contract.mjs';
import {
  encodeReport, summarize, outlierFlags, toStage2Outcome, fromStage2Outcome, stage2ErrorOutcome,
  compareReports,
} from '../../../spec/benchmark-report-v1/model.mjs';

// Expected values come from the committed contract vector and its independent
// BigInt model, never from a production result or the source fixture's fields.
const baseline = JSON.parse(fs.readFileSync(new URL(
  '../../../spec/benchmark-report-v1/vectors/positive/maximum.json', import.meta.url,
)));
baseline.identity.parameter = 'cafe\u0301-😀' + baseline.identity.parameter.slice(11);
baseline.counters.allocated_bytes = {state: 'unavailable'};
baseline.counters.allocation_count = {state: 'available', value: 0};
const candidate = structuredClone(baseline);
candidate.samples = candidate.samples.map(value => Number(BigInt(value) / 2n));
candidate.summary = summarize(candidate.samples);
candidate.outliers = outlierFlags(candidate.samples);
const baseOutcome = toStage2Outcome(baseline);
const nextOutcome = toStage2Outcome(candidate);
const baseWire = encodeReport(baseline);
const nextWire = encodeReport(candidate);
assert.equal(STAGE2_REPORT_FIELDS.length, 49);
assert.equal(baseOutcome.sample_segment0.length, 64);
assert.equal(baseOutcome.sample_segment1.length, 36);
assert.equal(baseOutcome.allocated_bytes_available, false);
assert.equal(baseOutcome.allocation_count_available, true);
assert.equal(baseOutcome.allocation_count_value, 0);
assert.notEqual(baseline.identity.parameter, baseline.identity.parameter.normalize('NFC'));
assert.ok(baseWire.length > 4096 && nextWire.length > 4096);

function line(value) { process.stdout.write(`${value}\n`); }
function fields(outcome) {
  for (const {name, type} of STAGE2_REPORT_FIELDS) {
    line(name);
    const value = outcome[name];
    if (type === 'List[Int]') {
      line(value.length);
      value.forEach(line);
    } else line(type === 'Bool' ? Number(value) : value);
  }
}
function wire(bytes) { line(bytes.length); bytes.forEach(line); }
function comparison(status, result = 0, change = 0, threshold = 0) {
  [status, result, change, threshold].forEach(line);
}

line('baseline model'); fields(baseOutcome);
line('candidate model'); fields(nextOutcome);
line('encode statuses'); line(0); line(0);
line('baseline wire'); wire(baseWire);
line('candidate wire'); wire(nextWire);
line('baseline decoded'); fields(baseOutcome);
line('candidate decoded'); fields(nextOutcome);
line('comparison');
const verdict = compareReports(baseline, candidate, 100);
assert.equal(verdict.verdict, 'improved');
assert.equal(verdict.change_bps, -5000);
comparison(0, 1, verdict.change_bps, verdict.threshold_bps);
// The producer's invalid physical direction maps before semantic report
// validation. Derive its category independently instead of preserving the
// superseded model's BR003 result.
let modelError;
try { fromStage2Outcome({...baseOutcome, direction_tag: 99}); assert.fail('invalid direction accepted'); }
catch(error) { assert.equal(error.code, 'BR006'); modelError = Number(error.code.slice(2)); }
line('decode refusal'); fields(stage2ErrorOutcome('BR001'));
line('model refusal'); fields(stage2ErrorOutcome('BR006'));
line('cancelled outcome'); fields(stage2ErrorOutcome('BR011'));
line('refused comparisons'); comparison(1); comparison(modelError);
line('refused encodes preserve complete prior wire');
[1, modelError, 11].forEach(line); wire(baseWire);
line('empty destination remains empty'); line(modelError); wire(Buffer.alloc(0));

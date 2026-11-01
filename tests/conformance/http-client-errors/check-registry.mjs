// The HttpError registry, held against the #1257 oracle and the fixtures
// (#1697, RFC-0016/A01).
//
// usage: node check-registry.mjs block FIXTURE.kofun...
//        node check-registry.mjs project OUTDIR
//
// `block` requires the carrier declaration in every fixture to be byte-for-byte
// the one rendered from `spec/native-toolchain-v1/contract.json`
// (`http_carrier.error`), between the BEGIN and END marker lines. The contract
// is the authority; a fixture that edits a field, a constructor, or a payload
// name by hand is refused, so no fixture can pin a different HttpError.
//
// `project` renders the contract's registry against the oracle's committed
// results: every error the #1257 oracle can produce becomes one HttpError in a
// generated Kofun program, and the expected output is computed here from the
// oracle's own results and the registry, not from the compiler. Running the
// program through both halves of the pair and comparing is what makes "the
// four kinds and their payloads are exact" a measurement.
//
// What the oracle records, and so what is projected exactly:
//   kind            -> constructor
//   retry_safe      -> retry_safe
//   at              -> offset (protocol, body-truncated, transport)
//   fail/cancel/deadline trace note -> transport cause, and its phase
//   limit-exceeded detail text + the script's limit -> dimension and limit
// The oracle records no observed size and no phase for an error the model
// raised itself, so those two are not oracle facts: a protocol, limit, or
// truncation error takes `head` before the framing decision and `body` after
// it (the only two places the model raises them), and `observed_at_most` is not
// projected at all. A producer (#1261, #1262) fills what the oracle cannot say.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

import {ERROR_KINDS, PHASES, readScript, readResult} from '../../http/client-model/schema.mjs';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const contract = JSON.parse(fs.readFileSync(path.join(root, 'spec/native-toolchain-v1/contract.json'), 'utf8'));
const http = contract.decisions.http_carrier;
const error = http.error;
const fixtures = path.join(root, 'tests/http/client-model/fixtures');

const BEGIN = `# BEGIN ${error.profile}`;
const END = `# END ${error.profile}`;

// The caller-set limits of the oracle and the ceiling each one bounds (#1258
// Q2(e)). The dimension of a LimitExceeded is the ceiling's registry code.
const CALLER_LIMIT_CEILING = Object.freeze({
  max_header_bytes: 'header_total_bytes',
  max_headers: 'header_count',
  max_chunk_bytes: 'chunk_bytes',
  max_body_bytes: 'read_all_hard_bytes',
});

export function renderBlock() {
  const lines = [];
  for (const kind of error.kinds) {
    lines.push(`type ${kind.payload} = {`);
    for (const [name, type] of kind.fields) lines.push(`    ${name}: ${type},`);
    lines.push('}', '');
  }
  lines.push(`type ${error.adt} =`);
  for (const kind of error.kinds) lines.push(`    | ${kind.constructor}(detail: ${kind.payload})`);
  return `${lines.join('\n')}\n`;
}

// The registry is the oracle's vocabulary, not a copy that can drift from it.
function checkAgainstOracle() {
  assert.deepEqual(error.kinds.map(kind => kind.kind), [...ERROR_KINDS],
    'the contract kinds are the oracle ERROR_KINDS, in order');
  assert.deepEqual(Object.keys(error.phase_codes), [...PHASES],
    'the contract phase registry is the oracle PHASES, in order');
  for (const ceiling of Object.values(CALLER_LIMIT_CEILING)) {
    assert(Object.hasOwn(error.dimension_codes, ceiling), `${ceiling} has a dimension code`);
  }
  // Every phase the oracle can inject a deadline at has a committed script that
  // the model answers as kind `transport`, cause deadline.
  for (const phase of PHASES) {
    const name = `deadline_at_${phase}`;
    const script = readScript(JSON.parse(fs.readFileSync(path.join(fixtures, `${name}.script.json`), 'utf8')));
    const last = script.operations.at(-1);
    assert.deepEqual(last, {op: 'deadline', at: phase}, `${name} ends in a deadline at ${phase}`);
    const result = readResult(JSON.parse(fs.readFileSync(path.join(fixtures, `${name}.result.json`), 'utf8')));
    assert.equal(result.error.kind, 'transport', `${name} is a transport error`);
    assert.equal(result.error.detail, 'the deadline elapsed', `${name} names the deadline`);
    assert(result.trace.includes(`deadline:${phase}`), `${name} traces the deadline`);
  }
}

function block(files) {
  const expected = renderBlock();
  assert(files.length > 0, 'usage: check-registry.mjs block FIXTURE.kofun...');
  for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    const begin = text.indexOf(`${BEGIN}\n`);
    const end = text.indexOf(`\n${END}\n`);
    assert(begin >= 0 && end > begin, `${path.basename(file)} has no ${BEGIN} block`);
    const actual = text.slice(begin + BEGIN.length + 1, end + 1);
    assert.equal(actual, expected, `${path.basename(file)} declares an HttpError other than the contract's`);
  }
  console.log(`PASS: ${files.length} fixtures declare exactly the contract's HttpError (${error.kinds.length} kinds)`);
}

function oracleErrors() {
  const results = [];
  for (const file of fs.readdirSync(fixtures).filter(name => name.endsWith('.result.json')).sort()) {
    const stem = file.slice(0, -'.result.json'.length);
    const result = readResult(JSON.parse(fs.readFileSync(path.join(fixtures, file), 'utf8')));
    if (result.outcome === 'complete') continue;
    const script = readScript(JSON.parse(fs.readFileSync(path.join(fixtures, `${stem}.script.json`), 'utf8')));
    results.push({stem, result, script});
  }
  return results;
}

// One oracle error as the registry's payload values.
export function project({result, script}) {
  const kind = error.kinds.find(entry => entry.kind === result.error.kind);
  assert(kind, `${result.error.kind} is one of the four kinds`);
  const injected = result.trace.map(note => /^(fail|cancel|deadline):(write|head|body|drain)$/.exec(note)).filter(Boolean).at(-1);
  const phaseName = injected ? injected[2] : result.trace.some(note => note.startsWith('framing:')) ? 'body' : 'head';
  const values = {
    phase: error.phase_codes[phaseName],
    retry_safe: result.retry_safe,
    offset: result.error.at,
  };
  if (kind.kind === 'transport') {
    assert(injected, `${result.name}: a transport error is an injected event`);
    values.cause = error.cause_codes[{fail: 'failed', cancel: 'cancelled', deadline: 'deadline'}[injected[1]]];
  }
  if (kind.kind === 'limit-exceeded') {
    const caller = result.error.detail.split(' ')[0];
    assert(Object.hasOwn(CALLER_LIMIT_CEILING, caller), `${result.name}: ${result.error.detail} names a caller limit`);
    values.dimension = error.dimension_codes[CALLER_LIMIT_CEILING[caller]];
    values.limit = script.limits[caller];
    values.observed_at_most = 0;
  }
  return {kind, values};
}

const tag = name => error.kinds.findIndex(entry => entry.kind === name) + 1;
const fieldA = ({kind, values}) => kind.kind === 'limit-exceeded' ? values.dimension : kind.kind === 'transport' ? values.cause : values.offset;
const fieldB = ({kind, values}) => kind.kind === 'limit-exceeded' ? values.limit : 0;

// One generated Kofun program and its expected output, for a list of projected errors.
function render(errors) {
  const source = [
    '# Generated by check-registry.mjs from the contract and the oracle corpus; not a tracked fixture.',
    BEGIN,
    renderBlock().trimEnd(),
    END,
    '',
    `fn kind_of(error: ${error.adt}) -> Int {`,
    '    let mut kind = 0',
    '    match error {',
    ...error.kinds.map((entry, index) => `        ${entry.constructor}(_) => { kind = ${index + 1} },`),
    '    }',
    '    return kind',
    '}',
    '',
    `fn phase_of(error: ${error.adt}) -> Int {`,
    '    let mut phase = 0',
    '    match error {',
    ...error.kinds.map(entry => `        ${entry.constructor}(detail) => { phase = detail.phase },`),
    '    }',
    '    return phase',
    '}',
    '',
    `fn retry_of(error: ${error.adt}) -> Int {`,
    '    let mut safe = 0',
    '    match error {',
    ...error.kinds.map(entry => `        ${entry.constructor}(detail) => {\n            if detail.retry_safe {\n                safe = 1\n            }\n        },`),
    '    }',
    '    return safe',
    '}',
    '',
    `fn first_of(error: ${error.adt}) -> Int {`,
    '    let mut first = 0',
    '    match error {',
    ...error.kinds.map(entry => {
      const name = entry.kind === 'limit-exceeded' ? 'dimension' : entry.kind === 'transport' ? 'cause' : 'offset';
      return `        ${entry.constructor}(detail) => { first = detail.${name} },`;
    }),
    '    }',
    '    return first',
    '}',
    '',
    `fn second_of(error: ${error.adt}) -> Int {`,
    '    let mut second = 0',
    '    match error {',
    '        LimitExceeded(detail) => { second = detail.limit },',
    '        _ => { second = 0 },',
    '    }',
    '    return second',
    '}',
    '',
    `fn report(error: ${error.adt}) -> Int {`,
    '    print(kind_of(error))',
    '    print(phase_of(error))',
    '    print(retry_of(error))',
    '    print(first_of(error))',
    '    print(second_of(error))',
    '    return 0',
    '}',
    '',
    'fn main() -> Int {',
  ];
  const expected = [];
  errors.forEach((entry, index) => {
    const fields = entry.kind.fields.map(([name]) => `${name}: ${entry.values[name]}`).join(', ');
    source.push(`    let d${index}: ${entry.kind.payload} = ${entry.kind.payload}(${fields})`);
    source.push(`    let e${index}: ${error.adt} = ${entry.kind.constructor}(d${index})`);
    source.push(`    report(e${index})`);
    expected.push(tag(entry.kind.kind), entry.values.phase, entry.values.retry_safe ? 1 : 0, fieldA(entry), fieldB(entry));
  });
  source.push('    return 0', '}', '');
  return {source: source.join('\n'), expected: `${expected.join('\n')}\n`};
}

function projectProgram(outdir) {
  checkAgainstOracle();
  const errors = oracleErrors().map(entry => ({...entry, ...project(entry)}));
  assert(errors.length >= 40, 'the oracle corpus has at least forty error results');
  const kindsSeen = new Set(errors.map(entry => entry.kind.kind));
  assert.deepEqual([...kindsSeen].sort(), [...ERROR_KINDS].sort(), 'the corpus produces all four kinds');

  // The whole corpus runs through the compiled C. The Kofun half interprets a
  // source in time that grows with its size, so the pair is compared on one
  // error per distinct (kind, phase, retry_safe, cause or dimension) instead:
  // the same constructs, at a size a gate can afford.
  const distinct = new Map();
  for (const entry of errors) {
    const key = JSON.stringify([entry.kind.kind, entry.values.phase, entry.values.retry_safe, entry.values.cause ?? entry.values.dimension ?? 0]);
    if (!distinct.has(key)) distinct.set(key, entry);
  }
  const all = render(errors);
  const some = render([...distinct.values()]);
  fs.mkdirSync(outdir, {recursive: true});
  fs.writeFileSync(path.join(outdir, 'projection.kofun'), all.source);
  fs.writeFileSync(path.join(outdir, 'projection.expected'), all.expected);
  fs.writeFileSync(path.join(outdir, 'distinct.kofun'), some.source);
  fs.writeFileSync(path.join(outdir, 'distinct.expected'), some.expected);
  const perKind = Object.fromEntries(ERROR_KINDS.map(name => [name, errors.filter(entry => entry.kind.kind === name).length]));
  console.log(`PASS: ${errors.length} oracle errors project onto HttpError (${Object.entries(perKind).map(([name, count]) => `${name} ${count}`).join(', ')}); ${distinct.size} distinct shapes for the pair`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [mode, ...rest] = process.argv.slice(2);
  if (mode === 'block') block(rest);
  else if (mode === 'project') projectProgram(rest[0]);
  else throw new Error('usage: check-registry.mjs block FIXTURE.kofun... | project OUTDIR');
}

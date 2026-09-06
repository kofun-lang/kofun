import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const cases = dirname(fileURLToPath(import.meta.url))
const root = resolve(cases, '../../..')
const work = mkdtempSync(join(tmpdir(), 'kofun-move-call-crossings.'))
const cc = process.env.CC || 'cc'
const implementation = join(root, 'bootstrap/stage2/compiler.c')
const include = join(root, 'bootstrap/stage2')
const source = readFileSync(implementation, 'utf8')
const flags = ['-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic', '-I', include]
function run(command, args, label, expected = 0) {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 })
  assert.equal(result.error, undefined, `${label}: ${result.error}`)
  assert.equal(result.status, expected, `${label}: exit ${result.status}\n${result.stdout}\n${result.stderr}\nwork: ${work}`)
  return result
}
function compile(tool, file, name, expected) {
  const output = join(work, `${name}.c`)
  const result = run(tool, [file, output, join(work, `${name}.ir`), join(work, `${name}.tokens`)], name, expected)
  assert.equal(result.stderr, '', `${name}: internal stderr`)
  if (expected === 1) assert.equal(existsSync(output), false, `${name}: rejected C committed`)
  return { ...result, output }
}
const refusals = ['bytes_edit_after', 'bytes_double', 'record_use_after', 'record_double', 'record_edit']
for (const level of [0, 2]) {
  const tool = join(work, `stage2.O${level}`)
  run(cc, [...flags, `-O${level}`, implementation, '-o', tool], `compiler O${level}`)
  for (const stem of refusals) {
    const result = compile(tool, join(cases, `${stem}.kofun`), `${stem}.O${level}`, 1)
    assert.equal(result.stdout, readFileSync(join(cases, `${stem}.stderr`), 'utf8'), `${stem}: exact diagnostic/spans`)
  }
  const accepted = compile(tool, join(cases, 'accepted.kofun'), `accepted.O${level}`, 0)
  const binary = join(work, `accepted.O${level}`)
  run(cc, [...flags, `-O${level}`, '-g', '-fsanitize=address,undefined', accepted.output, '-o', binary], `accepted C O${level}`)
  const execution = spawnSync(binary, [], { encoding: 'utf8', env: { ...process.env, ASAN_OPTIONS: 'detect_leaks=1', UBSAN_OPTIONS: 'halt_on_error=1' } })
  assert.equal(execution.status, 0, `accepted O${level}: ${execution.stderr}`)
  assert.equal(execution.stderr, '', `accepted O${level}: sanitizer output`)
  assert.equal(execution.stdout, readFileSync(join(cases, 'accepted.stdout'), 'utf8'))
  const driver = join(work, `boundaries.O${level}`)
  run(cc, [...flags, `-O${level}`, join(cases, 'boundary_driver.c'), '-o', driver], `boundary driver O${level}`)
  run(driver, [], `boundary driver O${level}`)

  // A completed coalescing operand cannot suppress a later definite move.
  // Pin both a later statement and a separate argument in the same call.
  for (const context of ['statement', 'argument']) {
    let fixture = readFileSync(join(cases, 'record_use_after.kofun'), 'utf8')
    fixture = fixture.replace('fn main()', 'fn select(first: Int, second: Int) -> Int { return first + second }\n\nfn main()')
    fixture = fixture.replace('    print(consume(point))', context === 'statement'
      ? '    let fallback: Int? = null\n    print(fallback ?? 0)\n    print(consume(point))'
      : '    let fallback: Int? = null\n    print(select(fallback ?? 0, consume(point)))')
    const moved = fixture.indexOf('consume(point)', fixture.indexOf('fn main')) + 8
    const use = fixture.indexOf('print(point.x)', moved) + 6
    const file = join(work, `after-coalescing-${context}.kofun`)
    writeFileSync(file, fixture)
    const result = compile(tool, file, `after-coalescing-${context}.O${level}`, 1)
    assert.equal(result.stdout, `error[E2S123]: \`point\` was moved by \`take\` and cannot be used again at bytes ${use}..${use + 5}; moved by \`take\` at bytes ${moved}..${moved + 5}\n`)
  }

  // The same record crossing followed by each pre-existing move spelling must
  // retain the exact second-move wording and primary/related span roles.
  const original = readFileSync(join(cases, 'record_double.kofun'), 'utf8')
  for (const spelling of ['standalone', 'labelled', 'pipeline']) {
    let fixture = original
    const second = original.lastIndexOf('    print(consume(point))')
    if (spelling === 'standalone') fixture = original.slice(0, second) + original.slice(second).replace('print(consume(point))', 'take point')
    if (spelling === 'labelled') fixture = original.replace('fn main()', 'fn labelled(take value point: Point) -> Int { return point.x }\n\nfn main()')
    if (spelling === 'labelled') {
      const at = fixture.lastIndexOf('print(consume(point))')
      fixture = fixture.slice(0, at) + fixture.slice(at).replace('print(consume(point))', 'print(labelled(value: point))')
    }
    if (spelling === 'pipeline') fixture = original.slice(0, second) + original.slice(second).replace('print(consume(point))', 'print(point |> consume())')
    const first = fixture.indexOf('consume(point)', fixture.indexOf('fn main')) + 8
    const again = spelling === 'standalone' ? fixture.indexOf('take point', fixture.indexOf('fn main'))
      : spelling === 'labelled' ? fixture.indexOf('value: point', fixture.indexOf('fn main')) + 7
        : fixture.indexOf('point |>', fixture.indexOf('fn main'))
    const end = again + (spelling === 'standalone' ? 10 : 5)
    const file = join(work, `${spelling}.kofun`)
    writeFileSync(file, fixture)
    const result = compile(tool, file, `${spelling}.O${level}`, 1)
    assert.equal(result.stdout, `error[E2S123]: \`point\` was already moved by \`take\` at bytes ${again}..${end}; first moved by \`take\` at bytes ${first}..${first + 5}\n`, spelling)
  }
}

// The public build path must also refuse before publishing either artifact.
// The direct compiler checks above alone cannot prove executable publication.
for (const stem of refusals) {
  const output = join(work, `${stem}.cli.c`)
  const binary = join(work, `${stem}.cli.bin`)
  const result = run(join(root, 'bin/kofun'), ['build', join(cases, `${stem}.kofun`), '-o', binary, '--emit-c', output], `${stem} CLI`, 1)
  const golden = readFileSync(join(cases, `${stem}.stderr`), 'utf8')
  assert.ok((result.stdout + result.stderr).includes(golden), `${stem}: CLI diagnostic`)
  assert.equal(existsSync(output), false, `${stem}: CLI published C`)
  assert.equal(existsSync(binary), false, `${stem}: CLI published executable`)
}

const mutations = [
  ['mode-check', 'if (!taken) return false;', 'if (false && !taken) return false;'],
  ['direct-resolution', 'if (!direct) { free(name); return false; }', 'if (false && !direct) { free(name); return false; }'],
  ['bare-binding', 'if (expression_end(source, cursor) != token_end(source, cursor)) return false;', 'if (false && expression_end(source, cursor) != token_end(source, cursor)) return false;'],
  ['type-bound', 'bool admitted = strcmp(type, "Bytes") == 0 || move_trivial_record(source, type);', 'bool admitted = true || strcmp(type, "Bytes") == 0 || move_trivial_record(source, type);'],
  ['borrowed-owner', 'if (borrowed) return false;', 'if (false && borrowed) return false;'],
  ['straight-line', 'return admitted && move_straight_line_position(source, cursor);', 'return admitted && (true || move_straight_line_position(source, cursor));'],
  ['binding-id', "bool same = left[0] != '\\0' && strcmp(left, right) == 0;", "bool same = left[0] != '\\0' && (true || strcmp(left, right) == 0);"],
  ['structured-record-edit', 'stage2_diagnostic_set("E2S181", cursor, token_end(source, cursor), true, error.data);', '/* missing structured record-edit diagnostic */']
]
for (const [label, before, after] of mutations) {
  assert.equal(source.split(before).length, 2, `${label}: mutation anchor must occur once`)
  const file = join(work, `${label}.c`)
  writeFileSync(file, source.replace(before, after))
  const driver = join(work, label)
  run(cc, [...flags, '-O0', `-DKOFUN_MOVE_COMPILER="${file}"`, join(cases, 'boundary_driver.c'), '-o', driver], `${label} mutant build`)
  const failure = run(driver, [], `${label} mutant witness`, 1)
  assert.match(failure.stderr, new RegExp(`FAIL: move-call boundary: ${label}\\n`))
}

// Reintroduce the two externally visible defects independently. A mutant that
// fails to build is never counted as a successful regression witness.
for (const [label, before, after, fixture] of [
  ['missing-positional-move', 'return written_with_label || move_positional_binding(source, hir, cursor);', 'return written_with_label && move_positional_binding(source, hir, cursor);', 'bytes_edit_after'],
  ['missing-record-edit-refusal', "if (record_mode_check[0] != '\\0') return record_mode_check;", "if (false && record_mode_check[0] != '\\0') return record_mode_check;", 'record_edit']
]) {
  assert.equal(source.split(before).length, 2, `${label}: mutation anchor`)
  const file = join(work, `${label}.c`)
  const tool = join(work, label)
  writeFileSync(file, source.replace(before, after))
  run(cc, [...flags, '-O0', file, '-o', tool], `${label} compiler`)
  const result = compile(tool, join(cases, `${fixture}.kofun`), label, 0)
  run(cc, [...flags, '-O0', result.output, '-o', join(work, `${label}.bin`)], `${label} wrongly accepted C`)
}
console.log('PASS: move-call-crossings exact Bytes/record diagnostics and spans, CLI no-C/no-binary refusals, accepted borrowing/shadowing, O0/O2 sanitizer execution, three existing move spellings, seven semantic-boundary mutations, a structured-diagnostic mutation and two missing-rule mutations')
if (process.env.KOFUN_MOVE_KEEP_WORK) console.log(`Evidence directory: ${work}`)
else rmSync(work, { recursive: true })

import assert from "node:assert/strict";
import fs from "node:fs";

const [cPath, kofunPath, mode = "check"] = process.argv.slice(2);
if (!cPath || !kofunPath || !new Set(["check", "self-test"]).has(mode)) {
  throw new Error("usage: check-pair.mjs COMPILER_C COMPILER_KOFUN [check|self-test]");
}

const original = {
  C: fs.readFileSync(cPath, "utf8"),
  Kofun: fs.readFileSync(kofunPath, "utf8"),
};

const compact = (text) => text.replace(/\s+/g, " ");

function section(source, start, end, side) {
  const at = source.indexOf(start);
  assert.ok(at >= 0, `${side} missing section ${start}`);
  assert.equal(source.indexOf(start, at + start.length), -1, `${side} duplicated section ${start}`);
  const finish = source.indexOf(end, at + start.length);
  assert.ok(finish > at, `${side} missing section end ${end}`);
  return compact(source.slice(at, finish));
}

function ordered(failures, side, source, checks) {
  let prior = -1;
  for (const [label, needle] of checks) {
    const at = source.indexOf(needle);
    if (at < 0) failures.push(`${side} missing ${label}`);
    else if (at <= prior) failures.push(`${side} reordered ${label}`);
    prior = Math.max(prior, at);
  }
}

function verifyPair(cText, kofunText) {
  const failures = [];
  const cOptional = section(cText, "static char *validate_optional_uses(", "static char *emit_condition_into(", "C");
  const kOptional = section(kofunText, "fn validate_optional_uses(", "fn emit_condition_into(", "Kofun");
  const cPreflight = section(cText, "static char *int_bit_error_before_unresolved(", "static char *scope_hir_error(", "C");
  const kPreflight = section(kofunText, "fn int_bit_error_before_unresolved(", "fn build_scope_hir_mode(", "Kofun");
  const cChain = section(cText, "static char *emit_int_bit_chain(", "static char *emit_primary(", "C");
  const kChain = section(kofunText, "fn emit_int_bit_chain(", "fn emit_primary(", "Kofun");
  const cScope = section(cText, "static char *build_scope_hir_mode(", "static char *build_scope_hir(", "C");
  const kScope = section(kofunText, "fn build_scope_hir_mode(", "fn build_scope_hir(", "Kofun");

  for (const [side, optional] of [["C", cOptional], ["Kofun", kOptional]]) {
    if (!optional.includes("bit_expression")) failures.push(`${side} missing Optional bit-call deferral`);
    if (!optional.includes("optional && !bit_expression")) failures.push(`${side} Optional deferral is not bit-call bounded`);
  }
  for (const [side, preflight, chain, scope] of [
    ["C", cPreflight, cChain, cScope],
    ["Kofun", kPreflight, kChain, kScope],
  ]) {
    const truth = side === "C" ? {
      unknownBranch: "if (arity < 0)",
      receiverRefusal: 'if (strcmp(receiver_type, "Int") != 0)',
      argumentRefusal: 'if (strcmp(argument_type, "Int") != 0)',
      labelRefusal: 'if (colon >= 0 && colon < close && token_equal(source, colon, ":"))',
      scopeGuard: "if (bit_error != NULL)",
    } : {
      unknownBranch: "if arity < 0",
      receiverRefusal: 'if receiver_type != "Int"',
      argumentRefusal: 'if argument_type != "Int"',
      labelRefusal: 'if colon >= 0 && colon < close && token_text(source, colon) == ":"',
      scopeGuard: "if len(bit_error) > 0",
    };
    ordered(failures, side, preflight, [
      ["preflight receiver classifier", "receiver_type = initializer_type_bounded("],
      ["preflight receiver refusal", "bit operations are defined on `Int`"],
      ["preflight label refusal", "takes positional arguments"],
      ["preflight argument classifier", "argument_type = initializer_type_bounded("],
      ["preflight argument refusal", "takes `Int` arguments"],
    ]);
    if (!preflight.includes(truth.receiverRefusal)) failures.push(`${side} missing preflight receiver type refusal`);
    if (!preflight.includes(truth.labelRefusal)) failures.push(`${side} missing preflight label refusal`);
    if (!preflight.includes(truth.argumentRefusal)) failures.push(`${side} missing preflight argument type refusal`);
    if (!scope.includes("int_bit_error_before_unresolved(")) failures.push(`${side} missing scope-order deferral`);
    if (!scope.includes(truth.scopeGuard)) failures.push(`${side} missing scope-order guard`);
    ordered(failures, side, chain, [
      ["receiver classifier", "receiver_type = initializer_type_bounded("],
      ["receiver refusal", "bit operations are defined on `Int`"],
      ["receiver emission", "emit_primary("],
      ["unknown suffix refusal", "unknown `Int` member"],
      ["label refusal", "takes positional arguments"],
      ["argument classifier", "argument_type = initializer_type_bounded("],
      ["argument refusal", "takes `Int` arguments"],
      ["fn anchor", "skip_trivia(source, close)"],
      ["trailing refusal", "takes no trailing lambda"],
      ["arity refusal", "expects"],
    ]);
    if (!chain.includes(truth.unknownBranch)) failures.push(`${side} missing unknown suffix branch`);
    if (!chain.includes(truth.receiverRefusal)) failures.push(`${side} missing receiver type refusal`);
    if (!chain.includes(truth.labelRefusal)) failures.push(`${side} missing label refusal branch`);
    if (!chain.includes(truth.argumentRefusal)) failures.push(`${side} missing argument type refusal`);
  }
  return failures;
}

function mutateSection(source, start, end, needle, replacement, label) {
  const at = source.indexOf(start);
  assert.ok(at >= 0, `${label}: section start absent`);
  const finish = source.indexOf(end, at + start.length);
  assert.ok(finish > at, `${label}: section end absent`);
  const slice = source.slice(at, finish);
  const hit = slice.indexOf(needle);
  assert.ok(hit >= 0, `${label}: target absent`);
  assert.equal(slice.indexOf(needle, hit + needle.length), -1, `${label}: target ambiguous`);
  const absolute = at + hit;
  const changed = source.slice(0, absolute) + replacement + source.slice(absolute + needle.length);
  assert.notEqual(changed, source, `${label}: bytes did not change`);
  return changed;
}

function expectFailure(label, sources, expected) {
  const failures = verifyPair(sources.C, sources.Kofun);
  assert.ok(failures.some((failure) => failure.includes(expected)), `${label} survived: ${failures.join("; ")}`);
}

const clean = verifyPair(original.C, original.Kofun);
if (clean.length) throw new Error(clean.join("\n"));

if (mode === "self-test") {
  const specs = [
    {
      rule: "Optional deferral",
      functionName: "validate_optional_uses",
      expected: "Optional deferral is not bit-call bounded",
      C: ["optional && !bit_expression", "optional && bit_expression"],
      Kofun: ["optional && !bit_expression", "optional && bit_expression"],
    },
    {
      rule: "unknown suffix",
      functionName: "emit_int_bit_chain",
      expected: "missing unknown suffix branch",
      C: ["if (arity < 0)", "if (arity < -1)"],
      Kofun: ["if arity < 0", "if arity < -1"],
    },
    {
      rule: "receiver actual type",
      functionName: "emit_int_bit_chain",
      expected: "missing receiver type refusal",
      C: ['if (strcmp(receiver_type, "Int") != 0)', 'if (strcmp(receiver_type, "Int") == 0)'],
      Kofun: ['if receiver_type != "Int"', 'if receiver_type == "Int"'],
    },
    {
      rule: "argument actual type",
      functionName: "emit_int_bit_chain",
      expected: "missing argument type refusal",
      C: ['if (strcmp(argument_type, "Int") != 0)', 'if (strcmp(argument_type, "Int") == 0)'],
      Kofun: ['if argument_type != "Int"', 'if argument_type == "Int"'],
    },
    {
      rule: "scope order",
      functionName: "build_scope_hir_mode",
      expected: "missing scope-order guard",
      C: ["if (bit_error != NULL)", "if (false)"],
      Kofun: ["if len(bit_error) > 0", "if false"],
    },
    {
      rule: "label order",
      functionName: "emit_int_bit_chain",
      expected: "missing label refusal branch",
      C: [
        'if (colon >= 0 && colon < close && token_equal(source, colon, ":"))',
        "if (false)",
      ],
      Kofun: [
        'if colon >= 0 && colon < close &&\n               token_text(source, colon) == ":"',
        "if false",
      ],
    },
    {
      rule: "fn anchor",
      functionName: "emit_int_bit_chain",
      expected: "missing fn anchor",
      C: ["skip_trivia(source, close)", "trailing_parameters"],
      Kofun: ["skip_trivia(source, close)", "trailing_parameters"],
    },
  ];
  let mutations = 0;
  for (const side of ["C", "Kofun"]) {
    for (const spec of specs) {
      const { rule, functionName, expected } = spec;
      const [needle, replacement] = spec[side];
      const cStyle = side === "C";
      const start = cStyle ? `static char *${functionName}(` : `fn ${functionName}(`;
      const ends = {
        validate_optional_uses: cStyle ? "static char *emit_condition_into(" : "fn emit_condition_into(",
        emit_int_bit_chain: cStyle ? "static char *emit_primary(" : "fn emit_primary(",
        build_scope_hir_mode: cStyle ? "static char *build_scope_hir(" : "fn build_scope_hir(",
      };
      const sources = { ...original };
      sources[side] = mutateSection(sources[side], start, ends[functionName], needle, replacement, `${side} ${rule}`);
      expectFailure(`${side} ${rule}`, sources, `${side} ${expected}`);
      mutations += 1;
      process.stdout.write(`PASS [int-bit-mutation] ${side} ${rule}\n`);
    }
  }
  assert.equal(mutations, 14, "mutation matrix must remain exactly 14 cases");
  process.stdout.write("PASS: 14 independent Int-bit authority mutations are refused across both twins\n");
}

process.stdout.write("PASS: Int-bit Optional, scope order, actual types, suffix, labels, and fn anchors agree across both twins\n");

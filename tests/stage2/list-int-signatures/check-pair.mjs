import assert from "node:assert/strict";
import fs from "node:fs";

const [cPath, kofunPath, mode = "check"] = process.argv.slice(2);
if (!cPath || !kofunPath) {
  throw new Error("usage: check-pair.mjs COMPILER_C COMPILER_KOFUN [check|self-test]");
}

const cSource = fs.readFileSync(cPath, "utf8");
const kofunSource = fs.readFileSync(kofunPath, "utf8");

// The shared fixed-slot family is deliberately explicit. Before #1113 this
// harness selected only names containing `list_int`, so a correct generic
// rename could silently remove the merged mechanism from pair checking while
// the harness stayed green.
const fixedSlotFunctions = new Set([
  "call_slot_carried",
  "call_slot_declaration_prefix",
  "call_slot_zero",
  "fixed_slot_call_shape",
  "fixed_slot_call_supported",
  "labelled_call_supported",
  "direct_list_int_call_shape",
  "direct_list_int_call_supported",
  "labelled_argument_slot",
  "labelled_argument_value",
  "emit_fixed_slot_call",
  "emit_fixed_slot_call_temporaries",
]);

function functionNames(source, language) {
  const expression = language === "c"
    ? /^static\s+[^\n(]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/gm
    : /^fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/gm;
  return new Set(
    [...source.matchAll(expression)]
      .map((match) => match[1])
      .filter((name) => name.includes("list_int") || fixedSlotFunctions.has(name)),
  );
}

function callCount(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return [...source.matchAll(new RegExp(`\\b${escaped}\\s*\\(`, "g"))].length;
}

const minimumCalls = new Map([
  ["list_int_type_end", { c: 13, kofun: 13 }],
  ["validate_list_int_annotations", { c: 4, kofun: 3 }],
  ["fixed_slot_call_shape", { c: 3, kofun: 3 }],
  ["fixed_slot_call_supported", { c: 4, kofun: 4 }],
  ["labelled_call_supported", { c: 2, kofun: 2 }],
  ["direct_list_int_call_shape", { c: 2, kofun: 2 }],
  ["direct_list_int_call_supported", { c: 3, kofun: 3 }],
  ["labelled_argument_slot", { c: 2, kofun: 2 }],
  ["labelled_argument_value", { c: 2, kofun: 2 }],
  ["emit_fixed_slot_call", { c: 3, kofun: 3 }],
  ["emit_fixed_slot_call_temporaries", { c: 2, kofun: 2 }],
  ["emit_list_int_value", { c: 6, kofun: 5 }],
  ["function_result_is_list_int", { c: 2, kofun: 2 }],
  ["validate_list_int_lambda_uses", { c: 2, kofun: 2 }],
]);

const semanticAnchors = [
  {
    id: "annotation-validation-before-lowering",
    c: "char *list_annotation_check = validate_list_int_annotations(source);",
    kofun: "let list_annotation_check = validate_list_int_annotations(source)",
  },
  {
    id: "annotation-fallback-after-partial-hir",
    c: "char *list_fallback = validate_list_int_annotations(source);",
    kofun: "let list_fallback = validate_list_int_annotations(source)",
  },
  {
    id: "constructed-list-scope-span",
    c: "static int64_t constructed_list_type_end(",
    kofun: "fn constructed_list_type_end(",
  },
  {
    id: "constructed-list-scope-identity",
    c: "static char *constructed_list_type_text(",
    kofun: "fn constructed_list_type_text(",
  },
  {
    id: "lambda-validation-before-output",
    c: "char *list_lambda_check = validate_list_int_lambda_uses(source, hir);",
    kofun: "let list_lambda_check = validate_list_int_lambda_uses(source, hir)",
  },
  {
    id: "lambda-value-refusal",
    c: "lambda_scope_open(source, function_open, cursor) >= 0",
    kofun: "lambda_scope_open(source, function_open, cursor) >= 0",
  },
  {
    id: "ownership-mode-refusal",
    c: "ownership_mode_token(source, parameter) && list_int_type_end(source, type_start) >= 0",
    kofun: "ownership_mode_token(source, parameter) && list_int_type_end(source, type_start) >= 0",
  },
  {
    id: "function-local-source-order-temporaries",
    c: "temporaries = emit_fixed_slot_call_temporaries( source, hir, function_open );",
    kofun: "emitted = emitted + emit_fixed_slot_call_temporaries( source, hir, function_open )",
  },
  {
    id: "labelled-only-return-carrier-guard",
    c: "if (labelled) { char *result = function_return_type(source, callee); bool carries_result = call_slot_carried(source, result);",
    kofun: "if labelled && !call_slot_carried(source, function_return_type(source, callee))",
  },
  {
    id: "source-aware-labelled-carrier-vocabulary",
    c: "? call_slot_carried(source, type)",
    kofun: "carried = call_slot_carried(source, parameter_type)",
  },
  {
    id: "direct-mode-list-requirement",
    c: "return labelled || has_list;",
    kofun: "return labelled || has_list",
  },
  {
    id: "by-value-parameter-carrier",
    c: "buffer_format(&list, \"KofunIntListValue k_b%s\", binding_id);",
    kofun: "declarator = \"KofunIntListValue k_b\" + hir_definition_id_at(hir, name_at)",
  },
  {
    id: "by-value-result-carrier",
    c: "c_result = \"KofunIntListValue\";",
    kofun: "c_result = \"KofunIntListValue\"",
  },
  {
    id: "whole-value-let",
    c: "value = emit_list_int_value( source, hir, value_start, value_end, true );",
    kofun: "initializer = emit_list_int_value( source, hir, value_start, value_end, true )",
  },
  {
    id: "whole-value-return",
    c: "char *value = emit_list_int_value( source, hir, value_start, value_end, false );",
    kofun: "let value = emit_list_int_value( source, hir, value_start, value_end, false )",
  },
];

function compact(source) {
  return source.replace(/\s+/g, " ");
}

function verifyPair(cText, kofunText) {
  const failures = [];
  const cFunctions = functionNames(cText, "c");
  const kofunFunctions = functionNames(kofunText, "kofun");
  for (const name of cFunctions) {
    if (!kofunFunctions.has(name)) failures.push(`missing Kofun function: ${name}`);
  }
  for (const name of kofunFunctions) {
    if (!cFunctions.has(name)) failures.push(`missing C function: ${name}`);
  }

  for (const [name, minima] of minimumCalls) {
    for (const [side, source, minimum] of [
      ["C", cText, minima.c],
      ["Kofun", kofunText, minima.kofun],
    ]) {
      const observed = callCount(source, name);
      if (observed < minimum) {
        failures.push(`${side} dispatch ${name}: expected at least ${minimum}, saw ${observed}`);
      }
    }
  }

  const compactC = compact(cText);
  const compactKofun = compact(kofunText);
  for (const anchor of semanticAnchors) {
    if (!compactC.includes(compact(anchor.c))) failures.push(`C semantic dispatch missing: ${anchor.id}`);
    if (!compactKofun.includes(compact(anchor.kofun))) failures.push(`Kofun semantic dispatch missing: ${anchor.id}`);
  }

  for (const [label, token] of [
    ["by-value carrier", "KofunIntListValue"],
    ["fixed capacity", "elements[64]"],
    ["carrier zero", "KOFUN_LIST_INT_ZERO"],
    ["copy constructor", "kofun_list_int_value("],
    ["carrier length", "kofun_list_int_value_length("],
    ["view projection", "kofun_list_int_view("],
    ["source-order slots", "kofun_call_arg_"],
    ["stable refusal", "E2S157"],
    ["lambda annotation refusal", "List annotations inside lambdas"],
    ["lambda literal refusal", "List[Int] literals inside lambdas"],
    ["lambda binding refusal", "List[Int] binding uses inside lambdas"],
    ["lambda result refusal", "List[Int] direct results inside lambdas"],
    ["ownership-mode refusal", "List[Int] function parameters support only the immutable"],
    ["runtime bounds", "R023"],
  ]) {
    if (!cText.includes(token)) failures.push(`C missing ${label}: ${token}`);
    if (!kofunText.includes(token)) failures.push(`Kofun missing ${label}: ${token}`);
  }
  if (cText.includes("kofun_list_call_arg_")) {
    failures.push("C retained retired split slot prefix: kofun_list_call_arg_");
  }
  if (kofunText.includes("kofun_list_call_arg_")) {
    failures.push("Kofun retained retired split slot prefix: kofun_list_call_arg_");
  }
  return failures;
}

function requireFailure(failures, expected) {
  assert.ok(
    failures.some((failure) => failure.includes(expected)),
    `mutation did not produce named failure ${expected}: ${failures.join("; ")}`,
  );
}

function replaceLast(source, needle, replacement) {
  const at = source.lastIndexOf(needle);
  assert.ok(at >= 0, `mutation target not found: ${needle}`);
  return source.slice(0, at) + replacement + source.slice(at + needle.length);
}

const failures = verifyPair(cSource, kofunSource);
if (failures.length > 0) throw new Error(failures.join("\n"));

if (mode === "self-test") {
  const renamedKofun = kofunSource.replace(
    "fn validate_list_int_lambda_uses(",
    "fn removed_list_int_lambda_uses(",
  );
  assert.notEqual(renamedKofun, kofunSource, "Kofun member mutation did not apply");
  requireFailure(
    verifyPair(cSource, renamedKofun),
    "missing Kofun function: validate_list_int_lambda_uses",
  );

  const renamedC = cSource.replace(
    "static char *validate_list_int_lambda_uses(",
    "static char *removed_list_int_lambda_uses(",
  );
  assert.notEqual(renamedC, cSource, "C member mutation did not apply");
  requireFailure(
    verifyPair(renamedC, kofunSource),
    "missing C function: validate_list_int_lambda_uses",
  );

  const unvalidatedC = cSource.replace(
    "char *list_lambda_check = validate_list_int_lambda_uses(source, hir);",
    "char *list_lambda_check = owned_text(\"ok\");",
  );
  assert.notEqual(unvalidatedC, cSource, "C dispatch mutation did not apply");
  requireFailure(
    verifyPair(unvalidatedC, kofunSource),
    "C semantic dispatch missing: lambda-validation-before-output",
  );

  const unvalidatedKofun = kofunSource.replace(
    "let list_lambda_check = validate_list_int_lambda_uses(source, hir)",
    "let list_lambda_check = \"ok\"",
  );
  assert.notEqual(unvalidatedKofun, kofunSource, "Kofun dispatch mutation did not apply");
  requireFailure(
    verifyPair(cSource, unvalidatedKofun),
    "Kofun semantic dispatch missing: lambda-validation-before-output",
  );

  const unpairedSharedWalker = kofunSource.replace(
    "fn emit_fixed_slot_call_temporaries(",
    "fn removed_fixed_slot_call_temporaries(",
  );
  assert.notEqual(unpairedSharedWalker, kofunSource, "shared walker mutation did not apply");
  requireFailure(
    verifyPair(cSource, unpairedSharedWalker),
    "missing Kofun function: emit_fixed_slot_call_temporaries",
  );

  const unpairedSharedEmitter = kofunSource.replace(
    "fn emit_fixed_slot_call(",
    "fn removed_fixed_slot_call(",
  );
  assert.notEqual(unpairedSharedEmitter, kofunSource, "shared emitter mutation did not apply");
  requireFailure(
    verifyPair(cSource, unpairedSharedEmitter),
    "missing Kofun function: emit_fixed_slot_call",
  );

  const underCalledC = replaceLast(
    cSource,
    "fixed_slot_call_supported(",
    "removed_fixed_slot_call_supported(",
  );
  requireFailure(
    verifyPair(underCalledC, kofunSource),
    "C dispatch fixed_slot_call_supported: expected at least 4, saw 3",
  );

  const underCalledKofun = replaceLast(
    kofunSource,
    "fixed_slot_call_supported(",
    "removed_fixed_slot_call_supported(",
  );
  requireFailure(
    verifyPair(cSource, underCalledKofun),
    "Kofun dispatch fixed_slot_call_supported: expected at least 4, saw 3",
  );

  const underCalledLabelledC = replaceLast(
    cSource,
    "labelled_call_supported(",
    "removed_labelled_call_supported(",
  );
  requireFailure(
    verifyPair(underCalledLabelledC, kofunSource),
    "C dispatch labelled_call_supported: expected at least 2, saw 1",
  );

  const underCalledDirectKofun = replaceLast(
    kofunSource,
    "direct_list_int_call_supported(",
    "removed_direct_list_int_call_supported(",
  );
  requireFailure(
    verifyPair(cSource, underCalledDirectKofun),
    "Kofun dispatch direct_list_int_call_supported: expected at least 3, saw 2",
  );

  const sourceBlindKofun = kofunSource.replace(
    "carried = call_slot_carried(source, parameter_type)",
    "carried = call_slot_carried(\"\", parameter_type)",
  );
  assert.notEqual(sourceBlindKofun, kofunSource, "source-aware carrier mutation did not apply");
  requireFailure(
    verifyPair(cSource, sourceBlindKofun),
    "Kofun semantic dispatch missing: source-aware-labelled-carrier-vocabulary",
  );

  const splitPrefixC = cSource.replace(
    "kofun_call_arg_",
    "kofun_list_call_arg_",
  );
  assert.notEqual(splitPrefixC, cSource, "split-prefix mutation did not apply");
  requireFailure(
    verifyPair(splitPrefixC, kofunSource),
    "C retained retired split slot prefix: kofun_list_call_arg_",
  );

  const tokenlessC = cSource.replaceAll("R023", "REMOVED_RUNTIME_BOUNDS");
  assert.notEqual(tokenlessC, cSource, "required-token mutation did not apply");
  requireFailure(
    verifyPair(tokenlessC, kofunSource),
    "C missing runtime bounds: R023",
  );

  console.log("PASS: List[Int] pair mutations fail by explicit shared-family member, mode/surface dispatch, source-aware carrier, call-count, prefix, and token checks");
}

console.log("PASS: List[Int] semantic family and load-bearing dispatches exist on both canonical surfaces");

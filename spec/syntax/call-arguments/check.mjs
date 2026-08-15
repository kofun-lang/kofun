import assert from "node:assert/strict";
import fs from "node:fs";

import {
  CallModelError,
  assertNoRuntimeLabels,
  bindCall,
  classifySurface,
  interfaceFingerprint,
} from "./model.mjs";

const corpus = JSON.parse(fs.readFileSync(new URL("./corpus.json", import.meta.url), "utf8"));
assert.equal(corpus.schema, "kofun.call-arguments-corpus/v1");

const replace = {
  name: "replace",
  result: "Text",
  parameters: [
    { external: "in", internal: "text", mode: "read", type: "Text" },
    { external: "from", internal: "old", mode: "read", type: "Text" },
    { external: "to", internal: "replacement", mode: "read", type: "Text" },
  ],
};

const reordered = bindCall(replace, {
  arguments: [
    { label: "to", expression: "effect-c" },
    { label: "in", expression: "effect-a" },
    { label: "from", expression: "effect-b" },
  ],
});
assert.deepEqual(reordered.evaluation, ["effect-c", "effect-a", "effect-b"]);
assert.deepEqual(reordered.abi.map((entry) => entry.expression),
  ["effect-a", "effect-b", "effect-c"]);
assert.equal(assertNoRuntimeLabels(reordered.lowering), true);
assert.deepEqual([...new Set(reordered.lowering.map((item) => item.op))].sort(),
  ["call", "eval-temp", "store-slot"]);
const repeatedExpression = bindCall(replace, { arguments: [
  { label: "in", expression: "same" },
  { label: "from", expression: "same" },
  { label: "to", expression: "same" },
] });
assert.deepEqual(repeatedExpression.lowering.filter((item) => item.op === "store-slot")
  .map((item) => item.temp), [0, 1, 2]);

const fold = {
  name: "fold",
  result: "Int",
  parameters: [
    { internal: "values", mode: "read", type: "List[Int]" },
    { external: "initial", internal: "initial", mode: "read", type: "Int" },
    { internal: "combine", mode: "read", type: "Function" },
  ],
};
const piped = bindCall(fold, {
  pipeline: "values-effect",
  arguments: [{ label: "initial", expression: "initial-effect" }],
  trailingLambda: "lambda-effect",
});
assert.deepEqual(piped.evaluation,
  ["values-effect", "initial-effect", "lambda-effect"]);
assert.deepEqual(piped.abi.map((entry) => entry.expression),
  ["values-effect", "initial-effect", "lambda-effect"]);

function rejected(code, signature, call) {
  assert.throws(() => bindCall(signature, call), (error) =>
    error instanceof CallModelError && error.code === code);
}

rejected("CALL01", replace, { arguments: [
  { label: "inside", expression: "a" },
  { label: "from", expression: "b" },
  { label: "to", expression: "c" },
] });
rejected("CALL02", replace, { arguments: [
  { label: "in", expression: "a" },
  { label: "in", expression: "b" },
  { label: "from", expression: "c" },
  { label: "to", expression: "d" },
] });
rejected("CALL03", replace, { arguments: [
  { label: "in", expression: "a" },
  { label: "from", expression: "b" },
] });
rejected("CALL05", fold, { arguments: [
  { label: "initial", expression: "zero" },
  { label: null, expression: "values" },
  { label: null, expression: "lambda" },
] });
rejected("CALL07", replace, { arguments: [
  { label: null, expression: "a" },
  { label: "from", expression: "b" },
  { label: "to", expression: "c" },
] });
rejected("CALL08", replace, { arguments: [
  { label: "in", expression: "a" },
  { label: "from", expression: "b" },
  { label: "to", expression: "c" },
], trailingLambda: "lambda" });
const labelledFold = structuredClone(fold);
labelledFold.parameters[2].external = "combine";
rejected("CALL09", labelledFold, { pipeline: "values", arguments: [
  { label: "initial", expression: "zero" },
  { label: "combine", expression: "lambda-inside" },
], trailingLambda: "lambda-outside" });

for (const test of corpus.surface) {
  assert.equal(classifySurface(test.source).kind, test.kind, test.name);
}

const internalRename = structuredClone(replace);
internalRename.parameters[0].internal = "input";
assert.equal(interfaceFingerprint(internalRename), interfaceFingerprint(replace));
const externalRename = structuredClone(replace);
externalRename.parameters[0].external = "inside";
assert.notEqual(interfaceFingerprint(externalRename), interfaceFingerprint(replace));
const effectChange = structuredClone(replace);
effectChange.effects = ["io"];
assert.notEqual(interfaceFingerprint(effectChange), interfaceFingerprint(replace));

assert.ok(corpus.usability.some((item) => item.material && item.call.includes("from:")));
assert.ok(corpus.usability.some((item) => !item.material && item.call === item.ordinary));
assert.ok(corpus.usability.every((item) => item.reason.length >= 20));

const doc = fs.readFileSync(new URL("../call-arguments-v1.md", import.meta.url), "utf8");
for (const required of [
  "Default arguments are rejected in v1",
  "Labels MUST NOT participate in overload selection",
  "Every explicit expression evaluates exactly once",
  "allocate a dictionary",
  "parser plus canonical formatter",
  "HIR/type checking",
  "pipeline/trailing lowering plus C11/direct-native differential",
]) assert.ok(doc.includes(required), required);

const expressionsDoc = fs.readFileSync(
  new URL("../EXPRESSIONS_AND_LITERALS.md", import.meta.url),
  "utf8",
);
const gateReadme = fs.readFileSync(
  new URL("../../../tests/conformance/call-arguments/README.md", import.meta.url),
  "utf8",
);
const gateRun = fs.readFileSync(
  new URL("../../../tests/conformance/call-arguments/run.sh", import.meta.url),
  "utf8",
);

const pipelineTruth = {
  expressions: expressionsDoc,
  spec: doc,
  readme: gateReadme,
  run: gateRun,
};
const requiredRunTruth = [
  "whose C11 lowering evaluates the subject first and exactly once before the explicit arguments",
  "the chain is that one production iterated, left-associated, with every stage checked and lowered as a stage whose subject is the result of the stage before it, and no second temporary family",
  "a binding whose initializer is a pipeline carries the declared result of the last stage and is checked against the slot it is later piped into",
  "#882 retains bare/member/trailing-lambda pipeline forms, block-bodied trailing calls, labelled calls in lifted lambdas, and lexical/indirect targets",
  "the labelled Int call executes on direct-native and wasm32 against the same golden as C11",
  "each stop at one named source-located boundary per backend",
];

function assertPipelineDocumentation({ expressions, spec, readme, run }) {
  const normalizedExpressions = expressions.replace(/\s+/g, " ");
  const normalizedSpec = spec.replace(/\s+/g, " ");
  const normalizedReadme = readme.replace(/\s+/g, " ");
  const normalizedRun = run.replace(/\s+/g, " ");
  const pipelineDocs = `${normalizedSpec}\n${normalizedReadme}`;

  assert.ok(!normalizedExpressions.includes(
    "current integer Core does not parse, type-check, or lower pipelines"),
  "stale expressions pipeline status");
  assert.ok(normalizedExpressions.includes(
    "Stage 2/C11 now parses, type-checks, and lowers the bounded one-stage"),
  "missing expressions current pipeline status");
  for (const stale of [
    "Recognition is all it is",
    "binding is #1226",
    "pipeline binding (#1226)",
    "Pipeline binding,",
    // #1192 landed. Both halves of the old status are now false, and the
    // second is the more dangerous one to leave lying around: a reader who
    // believed the backends were uncovered would re-derive a differential the
    // corpus already runs.
    "Direct-native/Wasm pipeline behavior is unclaimed and uncovered",
    "#1192 is the sole remaining direct-backend blocker",
    // #1396 landed. The chain is a recognized production, so a document still
    // listing it among the retained refusals sends a reader looking for a
    // boundary that no longer exists.
    "pipeline chains, pipelines with trailing lambdas",
    "member pipeline targets, pipeline chains",
  ]) assert.ok(!pipelineDocs.includes(stale), `stale pipeline status: ${stale}`);
  for (const current of [
    "The subject binds declaration/ABI slot zero",
    "#1190, #1226, #1227, and #1228 are landed",
    "#1226 binds its subject to slot zero, #1227 checks it, and #1228 lowers it",
    "#1192 landed the direct-native and Wasm differential",
    "#1396 is landed and gated by the same task",
  ]) assert.ok(pipelineDocs.includes(current), `missing pipeline status: ${current}`);

  // Each document states the measured backend result in its own right. The
  // three are asserted separately because a reader arrives at exactly one of
  // them, and the sentence they must all carry is what that reader is owed:
  // one shape executes and is compared against C11's own golden, and every
  // other shape has a named boundary rather than a silent gap.
  const nativeBoundary = "Direct-native and Wasm behavior is measured by the same corpus: the labelled Int call executes on both and is compared against the C11 golden, and every other shape stops at one named source-located boundary per backend";
  const nativeOverclaim = /(?:Direct-native[^.]{0,200}\bE2S158\b|\bE2S158\b[^.]{0,200}Direct-native)/i;
  for (const [owner, text] of [
    ["expressions contract", normalizedExpressions],
    ["call-arguments specification", normalizedSpec],
    ["gate README", normalizedReadme],
  ]) {
    assert.ok(text.includes(nativeBoundary), `${owner} missing native/Wasm boundary`);
    assert.ok(!nativeOverclaim.test(text), `${owner} assigns E2S158 to native/Wasm`);
  }

  // #1396. Asserted per document for the same reason as the sentence above: a
  // reader arrives at exactly one of them, and a chain is the shape most
  // likely to be assumed unsupported by someone who read only the other.
  const chainBoundary = "A pipeline chain is that production iterated: it associates left, every stage binds, counts, checks and moves its own subject into slot 0, and the C11 lowering nests each stage inside the next subject rather than adding a second temporary family.";
  for (const [owner, text] of [
    ["call-arguments specification", normalizedSpec],
    ["gate README", normalizedReadme],
  ]) {
    assert.ok(text.includes(chainBoundary), `${owner} missing chain status`);
  }
  assert.ok(!normalizedRun.includes("#882 retains pipeline lowering"),
    "stale call-arguments PASS: #882 retains pipeline lowering");
  for (const current of requiredRunTruth) {
    assert.ok(normalizedRun.includes(current), `missing call-arguments PASS: ${current}`);
  }
}

function rejectsPipelineMutation(name, expected, mutation) {
  assert.throws(
    () => assertPipelineDocumentation({ ...pipelineTruth, ...mutation }),
    (error) => error?.code === "ERR_ASSERTION" && error.message.includes(expected),
    name,
  );
}

/* The three documents wrap the sentence at different columns, so the mutation
 * is built from the sentence itself rather than written out with one file's
 * line breaks baked in. A mutation that silently matched nothing would leave
 * this self-test passing while asserting nothing. */
function withoutNativeBoundary(text) {
  const wrapped = new RegExp(
    "the labelled Int call executes on both and is compared against the C11 golden"
      .split(" ")
      .map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
      .join("\\s+"),
  );
  assert.ok(wrapped.test(text), "native/Wasm boundary mutation matched nothing");
  return text.replace(wrapped, "the labelled Int call executes on both");
}

function withoutExpressionsCurrent(text) {
  return text.replace(
    /Stage 2\/C11 now parses,\s+type-checks,\s+and lowers the bounded one-stage/,
    "Stage 2/C11 recognizes the bounded one-stage",
  );
}

assertPipelineDocumentation(pipelineTruth);
rejectsPipelineMutation("stale expressions status", "stale expressions pipeline status", {
  expressions: `${expressionsDoc}\ncurrent integer Core does not parse, type-check, or lower pipelines`,
});
rejectsPipelineMutation("missing expressions current status",
  "missing expressions current pipeline status", {
    expressions: withoutExpressionsCurrent(expressionsDoc),
  });
rejectsPipelineMutation("stale pipeline PASS", "stale call-arguments PASS", {
  run: `${gateRun}\n#882 retains pipeline lowering`,
});
for (const current of requiredRunTruth) {
  rejectsPipelineMutation(`missing call-arguments PASS: ${current}`,
    `missing call-arguments PASS: ${current}`, { run: gateRun.replace(current, "") });
}
for (const [owner, key, text] of [
  ["expressions contract", "expressions", expressionsDoc],
  ["call-arguments specification", "spec", doc],
  ["gate README", "readme", gateReadme],
]) {
  rejectsPipelineMutation(`missing ${owner} native/Wasm boundary`,
    `${owner} missing native/Wasm boundary`, { [key]: withoutNativeBoundary(text) });
  rejectsPipelineMutation(`${owner} native/Wasm overclaim`,
    `${owner} assigns E2S158 to native/Wasm`, {
      [key]: `${text}\nDirect-native/Wasm pipeline behavior remains at E2S158.`,
    });
}

console.log("call-arguments: grammar and one canonical trailing-lambda spelling: PASS");
console.log("call-arguments: labels bind statically; source evaluation and ABI order stay distinct: PASS");
console.log("call-arguments: ambiguity, diagnostics, pipeline, fingerprint, and no-map lowering: PASS");
console.log("call-arguments: pipeline documentation matches the landed C11 boundary: PASS");

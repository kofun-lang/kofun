#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";

const [sourcePath, emittedCPath, goldenPath, observedPath] = process.argv.slice(2);
if (
  sourcePath === undefined ||
  emittedCPath === undefined ||
  goldenPath === undefined ||
  observedPath === undefined
) {
  throw new Error(
    "usage: check-production-field-access.mjs SOURCE EMITTED_C GOLDEN OBSERVED",
  );
}

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// The emitted C is deliberately small, but a body boundary still cannot be a
// non-greedy regex: braces in strings/comments are not C structure, and the
// next function must never satisfy an assertion about this one.
function matchingDelimiter(source, openAt, open, close) {
  assert.equal(source[openAt], open, `expected ${open} at byte ${openAt}`);
  let depth = 0;
  let state = "code";
  for (let index = openAt; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (state === "line-comment") {
      if (character === "\n") state = "code";
      continue;
    }
    if (state === "block-comment") {
      if (character === "*" && next === "/") {
        state = "code";
        index += 1;
      }
      continue;
    }
    if (state === "string" || state === "character") {
      if (character === "\\") {
        index += 1;
      } else if (
        (state === "string" && character === '"') ||
        (state === "character" && character === "'")
      ) {
        state = "code";
      }
      continue;
    }
    if (character === "/" && next === "/") {
      state = "line-comment";
      index += 1;
    } else if (character === "/" && next === "*") {
      state = "block-comment";
      index += 1;
    } else if (character === '"') {
      state = "string";
    } else if (character === "'") {
      state = "character";
    } else if (character === open) {
      depth += 1;
    } else if (character === close) {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  throw new Error(`unterminated ${open}${close} group at byte ${openAt}`);
}

function semanticCode(source) {
  let output = "";
  let state = "code";
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (state === "line-comment") {
      output += character === "\n" ? "\n" : " ";
      if (character === "\n") state = "code";
    } else if (state === "block-comment") {
      output += " ";
      if (character === "*" && next === "/") {
        output += " ";
        state = "code";
        index += 1;
      }
    } else if (state === "string" || state === "character") {
      output += " ";
      if (character === "\\") {
        if (next !== undefined) output += " ";
        index += 1;
      } else if (
        (state === "string" && character === '"') ||
        (state === "character" && character === "'")
      ) {
        state = "code";
      }
    } else if (character === "/" && next === "/") {
      output += "  ";
      state = "line-comment";
      index += 1;
    } else if (character === "/" && next === "*") {
      output += "  ";
      state = "block-comment";
      index += 1;
    } else if (character === '"') {
      output += " ";
      state = "string";
    } else if (character === "'") {
      output += " ";
      state = "character";
    } else {
      output += character;
    }
  }
  return output;
}

function functionDefinition(emitted, witness) {
  const prefix = `static ${witness.emittedResult} kofun_fn_${witness.functionName}`;
  let searchAt = 0;
  while (true) {
    const start = emitted.indexOf(prefix, searchAt);
    assert.notEqual(start, -1, `production C omitted ${witness.functionName}`);
    const parametersOpen = emitted.indexOf("(", start + prefix.length);
    assert.notEqual(parametersOpen, -1, `${witness.functionName} omitted parameters`);
    const parametersClose = matchingDelimiter(
      emitted,
      parametersOpen,
      "(",
      ")",
    );
    let afterParameters = parametersClose + 1;
    while (/\s/u.test(emitted[afterParameters])) afterParameters += 1;
    if (emitted[afterParameters] === ";") {
      searchAt = afterParameters + 1;
      continue;
    }
    assert.equal(
      emitted[afterParameters],
      "{",
      `${witness.functionName} declaration has no function body`,
    );
    const bodyClose = matchingDelimiter(emitted, afterParameters, "{", "}");
    const header = emitted.slice(start, parametersClose + 1);
    const parameter = header.match(/\b([A-Za-z_][A-Za-z0-9_]*)\s*\)$/u)?.[1];
    assert.notEqual(parameter, undefined, `${witness.functionName} parameter is not named`);
    return {
      body: emitted.slice(afterParameters + 1, bodyClose),
      bodyClose,
      bodyOpen: afterParameters,
      parameter,
    };
  }
}

function assertProductionFieldReads(emitted, witnesses) {
  for (const witness of witnesses) {
    const definition = functionDefinition(emitted, witness);
    const body = semanticCode(definition.body);
    const member = `${definition.parameter}.f_${witness.field}`;
    const memberPattern = new RegExp(`\\b${escapeRegex(member)}\\b`, "gu");
    const resultPattern = new RegExp(
      `\\bkofun_result\\s*=\\s*${escapeRegex(member)}\\s*;`,
      "gu",
    );
    assert.equal(
      [...body.matchAll(memberPattern)].length,
      1,
      `${witness.functionName} must read exactly one ${member} inside its own body`,
    );
    assert.equal(
      [...body.matchAll(resultPattern)].length,
      1,
      `${witness.functionName} must initialize kofun_result from ${member}`,
    );
    assert.equal(
      [...body.matchAll(/\bkofun_result\s*=/gu)].length,
      1,
      `${witness.functionName} must initialize kofun_result exactly once`,
    );
  }
}

function replaceAccessorMember(emitted, witness, replacement) {
  const definition = functionDefinition(emitted, witness);
  const member = `${definition.parameter}.f_${witness.field}`;
  assert.equal(
    definition.body.split(member).length - 1,
    1,
    `mutation expected exactly one ${member} in ${witness.functionName}`,
  );
  const mutantBody = definition.body.replace(member, replacement);
  return emitted.slice(0, definition.bodyOpen + 1) +
    mutantBody + emitted.slice(definition.bodyClose);
}

try {
  const source = fs.readFileSync(sourcePath, "utf8");
  const emitted = fs.readFileSync(emittedCPath, "utf8");
  const golden = fs.readFileSync(goldenPath);
  const observed = fs.readFileSync(observedPath);
  const witnesses = [
    {
      functionName: "report_identity",
      field: "identity",
      sourceResult: "Text",
      emittedResult: "const char *",
    },
    {
      functionName: "report_samples",
      field: "samples",
      sourceResult: "List[Int]",
      emittedResult: "KofunIntListValue",
    },
    {
      functionName: "report_count",
      field: "count",
      sourceResult: "Int",
      emittedResult: "int64_t",
    },
  ];

  for (const witness of witnesses) {
    const sourceFunction = [
      `fn ${witness.functionName}(report: BridgeReport) -> ${witness.sourceResult} {`,
      `    return report.${witness.field}`,
      "}",
    ].join("\n");
    assert.ok(
      source.includes(sourceFunction),
      `raw source omitted the ${witness.functionName} selector witness`,
    );
  }
  assertProductionFieldReads(emitted, witnesses);

  // These mutations hold the exact false positive this checker once had: an
  // accessor returns the fixture value without reading its parameter, while a
  // same-named member occurrence remains later in main.
  const constantReturnMutant = replaceAccessorMember(
    emitted,
    witnesses[0],
    '"古墳-日本語"',
  );
  assert.throws(
    () => assertProductionFieldReads(constantReturnMutant, [witnesses[0]]),
    /must read exactly one/u,
    "a constant-return accessor mutation must be refused",
  );

  const identityDefinition = functionDefinition(emitted, witnesses[0]);
  const decoy = `${identityDefinition.parameter}.f_identity`;
  const stringAndCommentDecoyMutant = replaceAccessorMember(
    emitted,
    witnesses[0],
    `"${decoy} }" /* ${decoy} { */`,
  );
  assert.throws(
    () => assertProductionFieldReads(stringAndCommentDecoyMutant, [witnesses[0]]),
    /must read exactly one/u,
    "string/comment member decoys and their braces must be ignored",
  );

  const followingMainOnlyMutant = replaceAccessorMember(
    emitted,
    witnesses[1],
    "KOFUN_LIST_INT_ZERO",
  );
  assert.ok(
    followingMainOnlyMutant.slice(
      functionDefinition(followingMainOnlyMutant, witnesses[1]).bodyClose + 1,
    ).includes(".f_samples"),
    "the following-main-only mutation lost its later f_samples witness",
  );
  assert.throws(
    () => assertProductionFieldReads(followingMainOnlyMutant, [witnesses[1]]),
    /must read exactly one/u,
    "a later main member access must not satisfy the accessor-body check",
  );

  assert.equal(
    observed.equals(golden),
    true,
    "production runtime bytes differ from the committed golden",
  );
  const utf8Line = Buffer.from("古墳-日本語\n", "utf8");
  assert.equal(golden.subarray(0, utf8Line.length).equals(utf8Line), true);
  assert.equal(golden.includes(Buffer.from([0xef, 0xbf, 0xbd])), false);

  console.log(
    "PASS: raw source selectors are syntax witnesses only and are outside typed-sidecar acceptance",
  );
  console.log(
    "PASS: production emitted C reads identity/samples/count members and its runtime matches the exact UTF-8 golden",
  );
  console.log(
    "PASS: constant-return, string/comment-decoy, and following-main-only field-access mutations are refused",
  );
} catch (error) {
  console.error(`aggregate-bridge production field access: ${error.message}`);
  process.exitCode = 1;
}

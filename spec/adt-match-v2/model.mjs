/*
 * ADT match v2, as a pure model.
 *
 * Ten decisions were settled on #1281. Most of them are the kind that read as
 * obviously right in prose and have two plausible implementations, so this
 * file makes each one something a mutation can break:
 *
 *   - or-alternatives must bind the same names, types, paths, and modes;
 *   - a guarded arm never counts toward exhaustiveness;
 *   - a result join is exact TypeRef equality with no implicit conversion;
 *   - a take-arm transfers the whole payload, never a field;
 *   - budget exhaustion is a stable error, never an implicit accept.
 *
 * It resolves no real types and lowers nothing. Constructors, TypeRefs, and
 * binding modes are opaque strings, because every rule here is about their
 * *identity* rather than their content — and a model that carried real types
 * would let a bug hide behind type machinery this profile does not own.
 */

/* Decision 9. Changing a number is a versioned profile revision. */
export const LIMITS = Object.freeze({
  constructorsPerEnum: 64,
  armsPerMatch: 64,
  alternativesPerArm: 8,
  patternNodesPerMatch: 512,
  nestingDepth: 16,
  matrixCells: 65536,
});

export const PATTERN_KINDS = Object.freeze([
  "constructor",
  "wildcard",
  "binding",
  "parenthesized",
  "or",
  "int-literal",
]);

/* Decision 2: ranges and record subpatterns are refused in v2, by name. */
export const REFUSED_PATTERN_KINDS = Object.freeze(["range", "record-subpattern"]);

export class Refusal extends Error {
  constructor(code, detail) {
    super(`${code}: ${detail}`);
    this.code = code;
    this.detail = detail;
  }
}

const refuse = (code, detail) => {
  throw new Refusal(code, detail);
};

function countNodes(pattern) {
  if (pattern.kind === "or") {
    return 1 + pattern.alternatives.reduce((n, a) => n + countNodes(a), 0);
  }
  if (pattern.kind === "constructor" && pattern.payload) return 1 + countNodes(pattern.payload);
  if (pattern.kind === "parenthesized") return 1 + countNodes(pattern.inner);
  return 1;
}

function depthOf(pattern) {
  if (pattern.kind === "or") {
    return 1 + Math.max(0, ...pattern.alternatives.map(depthOf));
  }
  if (pattern.kind === "constructor" && pattern.payload) return 1 + depthOf(pattern.payload);
  if (pattern.kind === "parenthesized") return 1 + depthOf(pattern.inner);
  return 1;
}

/*
 * Decision 3. A binding is identified by name, resolved type, field path, and
 * ownership mode — all four. Comparing names alone is the implementation an
 * unwary reader writes, and it accepts `Some(x)` and `Other(x)` binding
 * different types under one name.
 */
function bindingsOf(pattern, path = []) {
  switch (pattern.kind) {
    case "binding":
      return [{ name: pattern.name, type: pattern.type, path: path.join("."), mode: pattern.mode }];
    case "constructor":
      return pattern.payload ? bindingsOf(pattern.payload, [...path, pattern.constructor]) : [];
    case "parenthesized":
      return bindingsOf(pattern.inner, path);
    case "or":
      return pattern.alternatives.flatMap((a) => bindingsOf(a, path));
    default:
      return [];
  }
}

/*
 * The identity of a binding, injectable so a checker that compares fewer of
 * the four parts can be *run* rather than argued about. Decision 3 says all
 * four; the mutation that passes a name-only key is what proves the other
 * three are load-bearing.
 */
export const FULL_BINDING_KEY = (b) => `${b.name}:${b.type}:${b.path}:${b.mode}`;

function checkOrAlternatives(pattern, bindingKey = FULL_BINDING_KEY) {
  if (pattern.kind === "parenthesized") return checkOrAlternatives(pattern.inner, bindingKey);
  if (pattern.kind === "constructor" && pattern.payload) return checkOrAlternatives(pattern.payload, bindingKey);
  if (pattern.kind !== "or") return;

  if (pattern.alternatives.length > LIMITS.alternativesPerArm) {
    refuse("BudgetExhausted", `${pattern.alternatives.length} or-alternatives exceeds ${LIMITS.alternativesPerArm}`);
  }

  const signatures = pattern.alternatives.map((alternative) => {
    const bindings = bindingsOf(alternative).map(bindingKey).sort();
    return bindings.join("|");
  });
  const first = signatures[0];
  for (let i = 1; i < signatures.length; i += 1) {
    if (signatures[i] !== first) {
      refuse(
        "OrAlternativeBindingMismatch",
        `alternative ${i} binds \`${signatures[i] || "nothing"}\`, alternative 0 binds \`${first || "nothing"}\``,
      );
    }
  }
  for (const alternative of pattern.alternatives) checkOrAlternatives(alternative, bindingKey);
}

/*
 * Decision 1. Zero or one payload TypeRef. Multiple logical fields use one
 * nominal record payload; there is no tuple layout and no tuple syntax.
 */
export function checkConstructorDeclaration(constructor) {
  if (!Array.isArray(constructor.payload)) refuse("MalformedDeclaration", constructor.name);
  if (constructor.payload.length > 1) {
    refuse(
      "MultiplePayloads",
      `\`${constructor.name}\` declares ${constructor.payload.length} payload TypeRefs; use one nominal record`,
    );
  }
}

export function checkEnumDeclaration(enumeration) {
  if (enumeration.constructors.length > LIMITS.constructorsPerEnum) {
    refuse("BudgetExhausted", `${enumeration.constructors.length} constructors exceeds ${LIMITS.constructorsPerEnum}`);
  }
  for (const constructor of enumeration.constructors) checkConstructorDeclaration(constructor);
}

/*
 * `match` is { scrutineeMode, arms: [{ pattern, guard, resultType, terminates }] }.
 * `enumeration` is { name, constructors: [{ name, payload: [TypeRef] }] }.
 */
export function checkMatch(match, enumeration, options = {}) {
  const bindingKey = options.bindingKey ?? FULL_BINDING_KEY;
  checkEnumDeclaration(enumeration);

  if (match.arms.length > LIMITS.armsPerMatch) {
    refuse("BudgetExhausted", `${match.arms.length} arms exceeds ${LIMITS.armsPerMatch}`);
  }

  let nodes = 0;
  for (const arm of match.arms) {
    for (const kind of REFUSED_PATTERN_KINDS) {
      if (JSON.stringify(arm.pattern).includes(`"${kind}"`)) {
        refuse("RefusedPatternKind", `${kind} is not admitted in v2`);
      }
    }
    nodes += countNodes(arm.pattern);
    if (depthOf(arm.pattern) > LIMITS.nestingDepth) {
      refuse("BudgetExhausted", `nesting depth exceeds ${LIMITS.nestingDepth}`);
    }
    checkOrAlternatives(arm.pattern, bindingKey);
  }
  if (nodes > LIMITS.patternNodesPerMatch) {
    refuse("BudgetExhausted", `${nodes} pattern nodes exceeds ${LIMITS.patternNodesPerMatch}`);
  }

  /*
   * Decision 4. The mode is inherited from the scrutinee expression; there is
   * no per-arm choice and no hidden clone.
   */
  for (const arm of match.arms) {
    for (const binding of bindingsOf(arm.pattern)) {
      if (binding.mode !== match.scrutineeMode) {
        refuse(
          "BindingModeMismatch",
          `binding \`${binding.name}\` is \`${binding.mode}\` under a \`${match.scrutineeMode}\` scrutinee`,
        );
      }
    }
  }

  /*
   * Decision 5. A take-arm transfers the whole selected payload. A field path
   * deeper than the constructor means a field-level take, which waits for the
   * general place/move contract.
   */
  if (match.scrutineeMode === "take") {
    for (const arm of match.arms) {
      for (const binding of bindingsOf(arm.pattern)) {
        if (binding.path.includes(".")) {
          refuse("FieldLevelTake", `\`${binding.name}\` at \`${binding.path}\` is a field-level take`);
        }
      }
    }
  }

  /* Decision 7. A guarded arm never counts toward coverage. */
  const covering = match.arms.filter((arm) => !arm.guard);
  const covered = new Set();
  let catchAll = false;
  for (const arm of covering) {
    for (const constructor of constructorsCovered(arm.pattern)) {
      if (constructor === "*") catchAll = true;
      else covered.add(constructor);
    }
  }

  const missing = enumeration.constructors
    .map((c) => c.name)
    .filter((name) => !covered.has(name));
  if (!catchAll && missing.length > 0) {
    /* Decision 8. Witnesses follow nominal declaration order. */
    refuse("NonExhaustive", missing.join(", "));
  }

  /* Redundancy is reported per arm and per alternative. */
  const seen = new Set();
  for (const arm of covering) {
    for (const constructor of constructorsCovered(arm.pattern)) {
      if (constructor === "*") continue;
      if (seen.has(constructor)) refuse("RedundantArm", constructor);
      seen.add(constructor);
    }
  }

  /*
   * Decision 6. Exact canonical TypeRef equality across reachable arms. No
   * implicit numeric conversion. A terminating arm participates only if
   * `Never` is represented, which v2 says it is not.
   */
  const reachable = match.arms.filter((arm) => !arm.terminates);
  const types = [...new Set(reachable.map((arm) => arm.resultType))];
  if (types.length > 1) {
    refuse("ResultJoinMismatch", types.join(" vs "));
  }
  if (match.arms.some((arm) => arm.terminates) && match.neverRepresented !== true) {
    if (reachable.length === 0) refuse("NeverNotRepresented", "every arm terminates");
  }

  return {
    resultType: types[0] ?? "Never",
    coveredConstructors: [...covered].sort(),
    catchAll,
    guardedArms: match.arms.length - covering.length,
    patternNodes: nodes,
  };
}

function constructorsCovered(pattern) {
  switch (pattern.kind) {
    case "constructor":
      return [pattern.constructor];
    case "wildcard":
    case "binding":
      return ["*"];
    case "parenthesized":
      return constructorsCovered(pattern.inner);
    case "or":
      return pattern.alternatives.flatMap(constructorsCovered);
    default:
      return [];
  }
}

/* Small builders, so vectors read like the source they stand for. */
export const ctor = (name, payload = null) => ({ kind: "constructor", constructor: name, payload });
export const bind = (name, type, mode = "read") => ({ kind: "binding", name, type, mode });
export const wild = () => ({ kind: "wildcard" });
export const or = (...alternatives) => ({ kind: "or", alternatives });

export function vectors() {
  const reply = {
    name: "Reply",
    constructors: [
      { name: "Ready", payload: ["Point"] },
      { name: "Waiting", payload: [] },
      { name: "Failed", payload: ["Int"] },
    ],
  };
  const cases = [];
  const record = (name, run) => {
    try {
      cases.push({ name, result: run() });
    } catch (error) {
      if (!(error instanceof Refusal)) throw error;
      cases.push({ name, refusal: { code: error.code, detail: error.detail } });
    }
  };

  record("exhaustive over three constructors", () =>
    checkMatch(
      {
        scrutineeMode: "read",
        arms: [
          { pattern: ctor("Ready", bind("p", "Point")), resultType: "Int" },
          { pattern: ctor("Waiting"), resultType: "Int" },
          { pattern: ctor("Failed", bind("c", "Int")), resultType: "Int" },
        ],
      },
      reply,
    ));

  record("a missing constructor is non-exhaustive", () =>
    checkMatch(
      { scrutineeMode: "read", arms: [{ pattern: ctor("Ready", bind("p", "Point")), resultType: "Int" }] },
      reply,
    ));

  record("a guarded arm does not cover", () =>
    checkMatch(
      {
        scrutineeMode: "read",
        arms: [
          { pattern: ctor("Ready", bind("p", "Point")), guard: true, resultType: "Int" },
          { pattern: ctor("Waiting"), resultType: "Int" },
          { pattern: ctor("Failed", bind("c", "Int")), resultType: "Int" },
        ],
      },
      reply,
    ));

  record("or-alternatives binding different names refuse", () =>
    checkMatch(
      {
        scrutineeMode: "read",
        arms: [
          { pattern: or(ctor("Ready", bind("p", "Point")), ctor("Failed", bind("q", "Int"))), resultType: "Int" },
          { pattern: wild(), resultType: "Int" },
        ],
      },
      reply,
    ));

  record("a result join mismatch refuses", () =>
    checkMatch(
      {
        scrutineeMode: "read",
        arms: [
          { pattern: ctor("Ready", bind("p", "Point")), resultType: "Int" },
          { pattern: wild(), resultType: "Text" },
        ],
      },
      reply,
    ));

  record("two payload TypeRefs refuse", () =>
    checkEnumDeclaration({ name: "Pair", constructors: [{ name: "Both", payload: ["Int", "Int"] }] }));

  record("a field-level take refuses", () =>
    checkMatch(
      {
        scrutineeMode: "take",
        arms: [
          { pattern: ctor("Ready", ctor("Inner", bind("p", "Point", "take"))), resultType: "Int" },
          { pattern: wild(), resultType: "Int" },
        ],
      },
      reply,
    ));

  record("a redundant arm refuses", () =>
    checkMatch(
      {
        scrutineeMode: "read",
        arms: [
          { pattern: ctor("Ready", bind("p", "Point")), resultType: "Int" },
          { pattern: ctor("Ready", bind("p", "Point")), resultType: "Int" },
          { pattern: wild(), resultType: "Int" },
        ],
      },
      reply,
    ));

  record("too many or-alternatives exhausts the budget", () =>
    checkMatch(
      {
        scrutineeMode: "read",
        arms: [{ pattern: or(...Array.from({ length: 9 }, () => wild())), resultType: "Int" }],
      },
      reply,
    ));

  return cases;
}

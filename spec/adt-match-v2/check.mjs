/*
 * The ADT match v2 contract gate.
 *
 *     node spec/adt-match-v2/check.mjs
 *     node spec/adt-match-v2/check.mjs --vectors
 *
 * Ten decisions, each asserted as a property and each attacked by a mutation
 * that a reader of the profile could plausibly write. The mutations matter
 * more than the properties here: every one of them produces a checker that
 * accepts all the correct programs and differs only on the ones the profile
 * exists to refuse.
 */

import {
  LIMITS,
  REFUSED_PATTERN_KINDS,
  Refusal,
  checkMatch,
  checkEnumDeclaration,
  ctor,
  bind,
  wild,
  or,
  vectors,
} from "./model.mjs";

class Broken extends Error {}
const require_ = (claim, ok) => { if (!ok) throw new Broken(claim); };

const reply = {
  name: "Reply",
  constructors: [
    { name: "Ready", payload: ["Point"] },
    { name: "Waiting", payload: [] },
    { name: "Failed", payload: ["Int"] },
  ],
};

const codeOf = (run) => {
  try { run(); } catch (error) {
    if (error instanceof Refusal) return error.code;
    throw error;
  }
  return null;
};

const exhaustive = (extra = {}) => ({
  scrutineeMode: "read",
  arms: [
    { pattern: ctor("Ready", bind("p", "Point")), resultType: "Int" },
    { pattern: ctor("Waiting"), resultType: "Int" },
    { pattern: ctor("Failed", bind("c", "Int")), resultType: "Int" },
  ],
  ...extra,
});

const PROPERTIES = {
  "1. one payload TypeRef per constructor": (m) =>
    require_(
      "two payloads refuse",
      codeOf(() => m.checkEnumDeclaration({ name: "P", constructors: [{ name: "B", payload: ["Int", "Int"] }] })) ===
        "MultiplePayloads",
    ),

  "2. ranges and record subpatterns are refused by name": (m) => {
    for (const kind of REFUSED_PATTERN_KINDS) {
      require_(
        `${kind} refused`,
        codeOf(() =>
          m.checkMatch({ scrutineeMode: "read", arms: [{ pattern: { kind }, resultType: "Int" }] }, reply),
        ) === "RefusedPatternKind",
      );
    }
  },

  "3. or-alternatives bind identical name, type, path, and mode": (m) => {
    require_(
      "different names refuse",
      codeOf(() =>
        m.checkMatch(
          {
            scrutineeMode: "read",
            arms: [
              { pattern: or(ctor("Ready", bind("p", "Point")), ctor("Failed", bind("q", "Int"))), resultType: "Int" },
              { pattern: wild(), resultType: "Int" },
            ],
          },
          reply,
        ),
      ) === "OrAlternativeBindingMismatch",
    );
    require_(
      "same name, different type refuses",
      codeOf(() =>
        m.checkMatch(
          {
            scrutineeMode: "read",
            arms: [
              { pattern: or(ctor("Ready", bind("p", "Point")), ctor("Failed", bind("p", "Int"))), resultType: "Int" },
              { pattern: wild(), resultType: "Int" },
            ],
          },
          reply,
        ),
      ) === "OrAlternativeBindingMismatch",
    );
  },

  "4. the binding mode is inherited from the scrutinee": (m) =>
    require_(
      "a take binding under a read scrutinee refuses",
      codeOf(() =>
        m.checkMatch(
          {
            scrutineeMode: "read",
            arms: [
              { pattern: ctor("Ready", bind("p", "Point", "take")), resultType: "Int" },
              { pattern: wild(), resultType: "Int" },
            ],
          },
          reply,
        ),
      ) === "BindingModeMismatch",
    ),

  "5. a take transfers the whole payload, never a field": (m) =>
    require_(
      "a nested take refuses",
      codeOf(() =>
        m.checkMatch(
          {
            scrutineeMode: "take",
            arms: [
              { pattern: ctor("Ready", ctor("Inner", bind("p", "Point", "take"))), resultType: "Int" },
              { pattern: wild(), resultType: "Int" },
            ],
          },
          reply,
        ),
      ) === "FieldLevelTake",
    ),

  "6. the result join is exact TypeRef equality": (m) => {
    require_(
      "Int vs Text refuses",
      codeOf(() =>
        m.checkMatch(
          {
            scrutineeMode: "read",
            arms: [
              { pattern: ctor("Ready", bind("p", "Point")), resultType: "Int" },
              { pattern: wild(), resultType: "Text" },
            ],
          },
          reply,
        ),
      ) === "ResultJoinMismatch",
    );
    require_("a uniform join is accepted", m.checkMatch(exhaustive(), reply).resultType === "Int");
  },

  "7. a guarded arm never covers": (m) => {
    const guarded = exhaustive();
    guarded.arms[0] = { ...guarded.arms[0], guard: true };
    require_(
      "coverage falls through",
      codeOf(() => m.checkMatch(guarded, reply)) === "NonExhaustive",
    );
  },

  "8. missing witnesses follow declaration order": (m) => {
    let detail = null;
    try {
      m.checkMatch({ scrutineeMode: "read", arms: [{ pattern: ctor("Ready", bind("p", "Point")), resultType: "Int" }] }, reply);
    } catch (error) {
      detail = error.detail;
    }
    require_("Waiting before Failed", detail === "Waiting, Failed");
  },

  "9. exhausting a budget is a stable error": (m) => {
    require_(
      "too many alternatives",
      codeOf(() =>
        m.checkMatch(
          { scrutineeMode: "read", arms: [{ pattern: or(...Array.from({ length: LIMITS.alternativesPerArm + 1 }, wild)), resultType: "Int" }] },
          reply,
        ),
      ) === "BudgetExhausted",
    );
    require_(
      "too many constructors",
      codeOf(() =>
        m.checkEnumDeclaration({
          name: "Wide",
          constructors: Array.from({ length: LIMITS.constructorsPerEnum + 1 }, (_, i) => ({ name: `C${i}`, payload: [] })),
        }),
      ) === "BudgetExhausted",
    );
  },

  "10. redundancy is reported per arm": (m) => {
    const duplicated = exhaustive();
    duplicated.arms.push({ pattern: ctor("Ready", bind("p", "Point")), resultType: "Int" });
    require_("a repeat refuses", codeOf(() => m.checkMatch(duplicated, reply)) === "RedundantArm");
  },

  "an exhaustive match is accepted": (m) => {
    const out = m.checkMatch(exhaustive(), reply);
    require_("three constructors covered", out.coveredConstructors.length === 3);
    require_("no catch-all needed", out.catchAll === false);
  },
};

const MODULE = { checkMatch, checkEnumDeclaration };

const MUTATIONS = {
  "compare or-alternative bindings by name only": (m) => ({
    ...m,
    checkMatch: (match, enumeration) => m.checkMatch(match, enumeration, { bindingKey: (b) => b.name }),
  }),
  "let a guarded arm cover its constructor": (m) => ({
    ...m,
    checkMatch: (match, enumeration) =>
      m.checkMatch({ ...match, arms: match.arms.map((a) => ({ ...a, guard: false })) }, enumeration),
  }),
  "widen the result join to any two types": (m) => ({
    ...m,
    checkMatch: (match, enumeration) =>
      m.checkMatch({ ...match, arms: match.arms.map((a) => ({ ...a, resultType: "Int" })) }, enumeration),
  }),
  "allow a field-level take": (m) => ({
    ...m,
    checkMatch: (match, enumeration) =>
      m.checkMatch(match.scrutineeMode === "take" ? { ...match, scrutineeMode: "read" } : match, enumeration),
  }),
  "accept two payload TypeRefs": (m) => ({
    ...m,
    checkEnumDeclaration: (e) =>
      m.checkEnumDeclaration({ ...e, constructors: e.constructors.map((c) => ({ ...c, payload: c.payload.slice(0, 1) })) }),
  }),
  "treat budget exhaustion as acceptance": (m) => ({
    ...m,
    checkMatch: (match, enumeration) => {
      try {
        return m.checkMatch(match, enumeration);
      } catch (error) {
        if (error instanceof Refusal && error.code === "BudgetExhausted") return { resultType: "Int", coveredConstructors: [], catchAll: true };
        throw error;
      }
    },
    checkEnumDeclaration: (e) => {
      try {
        return m.checkEnumDeclaration(e);
      } catch (error) {
        if (error instanceof Refusal && error.code === "BudgetExhausted") return undefined;
        throw error;
      }
    },
  }),
  "sort missing witnesses alphabetically": (m) => ({
    ...m,
    checkMatch: (match, enumeration) => {
      try {
        return m.checkMatch(match, enumeration);
      } catch (error) {
        if (error instanceof Refusal && error.code === "NonExhaustive") {
          throw new Refusal("NonExhaustive", error.detail.split(", ").sort().join(", "));
        }
        throw error;
      }
    },
  }),
  "ignore the scrutinee mode on bindings": (m) => ({
    ...m,
    checkMatch: (match, enumeration) => {
      const normalized = JSON.parse(JSON.stringify(match));
      const fix = (p) => {
        if (p.kind === "binding") p.mode = normalized.scrutineeMode;
        if (p.kind === "constructor" && p.payload) fix(p.payload);
        if (p.kind === "or") p.alternatives.forEach(fix);
        if (p.kind === "parenthesized") fix(p.inner);
      };
      normalized.arms.forEach((a) => fix(a.pattern));
      return m.checkMatch(normalized, enumeration);
    },
  }),
  "admit a refused pattern kind": (m) => ({
    ...m,
    checkMatch: (match, enumeration) =>
      m.checkMatch(
        { ...match, arms: match.arms.map((a) => (REFUSED_PATTERN_KINDS.includes(a.pattern.kind) ? { ...a, pattern: wild() } : a)) },
        enumeration,
      ),
  }),
  "drop the redundancy check": (m) => ({
    ...m,
    checkMatch: (match, enumeration) => {
      const seen = new Set();
      const unique = match.arms.filter((a) => {
        const key = JSON.stringify(a.pattern);
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      });
      return m.checkMatch({ ...match, arms: unique }, enumeration);
    },
  }),
};

function runProperties(module) {
  const failures = [];
  for (const [claim, check] of Object.entries(PROPERTIES)) {
    try { check(module); } catch (error) {
      if (!(error instanceof Broken)) throw error;
      failures.push(claim);
    }
  }
  return failures;
}

function main(argv) {
  if (argv.includes("--vectors")) {
    process.stdout.write(JSON.stringify(vectors(), null, 2) + "\n");
    return;
  }
  const failures = runProperties(MODULE);
  if (failures.length > 0) {
    for (const f of failures) process.stderr.write(`FAIL: ${f}\n`);
    process.exit(1);
  }
  const caughtBy = new Map();
  for (const [label, mutate] of Object.entries(MUTATIONS)) {
    const broken = runProperties(mutate(MODULE));
    if (broken.length === 0) {
      process.stderr.write(`FAIL: mutation \`${label}\` was caught by no property\n`);
      process.exit(1);
    }
    const signature = broken.sort().join(" + ");
    if (caughtBy.has(signature)) {
      process.stderr.write(`FAIL: mutations \`${caughtBy.get(signature)}\` and \`${label}\` are caught by the same properties (${signature})\n`);
      process.exit(1);
    }
    caughtBy.set(signature, label);
  }
  process.stdout.write(
    `PASS: ${Object.keys(PROPERTIES).length} profile properties hold, covering all ten decisions\n` +
      `PASS: ${Object.keys(MUTATIONS).length} plausible checker mistakes are each caught, by a distinct property set\n`,
  );
}

main(process.argv.slice(2));

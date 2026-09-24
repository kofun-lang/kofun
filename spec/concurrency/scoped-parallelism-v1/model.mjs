#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const MODEL_SCHEMA = "kofun.scoped-parallelism-model/v1";
export const RESULT_SCHEMA = "kofun.scoped-parallelism-model-result/v1";

const LIMITS = Object.freeze({
  inputBytes: 64 * 1024,
  tasks: 64,
  capturesPerTask: 64,
  parentActions: 256,
  projectionDepth: 8,
  textBytes: 96,
});

const MODES = new Set(["read", "edit", "take"]);
const OUTCOMES = new Set(["success", "panic", "cancelled"]);
const HANDLE_USES = new Set(["none", "return", "store", "capture", "pass"]);
const IDENTIFIER = /^[A-Za-z][A-Za-z0-9_-]*$/;

class InvalidModel extends Error {
  constructor(path, detail) {
    super(`${path}: ${detail}`);
    this.path = path;
    this.detail = detail;
  }
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function object(value, path) {
  if (!isObject(value)) throw new InvalidModel(path, "expected object");
  return value;
}

function exactKeys(value, allowed, path) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new InvalidModel(`${path}.${key}`, "unknown field");
  }
}

function array(value, path, maximum) {
  if (!Array.isArray(value)) throw new InvalidModel(path, "expected array");
  if (value.length > maximum) {
    throw new InvalidModel(path, `limit exceeded (${value.length} > ${maximum})`);
  }
  return value;
}

function integer(value, path, minimum = 0) {
  if (!Number.isSafeInteger(value) || value < minimum) {
    throw new InvalidModel(path, `expected integer >= ${minimum}`);
  }
  return value;
}

function text(value, path, { identifier = false } = {}) {
  if (typeof value !== "string" || value.length === 0) {
    throw new InvalidModel(path, "expected non-empty text");
  }
  if (Buffer.byteLength(value, "utf8") > LIMITS.textBytes) {
    throw new InvalidModel(path, "text limit exceeded");
  }
  if (identifier && !IDENTIFIER.test(value)) {
    throw new InvalidModel(path, "expected stable identifier");
  }
  return value;
}

function bound(value, path) {
  if (Number.isSafeInteger(value)) return value;
  return text(value, path, { identifier: true });
}

// An explicit unknown place (scoped-captures-v1 §5) names no base and no
// projections, so no rule in §6 can prove it disjoint from anything.
function normalizePlace(value, path) {
  const source = object(value, path);
  if (Object.hasOwn(source, "unknown")) {
    exactKeys(source, new Set(["unknown"]), path);
    return Object.freeze({ unknown: text(source.unknown, `${path}.unknown`, { identifier: true }) });
  }
  exactKeys(source, new Set(["base", "path"]), path);
  const projections = array(source.path ?? [], `${path}.path`, LIMITS.projectionDepth)
    .map((projection, index) => {
      const projectionPath = `${path}.path[${index}]`;
      const item = object(projection, projectionPath);
      exactKeys(item, new Set(["field", "slice"]), projectionPath);
      const hasField = Object.hasOwn(item, "field");
      const hasSlice = Object.hasOwn(item, "slice");
      if (hasField === hasSlice) {
        throw new InvalidModel(projectionPath, "expected exactly one field or slice");
      }
      if (hasField) {
        return Object.freeze({ kind: "field", name: text(item.field, `${projectionPath}.field`, { identifier: true }) });
      }
      const range = array(item.slice, `${projectionPath}.slice`, 2);
      if (range.length !== 2) {
        throw new InvalidModel(`${projectionPath}.slice`, "expected [start, end]");
      }
      const start = bound(range[0], `${projectionPath}.slice[0]`);
      const end = bound(range[1], `${projectionPath}.slice[1]`);
      if (typeof start === "number" && typeof end === "number" && start > end) {
        throw new InvalidModel(`${projectionPath}.slice`, "start must not exceed end");
      }
      return Object.freeze({ kind: "slice", start, end });
    });
  return Object.freeze({
    base: text(source.base, `${path}.base`, { identifier: true }),
    path: Object.freeze(projections),
  });
}

function normalizeCapture(value, path) {
  const source = object(value, path);
  exactKeys(source, new Set(["mode", "place"]), path);
  if (!MODES.has(source.mode)) throw new InvalidModel(`${path}.mode`, "expected read, edit, or take");
  return Object.freeze({ mode: source.mode, place: normalizePlace(source.place, `${path}.place`) });
}

function normalizeTask(value, path, exitStep) {
  const source = object(value, path);
  exactKeys(source, new Set([
    "id", "spawn_step", "join_step", "captures", "outcome", "result", "handle_use",
  ]), path);
  const spawnStep = integer(source.spawn_step, `${path}.spawn_step`, 1);
  let joinStep = null;
  if (Object.hasOwn(source, "join_step")) {
    joinStep = integer(source.join_step, `${path}.join_step`, 1);
    if (joinStep <= spawnStep || joinStep >= exitStep) {
      throw new InvalidModel(`${path}.join_step`, "must be after spawn and strictly before scope exit");
    }
  }
  const outcome = source.outcome ?? "success";
  if (!OUTCOMES.has(outcome)) {
    throw new InvalidModel(`${path}.outcome`, "expected success, panic, or cancelled");
  }
  if (outcome !== "success" && Object.hasOwn(source, "result")) {
    throw new InvalidModel(`${path}.result`, "only a successful task has a result");
  }
  const handleUse = source.handle_use ?? "none";
  if (!HANDLE_USES.has(handleUse)) {
    throw new InvalidModel(`${path}.handle_use`, "unsupported handle use");
  }
  const captures = array(source.captures ?? [], `${path}.captures`, LIMITS.capturesPerTask)
    .map((capture, index) => normalizeCapture(capture, `${path}.captures[${index}]`));
  return Object.freeze({
    id: text(source.id, `${path}.id`, { identifier: true }),
    spawnStep,
    joinStep,
    captures: Object.freeze(captures),
    outcome,
    result: Object.hasOwn(source, "result") ? text(source.result, `${path}.result`) : null,
    handleUse,
  });
}

function normalizeParentAction(value, path, exitStep) {
  const source = object(value, path);
  exactKeys(source, new Set(["step", "mode", "place"]), path);
  if (!MODES.has(source.mode)) throw new InvalidModel(`${path}.mode`, "expected read, edit, or take");
  const step = integer(source.step, `${path}.step`, 1);
  if (step >= exitStep) throw new InvalidModel(`${path}.step`, "must be strictly before scope exit");
  return Object.freeze({ step, mode: source.mode, place: normalizePlace(source.place, `${path}.place`) });
}

function normalize(input) {
  const root = object(input, "$input");
  exactKeys(root, new Set(["schema", "scope"]), "$input");
  if (root.schema !== MODEL_SCHEMA) throw new InvalidModel("$input.schema", `expected ${MODEL_SCHEMA}`);
  const scope = object(root.scope, "$input.scope");
  exactKeys(scope, new Set(["exit_step", "cancellation_step", "tasks", "parent_actions"]), "$input.scope");
  const exitStep = integer(scope.exit_step, "$input.scope.exit_step", 2);
  let cancellationStep = null;
  if (Object.hasOwn(scope, "cancellation_step")) {
    cancellationStep = integer(scope.cancellation_step, "$input.scope.cancellation_step", 1);
    if (cancellationStep > exitStep) {
      throw new InvalidModel("$input.scope.cancellation_step", "must be at or before scope exit");
    }
  }
  const tasks = array(scope.tasks, "$input.scope.tasks", LIMITS.tasks)
    .map((task, index) => normalizeTask(task, `$input.scope.tasks[${index}]`, exitStep));
  const ids = new Set();
  const lifecycleSteps = new Map();
  for (const task of tasks) {
    if (ids.has(task.id)) throw new InvalidModel("$input.scope.tasks", `duplicate task id ${task.id}`);
    ids.add(task.id);
    if (task.spawnStep >= exitStep) {
      throw new InvalidModel(`$input.scope.tasks.${task.id}.spawn_step`, "must be before scope exit");
    }
    for (const [kind, step] of [["spawn", task.spawnStep], ["join", task.joinStep]]) {
      if (step === null) continue;
      if (lifecycleSteps.has(step)) {
        throw new InvalidModel(
          `$input.scope.tasks.${task.id}.${kind}_step`,
          `lifecycle step ${step} is already used by ${lifecycleSteps.get(step)}`,
        );
      }
      lifecycleSteps.set(step, `${task.id}.${kind}`);
    }
  }
  const parentActions = array(scope.parent_actions ?? [], "$input.scope.parent_actions", LIMITS.parentActions)
    .map((action, index) => normalizeParentAction(action, `$input.scope.parent_actions[${index}]`, exitStep));
  for (let index = 0; index < parentActions.length; index += 1) {
    const step = parentActions[index].step;
    if (lifecycleSteps.has(step)) {
      throw new InvalidModel(
        `$input.scope.parent_actions[${index}].step`,
        `logical step ${step} is already used by ${lifecycleSteps.get(step)}`,
      );
    }
    lifecycleSteps.set(step, `parent_action:${index}`);
  }
  return Object.freeze({
    exitStep,
    cancellationStep,
    tasks: Object.freeze(tasks),
    parentActions: Object.freeze(parentActions),
  });
}

function compareText(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function taskOrder(left, right) {
  return left.spawnStep - right.spawnStep || compareText(left.id, right.id);
}

function projectionRelation(left, right) {
  if (Object.hasOwn(left, "unknown") || Object.hasOwn(right, "unknown")) {
    return left.unknown === right.unknown ? "overlap" : "unknown";
  }
  if (left.base !== right.base) return "disjoint";
  const length = Math.min(left.path.length, right.path.length);
  for (let index = 0; index < length; index += 1) {
    const a = left.path[index];
    const b = right.path[index];
    if (a.kind === "field" && b.kind === "field") {
      if (a.name !== b.name) return "disjoint";
      continue;
    }
    if (a.kind === "slice" && b.kind === "slice") {
      if (typeof a.start === "number" && typeof a.end === "number" &&
          typeof b.start === "number" && typeof b.end === "number") {
        if (a.start === a.end || b.start === b.end) return "disjoint";
        if (a.end <= b.start || b.end <= a.start) return "disjoint";
        continue;
      }
      if (a.start === b.start && a.end === b.end) continue;
      return "unknown";
    }
    return "unknown";
  }
  return "overlap";
}

function liveInterval(task, exitStep) {
  return Object.freeze({ start: task.spawnStep, end: task.joinStep ?? exitStep });
}

function intervalsOverlap(left, right) {
  return left.start < right.end && right.start < left.end;
}

function modesConflict(left, right) {
  return left !== "read" || right !== "read";
}

function placeText(place) {
  if (Object.hasOwn(place, "unknown")) return `?${place.unknown}`;
  let result = place.base;
  for (const projection of place.path) {
    if (projection.kind === "field") result += `.${projection.name}`;
    else result += `[${projection.start}..${projection.end}]`;
  }
  return result;
}

function diagnostic(code, at, detail) {
  return Object.freeze({ code, at, detail });
}

function diagnosticOrder(left, right) {
  return compareText(left.at, right.at) || compareText(left.code, right.code) || compareText(left.detail, right.detail);
}

function rejected(diagnostics) {
  return Object.freeze({
    schema: RESULT_SCHEMA,
    status: "rejected",
    scope_outcome: "not-run",
    primary_failure: null,
    joins: Object.freeze([]),
    semantic_anchors: Object.freeze([]),
    diagnostics: Object.freeze([...diagnostics].sort(diagnosticOrder)),
    guarantees: Object.freeze({
      data_race_freedom: true,
      race_condition_freedom: false,
      runtime_schedule_modeled: false,
    }),
  });
}

function analyzeNormalized(scope) {
  const tasks = [...scope.tasks].sort(taskOrder);
  const diagnostics = [];

  for (const task of tasks) {
    if (task.handleUse !== "none") {
      diagnostics.push(diagnostic(
        "SPV1-HANDLE-ESCAPE",
        `task:${task.id}`,
        `task handle ${task.id} cannot ${task.handleUse} outside its lexical scope`,
      ));
    }
  }

  for (let leftIndex = 0; leftIndex < tasks.length; leftIndex += 1) {
    const left = tasks[leftIndex];
    for (let rightIndex = leftIndex + 1; rightIndex < tasks.length; rightIndex += 1) {
      const right = tasks[rightIndex];
      if (!intervalsOverlap(liveInterval(left, scope.exitStep), liveInterval(right, scope.exitStep))) continue;
      for (const leftCapture of left.captures) {
        for (const rightCapture of right.captures) {
          if (!modesConflict(leftCapture.mode, rightCapture.mode)) continue;
          const relation = projectionRelation(leftCapture.place, rightCapture.place);
          const at = `tasks:${left.id},${right.id}`;
          if (relation === "unknown") {
            diagnostics.push(diagnostic(
              "SPV1-OVERLAP-UNKNOWN",
              at,
              `cannot prove ${placeText(leftCapture.place)} and ${placeText(rightCapture.place)} disjoint`,
            ));
          } else if (relation === "overlap") {
            diagnostics.push(diagnostic(
              "SPV1-CAPTURE-CONFLICT",
              at,
              `${leftCapture.mode} ${placeText(leftCapture.place)} conflicts with ${rightCapture.mode} ${placeText(rightCapture.place)}`,
            ));
          }
        }
      }
    }
  }

  for (const laterTask of tasks) {
    for (const laterCapture of laterTask.captures) {
      let removedBy = null;
      let removedRelation = null;
      for (const earlierTask of tasks) {
        if (earlierTask.spawnStep >= laterTask.spawnStep) break;
        if (liveInterval(earlierTask, scope.exitStep).end > laterTask.spawnStep) continue;
        for (const earlierCapture of earlierTask.captures) {
          if (earlierCapture.mode !== "take") continue;
          const relation = projectionRelation(earlierCapture.place, laterCapture.place);
          if (relation === "disjoint") continue;
          removedBy = Object.freeze({ task: earlierTask, capture: earlierCapture });
          removedRelation = relation;
          break;
        }
        if (removedBy !== null) break;
      }
      if (removedBy === null) continue;
      const at = `tasks:${removedBy.task.id},${laterTask.id}`;
      diagnostics.push(removedRelation === "unknown"
        ? diagnostic(
            "SPV1-OVERLAP-UNKNOWN",
            at,
            `cannot prove ${placeText(laterCapture.place)} disjoint from place taken by task ${removedBy.task.id}`,
          )
        : diagnostic(
            "SPV1-USE-AFTER-TAKE",
            at,
            `${placeText(laterCapture.place)} is unavailable after take by task ${removedBy.task.id}`,
          ));
    }
  }

  for (let actionIndex = 0; actionIndex < scope.parentActions.length; actionIndex += 1) {
    const action = scope.parentActions[actionIndex];
    for (const task of tasks) {
      for (const capture of task.captures) {
        if (action.step < task.spawnStep) continue;
        const relation = projectionRelation(action.place, capture.place);
        if (relation === "disjoint") continue;
        const at = `parent_action:${actionIndex}`;
        if (capture.mode === "take") {
          diagnostics.push(relation === "unknown"
            ? diagnostic(
                "SPV1-OVERLAP-UNKNOWN",
                at,
                `cannot prove parent ${placeText(action.place)} disjoint from place taken by task ${task.id}`,
              )
            : diagnostic(
                "SPV1-USE-AFTER-TAKE",
                at,
                `${placeText(action.place)} is unavailable after take by task ${task.id}`,
              ));
          continue;
        }
        const interval = liveInterval(task, scope.exitStep);
        if (action.step >= interval.end || !modesConflict(action.mode, capture.mode)) continue;
        if (relation === "unknown") {
          diagnostics.push(diagnostic(
            "SPV1-OVERLAP-UNKNOWN",
            at,
            `cannot prove parent ${placeText(action.place)} disjoint from task ${task.id} capture`,
          ));
        } else {
          diagnostics.push(diagnostic(
            "SPV1-PARENT-CONFLICT",
            at,
            `parent ${action.mode} ${placeText(action.place)} conflicts with live ${capture.mode} capture in task ${task.id}`,
          ));
        }
      }
    }
  }

  if (diagnostics.length > 0) return rejected(diagnostics);

  const joins = tasks.map((task) => Object.freeze({
    task: task.id,
    kind: task.joinStep === null ? "scope-exit" : "explicit",
    step: task.joinStep ?? scope.exitStep,
    outcome: task.outcome,
    result: task.outcome === "success" && task.joinStep !== null ? task.result : null,
    discarded: task.joinStep === null,
  })).sort((left, right) => left.step - right.step || compareText(left.task, right.task));

  const panicked = tasks.filter((task) => task.outcome === "panic");
  const cancelled = scope.cancellationStep !== null || tasks.some((task) => task.outcome === "cancelled");
  const scopeOutcome = panicked.length > 0 ? "panicked" : cancelled ? "cancelled" : "success";
  const primaryFailure = panicked.length > 0
    ? Object.freeze({ kind: "panic", task: panicked[0].id })
    : cancelled
      ? Object.freeze({ kind: "cancellation", task: null })
      : null;

  const anchors = [Object.freeze({ event: "scope.enter", step: 0, task: null })];
  for (const task of tasks) anchors.push(Object.freeze({ event: "task.spawn", step: task.spawnStep, task: task.id }));
  for (const join of joins) {
    anchors.push(Object.freeze({
      event: join.kind === "explicit" ? "task.join.explicit" : "task.join.scope-exit",
      step: join.step,
      task: join.task,
    }));
  }
  anchors.push(Object.freeze({ event: "scope.exit", step: scope.exitStep, task: null }));
  const anchorPriority = Object.freeze({
    "scope.enter": 0,
    "task.spawn": 1,
    "task.join.explicit": 2,
    "task.join.scope-exit": 3,
    "scope.exit": 4,
  });
  anchors.sort((left, right) => left.step - right.step ||
    anchorPriority[left.event] - anchorPriority[right.event] ||
    compareText(left.task ?? "", right.task ?? ""));

  return Object.freeze({
    schema: RESULT_SCHEMA,
    status: "accepted",
    scope_outcome: scopeOutcome,
    primary_failure: primaryFailure,
    joins: Object.freeze(joins),
    semantic_anchors: Object.freeze(anchors),
    diagnostics: Object.freeze([]),
    guarantees: Object.freeze({
      data_race_freedom: true,
      race_condition_freedom: false,
      runtime_schedule_modeled: false,
    }),
  });
}

export function analyzeScopedParallelism(input) {
  try {
    return analyzeNormalized(normalize(input));
  } catch (error) {
    if (!(error instanceof InvalidModel)) throw error;
    return rejected([diagnostic("SPV1-INVALID-MODEL", error.path, error.detail)]);
  }
}

function main(argv) {
  if (argv.length !== 1) {
    process.stderr.write("usage: node model.mjs FIXTURE.json\n");
    return 2;
  }
  let bytes;
  try {
    bytes = readFileSync(argv[0]);
  } catch (error) {
    process.stderr.write(`scoped-parallelism model: ${error.message}\n`);
    return 2;
  }
  if (bytes.length > LIMITS.inputBytes) {
    process.stderr.write(`scoped-parallelism model: input limit exceeded (${bytes.length} > ${LIMITS.inputBytes})\n`);
    return 2;
  }
  let input;
  try {
    input = JSON.parse(bytes.toString("utf8"));
  } catch (error) {
    process.stderr.write(`scoped-parallelism model: invalid JSON: ${error.message}\n`);
    return 2;
  }
  process.stdout.write(`${JSON.stringify(analyzeScopedParallelism(input), null, 2)}\n`);
  return 0;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = main(process.argv.slice(2));
}

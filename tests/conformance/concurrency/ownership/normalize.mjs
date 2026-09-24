// Order-level views of scoped-ownership model inputs (#1162). Production
// names are opaque identities; the gate compares them through the document's
// own name table and the step order, never through spelling or byte offsets.

const PLACE = /^([A-Za-z_][A-Za-z0-9_]*|\?)((?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]*\.\.[^\]]*\])*)$/;

function boundRank(ranks, bound) {
  return typeof bound === 'number' ? String(ranks.indexOf(bound)) : '#';
}

// `items[0..4]`, `pair.left`, `?`: authored place text to a model place.
export function parsePlace(text) {
  const match = PLACE.exec(text);
  if (!match) throw new Error(`unparseable place ${text}`);
  if (match[1] === '?') return { unknown: text };
  const path = [];
  for (const part of match[2].match(/\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]*\]/g) ?? []) {
    if (part.startsWith('.')) path.push({ field: part.slice(1) });
    else {
      const [lower, upper] = part.slice(1, -1).split('..');
      const bound = value => /^-?[0-9]+$/.test(value) ? Number(value) : value;
      path.push({ slice: [bound(lower), bound(upper)] });
    }
  }
  return { base: match[1], path };
}

function constants(places) {
  const values = new Set();
  for (const place of places) {
    for (const projection of place.path ?? []) {
      if (projection.slice) for (const bound of projection.slice) if (typeof bound === 'number') values.add(bound);
    }
  }
  return [...values].sort((a, b) => a - b);
}

function placeText(place, rename, ranks) {
  if (Object.hasOwn(place, 'unknown')) return '?';
  let result = rename(place.base);
  for (const projection of place.path ?? []) {
    if (projection.field !== undefined) result += `.${rename(projection.field)}`;
    else result += `[${boundRank(ranks, projection.slice[0])}..${boundRank(ranks, projection.slice[1])}]`;
  }
  return result;
}

// A model scope as step order, per-task capture multisets, and ordered parent
// and after-scope actions. Constants become dense ranks within the scope.
export function view(scope, { rename = name => name, taskNames, after = [] }) {
  const tasks = [...scope.tasks].sort((a, b) => a.spawn_step - b.spawn_step);
  const names = new Map(tasks.map((task, index) => [task.id, taskNames?.[index] ?? task.id]));
  const actions = scope.parent_actions ?? [];
  const all = [...tasks.flatMap(task => task.captures.map(c => c.place)), ...actions.map(a => a.place), ...after.map(a => a.place)];
  const ranks = constants(all);
  const events = [];
  for (const task of tasks) {
    events.push([task.spawn_step, `${names.get(task.id)}.spawn`]);
    if (task.join_step !== undefined) events.push([task.join_step, `${names.get(task.id)}.join`]);
  }
  for (const action of actions) events.push([action.step, 'parent']);
  events.sort((a, b) => a[0] - b[0]);
  const text = entry => `${entry.mode} ${placeText(entry.place, rename, ranks)}`;
  return {
    order: events.map(([, event]) => event),
    captures: Object.fromEntries(tasks.map(task => [names.get(task.id), task.captures.map(text).sort()])),
    escapes: Object.fromEntries(tasks.filter(task => (task.handle_use ?? 'none') !== 'none').map(task => [names.get(task.id), task.handle_use])),
    parent: [...actions].sort((a, b) => a.step - b.step).map(text),
    after: after.map(text),
  };
}

// An authored expectation in the same view, built through a real model input
// so its constants are ranked exactly as the production view's are.
export function expectedView(expect) {
  const order = expect.order;
  const parents = [...(expect.parent ?? [])];
  const tasks = expect.tasks.map(name => ({ id: name, captures: (expect.captures?.[name] ?? []).map(entry => {
    const [mode, place] = entry.split(' ');
    return { mode, place: parsePlace(place) };
  }), handle_use: expect.escapes?.[name] ?? 'none' }));
  const byName = new Map(tasks.map(task => [task.id, task]));
  const parent_actions = [];
  order.forEach((event, index) => {
    const step = index + 1;
    if (event === 'parent') {
      const [mode, place] = parents.shift().split(' ');
      parent_actions.push({ step, mode, place: parsePlace(place) });
    } else {
      const [name, kind] = event.split('.');
      byName.get(name)[kind === 'spawn' ? 'spawn_step' : 'join_step'] = step;
    }
  });
  if (parents.length !== 0) throw new Error('parent actions outnumber parent events');
  const after = (expect.after ?? []).map(entry => {
    const [mode, place] = entry.split(' ');
    return { mode, place: parsePlace(place) };
  });
  return view({ exit_step: order.length + 1, tasks, parent_actions }, { after });
}

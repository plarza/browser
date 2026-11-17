extension ScriptletLibrary {
    /// The `json-edit` family's queries, uBlock Origin's JSONPath: parsed
    /// once, then run over each object that passes.
    static let editing = #"""
// MARK: Editing (uBO's JSONPath)

/** `..key`, `.key`, `.*`, `./re/`, `[n]`, `["key"]`, `[?test]`, then `=value`
 *  or `+={…}`, or nothing to remove what matched. */
const query = (source, trusted) => {
  let q = source.trim();
  if (q.startsWith('v2:')) q = q.slice(3);
  let i = 0;
  if (q[i] === '$') i++;
  const steps = [];
  const fail = { apply: root => ({ root, modified: false }) };
  const readKey = () => {
    if (q[i] === '*') { i++; return { any: true }; }
    if (q[i] === '/') {
      let j = i + 1;
      while (j < q.length && q[j] !== '/') j += q[j] === '\\' ? 2 : 1;
      let k = j + 1;
      while (k < q.length && /[a-z]/.test(q[k])) k++;
      const re = regex(q.slice(i, k));
      i = k;
      return { re };
    }
    const start = i;
    while (i < q.length && !'.[=+!<>*^$'.includes(q[i])) i++;
    return { key: q.slice(start, i) };
  };
  const readBracket = () => {
    let depth = 0, quote = '', j = i;
    for (; j < q.length; j++) {
      const c = q[j];
      if (quote) { if (c === '\\') j++; else if (c === quote) quote = ''; continue; }
      if (c === '"' || c === "'") quote = c;
      else if (c === '[') depth++;
      else if (c === ']' && --depth === 0) break;
    }
    const inner = q.slice(i + 1, j);
    i = j + 1;
    return inner;
  };
  const parseSteps = (stop) => {
    const out = [];
    while (i < q.length && !stop()) {
      if (q.startsWith('..', i)) {
        i += 2;
        out.push({ deep: true, ...readKey() });
      } else if (q[i] === '.') {
        i++;
        if (q[i] === '[') continue;
        out.push(readKey());
      } else if (q[i] === '[') {
        const inner = readBracket().trim();
        if (inner.startsWith('?')) out.push({ test: test(inner.slice(1)) });
        else if (/^-?\d+$/.test(inner)) out.push({ index: Number(inner) });
        else if (inner === '*') out.push({ any: true });
        else if (/^(["']).*\1$/s.test(inner)) out.push({ key: inner.slice(1, -1) });
        else return null;
      } else {
        return null;
      }
    }
    return out;
  };
  const value = raw => {
    raw = raw.trim();
    const repl = /^repl\((.*)\)$/s.exec(raw);
    if (repl) {
      const spec = parseOr(repl[1]);
      if (!spec || typeof spec.regex !== 'string') return undefined;
      const re = spec.regex.startsWith('/') ? regex(spec.regex) : regex('/' + spec.regex + '/');
      return { replace: re, by: String(spec.replacement ?? '') };
    }
    if (raw.startsWith('/')) return { re: regex(raw) };
    const parsed = parseOr(raw);
    return { value: parsed === undefined ? raw : parsed };
  };
  function test(expr) {
    let not = false;
    if (expr.startsWith('!')) { not = true; expr = expr.slice(1); }
    const saved = [q, i];
    q = expr; i = 0;
    const ops = ['==', '!=', '*=', '^=', '$=', '=', '<', '>'];
    const path = parseSteps(() => ops.some(op => q.startsWith(op, i)));
    let op, rhs;
    if (path !== null && i < q.length) {
      op = ops.find(o => q.startsWith(o, i));
      rhs = value(q.slice(i + op.length));
    }
    [q, i] = saved;
    if (path === null) return () => false;
    return node => {
      const found = select(node, path);
      const ok = op === undefined ? found.length > 0 : found.some(ref => compare(ref.value, op, rhs));
      return ok !== not;
    };
  }
  const compare = (v, op, rhs) => {
    if (rhs === undefined) return false;
    if (rhs.re) return typeof v === 'string' && rhs.re.test(v) !== (op === '!=');
    const r = rhs.value;
    switch (op) {
      case '==': case '=': return v === r;
      case '!=': return v !== r;
      case '*=': return typeof v === 'string' && v.includes(r);
      case '^=': return typeof v === 'string' && v.startsWith(r);
      case '$=': return typeof v === 'string' && v.endsWith(r);
      case '<': return v < r;
      case '>': return v > r;
    }
    return false;
  };
  const matches = (step, key) => step.any || (step.re ? step.re.test(key) : step.key === key);
  function select(root, path) {
    let refs = [{ owner: null, key: null, value: root }];
    for (const step of path) {
      const next = [];
      if (step.test) {
        for (const ref of refs) if (step.test(ref.value)) next.push(ref);
      } else if (step.index !== undefined) {
        for (const ref of refs) {
          if (!Array.isArray(ref.value)) continue;
          const k = step.index < 0 ? ref.value.length + step.index : step.index;
          if (k >= 0 && k < ref.value.length) next.push({ owner: ref.value, key: k, value: ref.value[k] });
        }
      } else if (step.deep) {
        const seen = new Set();
        const walk = node => {
          if (typeof node !== 'object' || node === null || seen.has(node)) return;
          seen.add(node);
          for (const key of N.keys(node)) {
            if (matches(step, key)) next.push({ owner: node, key: Array.isArray(node) ? Number(key) : key, value: node[key] });
            walk(node[key]);
          }
        };
        for (const ref of refs) walk(ref.value);
      } else {
        for (const ref of refs) {
          const node = ref.value;
          if (typeof node !== 'object' || node === null) continue;
          if (step.key !== undefined) {
            if (N.hasOwn(node, step.key)) next.push({ owner: node, key: step.key, value: node[step.key] });
            continue;
          }
          for (const key of N.keys(node)) {
            if (matches(step, key)) next.push({ owner: node, key: Array.isArray(node) ? Number(key) : key, value: node[key] });
          }
        }
      }
      refs = next;
      if (refs.length === 0) break;
    }
    return refs;
  }
  const path = parseSteps(() => q[i] === '=' || q.startsWith('+=', i));
  if (path === null) return fail;
  let op, rhs;
  if (i < q.length) {
    op = q[i] === '=' ? '=' : '+=';
    rhs = value(q.slice(i + op.length));
    if (!trusted || rhs === undefined) return fail;
  }
  return {
    apply(root) {
      const refs = select(root, path);
      if (refs.length === 0) return { root, modified: false };
      if (op === undefined) {
        // Removed from the end, so earlier indices stay right.
        for (const ref of refs.reverse()) {
          if (ref.owner === null) continue;
          if (Array.isArray(ref.owner)) ref.owner.splice(ref.key, 1); else delete ref.owner[ref.key];
        }
        return { root, modified: true };
      }
      for (const ref of refs) {
        let next;
        if (op === '+=') {
          if (typeof ref.value !== 'object' || ref.value === null || typeof rhs.value !== 'object') continue;
          Object.assign(ref.value, rhs.value);
          continue;
        }
        if (rhs.replace) {
          if (typeof ref.value !== 'string') continue;
          next = ref.value.replace(rhs.replace, rhs.by);
        } else {
          next = typeof rhs.value === 'string' ? rhs.value.replace('${now}', String(N.now())) : rhs.value;
        }
        if (ref.owner === null) root = next; else ref.owner[ref.key] = next;
      }
      return { root, modified: true };
    },
  };
};
const editText = q => body => {
  const obj = parseOr(body);
  if (obj === undefined) return undefined;
  const out = q.apply(obj);
  return out.modified ? N.stringify(out.root) : undefined;
};
"""#
}

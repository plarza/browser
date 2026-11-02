import Foundation

/// The scriptlets themselves, uBlock Origin's names and behaviour, run in
/// the page's own world. `__TABLE__` becomes the frame's hosts and calls.
enum ScriptletLibrary {
    static func source(table: String) -> String {
        template.replacingOccurrences(of: "__TABLE__", with: table)
    }

    static func quote(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }.map(String.init) ?? "\"\""
    }

    /// Every scriptlet the library has: its `'name'(…) {` entries.
    static let names: Set<String> = {
        let pattern = try! NSRegularExpression(pattern: "^  '([^']+)'\\(", options: .anchorsMatchLines)
        let range = NSRange(template.startIndex..., in: template)
        return Set(pattern.matches(in: template, range: range).compactMap { Range($0.range(at: 1), in: template).map { String(template[$0]) } })
    }()

    private static let template = #"""
(() => {
'use strict';
const table = __TABLE__;
let host = location.hostname;
if (host === '') { try { host = parent.location.hostname; } catch {} }
const calls = table[host];
if (calls === undefined) return;

// The page's own functions, taken before any of its scripts run.
const N = {
  apply: Reflect.apply, construct: Reflect.construct, define: Object.defineProperty,
  descriptor: Object.getOwnPropertyDescriptor, keys: Object.keys, hasOwn: Object.hasOwn,
  parse: JSON.parse, stringify: JSON.stringify, Proxy, RegExp, Error, ReferenceError,
  Response: self.Response, Request: self.Request, Promise, MutationObserver: self.MutationObserver,
  setTimeout: self.setTimeout, now: Date.now, random: Math.random,
};
const magic = String.fromCharCode(Date.now() % 26 + 97) + Math.floor(N.random() * 982451653 + 982451653).toString(36);
self.addEventListener('error', event => {
  if (typeof event.message === 'string' && event.message.includes(magic)) event.preventDefault();
}, true);

// MARK: Helpers

const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
/** `/re/flags`, or text matched as is; nothing matches everything. */
const regex = (pattern, flags = '') => {
  if (pattern === undefined || pattern === '') return new N.RegExp('^', flags.replace('g', ''));
  const m = /^\/(.+)\/([dgimsuvy]*)$/s.exec(pattern);
  try {
    return m ? new N.RegExp(m[1], m[2] || flags) : new N.RegExp(escape(pattern), flags);
  } catch {
    return /[^\s\S]/;
  }
};
/** A test for text, `!` in front for "doesn't match". */
const needle = pattern => {
  let not = false;
  if (typeof pattern === 'string' && pattern.startsWith('!')) { not = true; pattern = pattern.slice(1); }
  const re = regex(pattern);
  return text => re.test(text) !== not;
};
/** The value after `name` in a scriptlet's trailing name, value pairs. */
const option = (args, name) => {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
};
const text = value => {
  try { return typeof value === 'function' ? N.apply(Function.prototype.toString, value, []) : String(value); } catch { return ''; }
};
/** The object a dotted chain ends on, from `root`, and its last name. */
const resolve = (chain, root = self) => {
  const parts = chain.split('.');
  const prop = parts.pop();
  let owner = root;
  for (const part of parts) {
    try { owner = owner[part]; } catch { return []; }
    if (owner === null || (typeof owner !== 'object' && typeof owner !== 'function')) return [];
  }
  return [owner, prop];
};
/** The function at `chain` runs through `handler(target, thisArg, args)`. */
const wrap = (chain, handler) => {
  const [owner, prop] = resolve(chain);
  if (owner === undefined || typeof owner[prop] !== 'function') return;
  try { owner[prop] = new N.Proxy(owner[prop], { apply: handler }); } catch {}
};
/** Runs `leaf(owner, prop)` on the chain's end, now or once the objects
 *  on the way to it are assigned. */
const trap = (chain, leaf) => {
  const go = (owner, chain) => {
    const dot = chain.indexOf('.');
    if (dot === -1) { leaf(owner, chain); return; }
    const prop = chain.slice(0, dot), rest = chain.slice(dot + 1);
    let value;
    try { value = owner[prop]; } catch { return; }
    if (value instanceof Object || (typeof value === 'object' && value !== null)) { go(value, rest); return; }
    // Another rule may already wait on the same object: both go on.
    const desc = N.descriptor(owner, prop);
    if (desc && desc.configurable === false) return;
    const before = desc?.set, read = desc?.get;
    try {
      N.define(owner, prop, {
        configurable: true, enumerable: true,
        get() { return read ? N.apply(read, this, []) : value; },
        set(next) {
          if (before) N.apply(before, this, [next]);
          value = next;
          if (next instanceof Object) go(next, rest);
        },
      });
    } catch {}
  };
  go(self, chain);
};
const later = (when, fn) => {
  if (when === 'asap' || document.readyState !== 'loading' && when !== 'complete') { fn(); return; }
  if (when === 'complete') {
    if (document.readyState === 'complete') fn(); else self.addEventListener('load', fn, { once: true });
    return;
  }
  document.addEventListener('DOMContentLoaded', fn, { once: true });
};
/** `fn` now (as `behavior` says) and, with `stay`, whenever the page changes. */
const onElements = (behavior = '', fn) => {
  const run = () => { try { fn(); } catch {} };
  const watch = () => {
    run();
    if (!/\bstay\b/.test(behavior)) return;
    // New elements only, at most every 50 ms: pages change all the time.
    let queued = false;
    new N.MutationObserver(() => {
      if (queued) return;
      queued = true;
      N.setTimeout(() => { queued = false; run(); }, 50);
    }).observe(document, { childList: true, subtree: true });
  };
  later(/\basap\b/.test(behavior) ? 'asap' : /\bcomplete\b/.test(behavior) ? 'complete' : '', watch);
};
const values = {
  'undefined': () => undefined, 'false': () => false, 'true': () => true, 'null': () => null,
  "''": () => '', '': () => '', 'emptyStr': () => '',
  'noopFunc': () => function () {}, 'trueFunc': () => () => true, 'falseFunc': () => () => false,
  'throwFunc': () => () => { throw new N.Error(magic); },
  'emptyArr': () => [], 'emptyObj': () => ({}), '[]': () => [], '{}': () => ({}),
  'noopPromiseResolve': () => () => N.Promise.resolve(), 'noopPromiseReject': () => () => N.Promise.reject(),
  'noopCallbackFunc': () => () => function () {},
  'yes': () => 'yes', 'no': () => 'no', 'on': () => 'on', 'off': () => 'off',
};
/** A value a filter names; trusted filters may give any JSON. */
const constant = (raw, trusted) => {
  if (N.hasOwn(values, raw)) return { value: values[raw]() };
  if (/^-?\d+(\.\d+)?$/.test(raw) && (trusted || Math.abs(Number(raw)) <= 0x7FFF)) return { value: Number(raw) };
  if (trusted) { try { return { value: N.parse(raw) }; } catch { return { value: raw }; } }
  return undefined;
};
const request = args => {
  const [resource, init] = args;
  const details = { url: '', method: 'GET' };
  if (resource instanceof N.Request) {
    details.url = resource.url;
    details.method = resource.method;
    details.mode = resource.mode;
    details.credentials = resource.credentials;
  } else {
    details.url = String(resource);
  }
  if (init instanceof Object) {
    for (const key of ['method', 'mode', 'credentials', 'cache', 'redirect', 'referrer', 'referrerPolicy', 'integrity', 'body']) {
      if (init[key] !== undefined) details[key] = init[key];
    }
  }
  try { details.url = new URL(details.url, location.href).href; } catch {}
  return details;
};
/** `url:/re/ method:POST`, or a bare pattern for the URL; nothing matches nothing. */
const props = spec => {
  if (typeof spec !== 'string' || spec.trim() === '') return undefined;
  const tests = [];
  for (const part of spec.trim().split(/\s+/)) {
    const m = /^(url|method|body|mode|credentials|cache|redirect|referrer|referrerPolicy|integrity|headers|responseType):(.*)$/s.exec(part);
    tests.push(m ? [m[1], needle(m[2])] : ['url', needle(part)]);
  }
  return details => tests.every(([key, test]) => test(text(details[key] ?? '')));
};
const all = () => true;

/** A response as if `body` had come from the server. */
const rebuild = (response, body) => {
  const out = new N.Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
  for (const key of ['ok', 'redirected', 'type', 'url']) {
    try { N.define(out, key, { value: response[key] }); } catch {}
  }
  return out;
};
/** fetch's responses that `match`, rewritten by `edit(text) -> text | undefined`. */
const fetchResponses = (match, edit) => {
  wrap('fetch', (target, thisArg, args) => {
    const sent = N.apply(target, thisArg, args);
    let details;
    try { details = request(args); } catch { return sent; }
    if (!match(details)) return sent;
    return sent.then(response => response.clone().text().then(body => {
      const edited = edit(body);
      return edited === undefined || edited === body ? response : rebuild(response, edited);
    }).catch(() => response));
  });
};
/** XMLHttpRequest's responses that `match`, rewritten the same way. */
const xhrResponses = (match, edit) => {
  const Base = self.XMLHttpRequest;
  if (typeof Base !== 'function') return;
  const state = new WeakMap();
  const response = N.descriptor(Base.prototype, 'response')
    ?? N.descriptor(self.XMLHttpRequest.prototype, 'response');
  const read = (xhr, fallback) => {
    const s = state.get(xhr);
    if (s === undefined || xhr.readyState !== 4) return fallback();
    if (s.done) return s.value;
    const type = xhr.responseType;
    const raw = fallback();
    s.done = true;
    s.value = raw;
    if (type !== '' && type !== 'text' && type !== 'json') return raw;
    let body;
    try { body = type === 'json' ? N.stringify(raw) : raw; } catch { return raw; }
    if (typeof body !== 'string') return raw;
    const edited = edit(body);
    if (edited === undefined || edited === body) return raw;
    try { s.value = type === 'json' ? N.parse(edited) : edited; } catch {}
    return s.value;
  };
  self.XMLHttpRequest = class XMLHttpRequest extends Base {
    open(method, url, ...rest) {
      let details = { method: String(method), url: String(url) };
      try { details.url = new URL(details.url, location.href).href; } catch {}
      if (match(details)) state.set(this, { done: false }); else state.delete(this);
      return super.open(method, url, ...rest);
    }
    get response() { return read(this, () => super.response); }
    get responseText() {
      const value = read(this, () => this.responseType === '' || this.responseType === 'text' ? super.responseText : super.response);
      return typeof value === 'string' ? value : super.responseText;
    }
  };
};
const parseOr = body => { try { return N.parse(body); } catch { return undefined; } };

// MARK: Pruning (json-prune's paths)

/** Whether `path` is in `root`; with `prune`, removes what it names. */
const find = (root, path, prune = false) => {
  let owner = root, chain = path;
  for (;;) {
    if (typeof owner !== 'object' || owner === null) return false;
    const dot = chain.indexOf('.');
    if (dot === -1) {
      if (!prune) return N.hasOwn(owner, chain);
      let modified = false;
      if (chain === '*') {
        for (const key of N.keys(owner)) { delete owner[key]; modified = true; }
      } else if (N.hasOwn(owner, chain)) {
        delete owner[chain];
        modified = true;
      }
      return modified;
    }
    const prop = chain.slice(0, dot), rest = chain.slice(dot + 1);
    let found = false;
    if (prop === '[-]' && Array.isArray(owner)) {
      for (let i = owner.length - 1; i >= 0; i--) {
        if (!find(owner[i], rest)) continue;
        owner.splice(i, 1);
        found = true;
      }
      return found;
    }
    if (prop === '{-}' && owner instanceof Object) {
      for (const key of N.keys(owner)) {
        if (!find(owner[key], rest)) continue;
        delete owner[key];
        found = true;
      }
      return found;
    }
    if ((prop === '[]' && Array.isArray(owner)) || ((prop === '{}' || prop === '*') && owner instanceof Object)) {
      for (const key of N.keys(owner)) if (find(owner[key], rest, prune)) found = true;
      return found;
    }
    if (!N.hasOwn(owner, prop)) return false;
    owner = owner[prop];
    chain = rest;
  }
};
const pruner = (rawPrune = '', rawNeedles = '') => {
  const paths = rawPrune.split(/\s+/).filter(Boolean);
  const needles = rawNeedles.split(/\s+/).filter(Boolean);
  return obj => {
    if (paths.length === 0 || typeof obj !== 'object' || obj === null) return false;
    if (needles.some(path => !find(obj, path))) return false;
    let modified = false;
    for (const path of paths) if (find(obj, path, true)) modified = true;
    return modified;
  };
};

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

// MARK: Shared bodies

const setConstant = (chain, raw, trusted) => {
  const parsed = constant(raw, trusted);
  if (parsed === undefined || chain === '') return;
  let wanted = parsed.value;
  const differs = v => v !== undefined && v !== null && wanted !== undefined && wanted !== null && typeof v !== typeof wanted;
  trap(chain, (owner, prop) => {
    const desc = N.descriptor(owner, prop);
    if (desc && desc.configurable === false) return;
    let old;
    try { old = owner[prop]; } catch {}
    if (differs(old)) return;
    try {
      N.define(owner, prop, {
        configurable: false, enumerable: desc ? desc.enumerable : true,
        get() { if (desc?.get) N.apply(desc.get, this, []); return wanted; },
        set(next) { if (desc?.set) N.apply(desc.set, this, [next]); if (differs(next)) wanted = next; },
      });
    } catch {}
  });
};
const nodeText = (nodeName, pattern, replacement, rest) => {
  if (!nodeName || !pattern) return;
  const name = regex(/^\/.+\/[a-z]*$/s.test(nodeName) ? nodeName : '/^' + escape(nodeName) + '$/i');
  const re = regex(pattern, replacement === undefined ? '' : 'gms');
  const condition = option(rest, 'condition'), excludes = option(rest, 'excludes');
  const when = condition && regex(condition, 'ms'), unless = excludes && regex(excludes, 'ms');
  const limit = Number(option(rest, 'sedCount')) || 0;
  const stay = rest.includes('stay');
  let count = 0;
  // Each node changes once: a replacement can contain what it replaces,
  // and setting the text is itself a change the observer would see.
  const done = new WeakSet();
  const handle = node => {
    if (done.has(node)) return;
    const before = node.textContent;
    if (when && !when.test(before)) return;
    if (unless && unless.test(before)) return;
    re.lastIndex = 0;
    if (replacement === undefined) {
      if (!re.test(before)) return;
      done.add(node);
      if (node.nodeType === 3) node.remove(); else node.textContent = '';
    } else {
      const after = before.replace(re, replacement);
      if (after === before) return;
      done.add(node);
      node.textContent = after;
    }
    observer.takeRecords();
    count++;
  };
  const named = node => name.test(node.nodeName.toLowerCase()) || name.test(node.nodeName);
  const observer = new N.MutationObserver(records => {
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (named(node)) handle(node);
        else if (node.nodeType === 3 && node.parentNode && named(node.parentNode)) handle(node.parentNode);
        if (limit && count >= limit) { observer.disconnect(); return; }
      }
    }
  });
  observer.observe(document, { childList: true, subtree: true });
  if (!stay) later('', () => N.setTimeout(() => observer.disconnect(), 1000));
};
const timerFilter = (name, rawNeedle = '', rawDelay = '') => {
  const test = needle(rawNeedle);
  let not = false, delay = rawDelay;
  if (delay.startsWith('!')) { not = true; delay = delay.slice(1); }
  const n = delay === '' ? undefined : Number(delay);
  wrap(name, (target, thisArg, args) => {
    const [callback, ms] = args;
    if (test(text(callback)) && (n === undefined || ((Number(ms) || 0) === n) !== not)) {
      args = [function () {}, ...args.slice(1)];
    }
    return N.apply(target, thisArg, args);
  });
};
const timerBoost = (name, rawNeedle = '', rawDelay = '', rawBoost = '') => {
  const test = needle(rawNeedle === '*' ? '' : rawNeedle);
  const delay = rawDelay === '*' ? undefined : Number(rawDelay || 1000);
  let boost = Number(rawBoost || 0.05);
  if (!(boost > 0)) boost = 0.05;
  boost = Math.min(50, Math.max(0.001, boost));
  wrap(name, (target, thisArg, args) => {
    const [callback, ms] = args;
    if ((delay === undefined || Number(ms) === delay) && test(text(callback))) {
      args = [callback, (Number(ms) || 0) * boost, ...args.slice(2)];
    }
    return N.apply(target, thisArg, args);
  });
};
const blockFetch = (spec, body, trusted) => {
  const match = props(spec);
  if (!match) return;
  wrap('fetch', (target, thisArg, args) => {
    let details;
    try { details = request(args); } catch { return N.apply(target, thisArg, args); }
    if (!match(details)) return N.apply(target, thisArg, args);
    let payload = '';
    if (body === 'emptyObj') payload = '{}';
    else if (body === 'emptyArr') payload = '[]';
    else if (body === 'true') payload = N.random().toString(36).slice(2, 12);
    else if (trusted && body) payload = body;
    const response = new N.Response(payload, { status: 200, statusText: 'OK' });
    try {
      N.define(response, 'url', { value: details.url });
      N.define(response, 'type', { value: details.mode === 'no-cors' ? 'opaque' : 'basic' });
    } catch {}
    return N.Promise.resolve(response);
  });
};
const blockXhr = (spec, body, trusted) => {
  const match = props(spec);
  const Base = self.XMLHttpRequest;
  if (!match || typeof Base !== 'function') return;
  const blocked = new WeakMap();
  const fake = (xhr, key, real) => {
    const b = blocked.get(xhr);
    return b && b.sent ? b[key] : real();
  };
  self.XMLHttpRequest = class XMLHttpRequest extends Base {
    open(method, url, ...rest) {
      let details = { method: String(method), url: String(url) };
      try { details.url = new URL(details.url, location.href).href; } catch {}
      if (match(details)) blocked.set(this, { url: details.url, sent: false }); else blocked.delete(this);
      return super.open(method, url, ...rest);
    }
    send(...args) {
      const b = blocked.get(this);
      if (!b) return super.send(...args);
      let payload = body === 'true' ? N.random().toString(36).slice(2, 12) : trusted && body ? body : '';
      const json = this.responseType === 'json';
      Object.assign(b, {
        sent: true, readyState: 4, status: 200, statusText: 'OK', responseURL: b.url,
        responseText: payload, response: json ? parseOr(payload) ?? null : payload,
      });
      N.setTimeout(() => {
        for (const type of ['readystatechange', 'load', 'loadend']) this.dispatchEvent(new Event(type));
      }, 1);
    }
    get readyState() { return fake(this, 'readyState', () => super.readyState); }
    get status() { return fake(this, 'status', () => super.status); }
    get statusText() { return fake(this, 'statusText', () => super.statusText); }
    get responseURL() { return fake(this, 'responseURL', () => super.responseURL); }
    get response() { return fake(this, 'response', () => super.response); }
    get responseText() { return fake(this, 'responseText', () => super.responseText); }
  };
};
const editArgument = (chain, rawPos, q) => {
  const pos = Number(rawPos) || 0;
  wrap(chain, (target, thisArg, args) => {
    const i = pos < 0 ? args.length + pos : pos;
    const obj = args[i];
    if (obj instanceof Object) {
      try {
        // What JSON.stringify is given is the page's own object: edit a copy.
        const copy = chain === 'JSON.stringify' ? N.parse(N.stringify(obj)) : obj;
        const out = q.apply(copy);
        if (out.modified) { args = [...args]; args[i] = out.root; }
      } catch {}
    }
    return N.apply(target, thisArg, args);
  });
};
const editResult = (chain, q) => {
  wrap(chain, (target, thisArg, args) => {
    const result = N.apply(target, thisArg, args);
    if (!(result instanceof Object)) return result;
    try { return q.apply(result).root; } catch { return result; }
  });
};
const editRequest = (q, spec) => {
  const match = props(spec) ?? all;
  wrap('fetch', (target, thisArg, args) => {
    try {
      const [resource, init] = args;
      if (init instanceof Object && typeof init.body === 'string' && match(request(args))) {
        const edited = editText(q)(init.body);
        if (edited !== undefined) args = [resource, { ...init, body: edited }, ...args.slice(2)];
      }
    } catch {}
    return N.apply(target, thisArg, args);
  });
};
const replaceText = (pattern, replacement = '') => {
  if (pattern === '*') return () => replacement;
  const re = regex(pattern, 'g');
  return body => body.replace(re, replacement);
};
const storage = (kind, key, raw, trusted) => {
  if (!key) return;
  const allowed = ['', 'undefined', 'null', 'false', 'true', 'on', 'off', 'yes', 'no', 'accept', 'accepted',
    'reject', 'rejected', 'allow', 'deny', '{}', '[]', '""', '$remove$', 'emptyArr', 'emptyObj'];
  let value = raw;
  if (raw === 'emptyArr') value = '[]';
  else if (raw === 'emptyObj') value = '{}';
  else if (trusted && raw === '$now$') value = String(N.now());
  else if (trusted && raw === '$currentDate$') value = String(new Date());
  else if (trusted && raw === '$currentISODate$') value = new Date().toISOString();
  else if (!trusted && !allowed.includes(raw) && !/^\d+$/.test(raw)) return;
  try {
    const store = self[kind];
    if (value === '$remove$') {
      const re = regex(key);
      for (const k of N.keys(store)) if (re.test(k)) store.removeItem(k);
    } else {
      store.setItem(key, value);
    }
  } catch {}
};
const setCookie = (name, raw, path = '', trusted) => {
  if (!name) return;
  const allowed = ['', 'accept', 'accepted', 'allow', 'allowed', 'approve', 'approved', 'deny', 'denied',
    'dismiss', 'dismissed', 'essential', 'false', 'fixed', 'hide', 'n', 'necessary', 'no', 'off', 'ok',
    'on', 'reject', 'rejected', 'true', 'y', 'yes', 'disagree', 'agree', 'all', 'none'];
  if (!trusted && !allowed.includes(raw.toLowerCase()) && !/^\d+$/.test(raw)) return;
  const value = trusted ? raw.replace('$now$', String(N.now())) : encodeURIComponent(raw);
  const existing = document.cookie.split(/;\s*/).find(c => c.startsWith(name + '='));
  if (existing === `${name}=${value}`) return;
  let cookie = `${name}=${value}`;
  if (path !== 'none') cookie += '; path=' + (path === '' ? '/' : path);
  try { document.cookie = cookie; } catch {}
};
const removeCookie = (pattern = '') => {
  const test = needle(pattern);
  const run = () => {
    for (const pair of document.cookie.split(/;\s*/)) {
      const name = pair.split('=')[0];
      if (!name || !test(name)) continue;
      const host = location.hostname.split('.');
      for (let i = 0; i < host.length - 1; i++) {
        const domain = host.slice(i).join('.');
        for (const d of ['', `; domain=${domain}`, `; domain=.${domain}`]) {
          try { document.cookie = `${name}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/${d}`; } catch {}
        }
      }
    }
  };
  run();
  later('', run);
  self.addEventListener('beforeunload', run);
};
const attributes = (selector, attr, raw, trusted) => {
  if (!selector || !attr) return;
  if (!trusted && !/^(|true|false|-?\d+|\[[\w-]+\])$/.test(raw)) return;
  const copy = /^\[([\w-]+)\]$/.exec(raw);
  onElements('stay', () => {
    for (const el of document.querySelectorAll(selector)) {
      const value = copy ? el.getAttribute(copy[1]) : raw;
      if (value !== null && el.getAttribute(attr) !== value) el.setAttribute(attr, value);
    }
  });
};

// MARK: Scriptlets

const S = {
  'abort-on-property-read'(chain = '') {
    if (chain === '') return;
    trap(chain, (owner, prop) => {
      try { N.define(owner, prop, { configurable: false, get() { throw new N.ReferenceError(magic); }, set() {} }); } catch {}
    });
  },
  'abort-on-property-write'(chain = '') {
    if (chain === '') return;
    trap(chain, (owner, prop) => {
      let value;
      try { value = owner[prop]; delete owner[prop]; } catch {}
      try { N.define(owner, prop, { configurable: false, get() { return value; }, set() { throw new N.ReferenceError(magic); } }); } catch {}
    });
  },
  'abort-current-script'(chain = '', rawNeedle = '', rawContext = '') {
    if (chain === '') return;
    const test = needle(rawNeedle), context = regex(rawContext);
    const ours = document.currentScript;
    const check = () => {
      const script = document.currentScript;
      if (!(script instanceof HTMLScriptElement) || script === ours) return;
      if (rawContext !== '' && !context.test(script.src)) return;
      if (test(script.textContent)) throw new N.ReferenceError(magic);
    };
    const [owner, prop] = resolve(chain);
    if (owner === undefined) return;
    const desc = N.descriptor(owner, prop);
    if (desc && desc.configurable === false) return;
    let value = owner[prop];
    try {
      N.define(owner, prop, {
        configurable: true,
        get() { check(); return desc?.get ? N.apply(desc.get, this, []) : value; },
        set(next) { check(); if (desc?.set) N.apply(desc.set, this, [next]); else value = next; },
      });
    } catch {}
  },
  'abort-on-stack-trace'(chain = '', rawNeedle = '') {
    if (chain === '') return;
    const test = needle(rawNeedle);
    const check = () => { if (test(new N.Error().stack ?? '')) throw new N.ReferenceError(magic); };
    trap(chain, (owner, prop) => {
      let value;
      try { value = owner[prop]; } catch {}
      try { N.define(owner, prop, { configurable: true, get() { check(); return value; }, set(next) { check(); value = next; } }); } catch {}
    });
  },
  'set-constant'(chain = '', raw = '') { setConstant(chain, raw, false); },
  'trusted-set-constant'(chain = '', raw = '') { setConstant(chain, raw, true); },
  'no-window-open-if'(pattern = '') {
    const test = needle(pattern);
    wrap('open', (target, thisArg, args) => {
      const url = args.length ? text(args[0]) : '';
      if (!test(url)) return N.apply(target, thisArg, args);
      const decoy = { closed: false, opener: self, name: '', location: { href: url, assign() {}, replace() {} } };
      for (const m of ['close', 'focus', 'blur', 'postMessage', 'moveTo', 'resizeTo', 'print', 'stop']) {
        decoy[m] = () => { if (m === 'close') decoy.closed = true; };
      }
      decoy.document = { write() {}, writeln() {}, open() {}, close() {}, body: null, documentElement: null };
      decoy.window = decoy.self = decoy;
      return decoy;
    });
  },
  'no-setTimeout-if'(n, d) { timerFilter('setTimeout', n, d); },
  'no-setInterval-if'(n, d) { timerFilter('setInterval', n, d); },
  'no-requestAnimationFrame-if'(rawNeedle = '') {
    const test = needle(rawNeedle);
    wrap('requestAnimationFrame', (target, thisArg, args) => {
      if (test(text(args[0]))) args = [function () {}];
      return N.apply(target, thisArg, args);
    });
  },
  'nano-setTimeout-booster'(n, d, b) { timerBoost('setTimeout', n, d, b); },
  'nano-setInterval-booster'(n, d, b) { timerBoost('setInterval', n, d, b); },
  'remove-node-text'(nodeName, pattern, ...rest) { nodeText(nodeName, pattern, undefined, rest); },
  'trusted-replace-node-text'(nodeName, pattern, replacement = '', ...rest) { nodeText(nodeName, pattern, replacement, rest); },
  'addEventListener-defuser'(rawType = '', rawHandler = '', ...rest) {
    const type = needle(rawType), handler = needle(rawHandler);
    // `elements`: only listeners on these (or `window`, `document`).
    const elements = option(rest, 'elements');
    const on = target => {
      if (!elements) return true;
      if (elements === 'window') return target === self;
      if (elements === 'document') return target === document;
      try { return target instanceof Element && target.matches(elements); } catch { return false; }
    };
    wrap('EventTarget.prototype.addEventListener', (target, thisArg, args) => {
      let fn = '';
      try { fn = text(args[1] instanceof Object && typeof args[1].handleEvent === 'function' ? args[1].handleEvent : args[1]); } catch {}
      if (type(String(args[0])) && handler(fn) && on(thisArg)) return;
      return N.apply(target, thisArg, args);
    });
  },
  'noeval'() { wrap('eval', () => undefined); },
  'noeval-if'(rawNeedle = '') {
    const test = needle(rawNeedle);
    wrap('eval', (target, thisArg, args) => test(text(args[0])) ? undefined : N.apply(target, thisArg, args));
  },
  'no-fetch-if'(spec = '', body = '') { blockFetch(spec, body, false); },
  'trusted-prevent-fetch'(spec = '', body = '') { blockFetch(spec, body, true); },
  'no-xhr-if'(spec = '', body = '') { blockXhr(spec, body, false); },
  'trusted-prevent-xhr'(spec = '', body = '') { blockXhr(spec, body, true); },
  'json-prune'(prune = '', needles = '', stack = '') {
    const run = pruner(prune, needles);
    const stackTest = stack === '' ? all : () => needle(stack)(new N.Error().stack ?? '');
    wrap('JSON.parse', (target, thisArg, args) => {
      const obj = N.apply(target, thisArg, args);
      if (stackTest()) run(obj);
      return obj;
    });
    wrap('Response.prototype.json', (target, thisArg, args) =>
      N.apply(target, thisArg, args).then(obj => { if (stackTest()) run(obj); return obj; }));
  },
  'json-prune-fetch-response'(prune = '', needles = '', ...rest) {
    const run = pruner(prune, needles);
    fetchResponses(props(option(rest, 'propsToMatch')) ?? all, body => {
      const obj = parseOr(body);
      return obj !== undefined && run(obj) ? N.stringify(obj) : undefined;
    });
  },
  'json-prune-xhr-response'(prune = '', needles = '', ...rest) {
    const run = pruner(prune, needles);
    xhrResponses(props(option(rest, 'propsToMatch')) ?? all, body => {
      const obj = parseOr(body);
      return obj !== undefined && run(obj) ? N.stringify(obj) : undefined;
    });
  },
  'json-edit'(q = '') {
    const edit = query(q, false);
    wrap('JSON.parse', (target, thisArg, args) => edit.apply(N.apply(target, thisArg, args)).root);
  },
  'trusted-json-edit'(q = '') {
    const edit = query(q, true);
    wrap('JSON.parse', (target, thisArg, args) => edit.apply(N.apply(target, thisArg, args)).root);
  },
  'json-edit-fetch-response'(q = '', ...rest) {
    fetchResponses(props(option(rest, 'propsToMatch')) ?? all, editText(query(q, false)));
  },
  'trusted-json-edit-fetch-response'(q = '', ...rest) {
    fetchResponses(props(option(rest, 'propsToMatch')) ?? all, editText(query(q, true)));
  },
  'json-edit-xhr-response'(q = '', ...rest) {
    xhrResponses(props(option(rest, 'propsToMatch')) ?? all, editText(query(q, false)));
  },
  'trusted-json-edit-xhr-response'(q = '', ...rest) {
    xhrResponses(props(option(rest, 'propsToMatch')) ?? all, editText(query(q, true)));
  },
  'json-edit-fetch-request'(q = '', ...rest) { editRequest(query(q, false), option(rest, 'propsToMatch')); },
  'trusted-json-edit-fetch-request'(q = '', ...rest) { editRequest(query(q, true), option(rest, 'propsToMatch')); },
  'edit-inbound-object'(chain = '', pos = '0', q = '') { editArgument(chain, pos, query(q, false)); },
  'trusted-edit-inbound-object'(chain = '', pos = '0', q = '') { editArgument(chain, pos, query(q, true)); },
  'edit-outbound-object'(chain = '', q = '') { editResult(chain, query(q, false)); },
  'trusted-edit-outbound-object'(chain = '', q = '') { editResult(chain, query(q, true)); },
  'trusted-replace-fetch-response'(pattern = '', replacement = '', spec = '') {
    if (pattern === '') return;
    fetchResponses(props(spec) ?? all, replaceText(pattern, replacement));
  },
  'trusted-replace-xhr-response'(pattern = '', replacement = '', spec = '') {
    if (pattern === '') return;
    xhrResponses(props(spec) ?? all, replaceText(pattern, replacement));
  },
  'trusted-replace-outbound-text'(chain = '', pattern = '', replacement = '', ...rest) {
    if (chain === '' || pattern === '') return;
    const condition = option(rest, 'condition');
    const when = condition ? regex(condition, 'ms') : undefined;
    const replace = replaceText(pattern, replacement);
    wrap(chain, (target, thisArg, args) => {
      const out = N.apply(target, thisArg, args);
      if (typeof out !== 'string' || (when && !when.test(out))) return out;
      return replace(out);
    });
  },
  'trusted-replace-argument'(chain = '', rawPos = '', raw = '', ...rest) {
    const pos = Number(rawPos);
    if (chain === '' || rawPos === '' || Number.isNaN(pos)) return;
    const condition = option(rest, 'condition');
    const when = condition ? needle(condition) : all;
    const repl = /^repl:\/(.+)\/(.*)\/$/s.exec(raw);
    let make;
    if (repl) {
      const re = regex('/' + repl[1] + '/');
      make = old => typeof old === 'string' ? old.replace(re, repl[2]) : old;
    } else if (raw.startsWith('json:')) {
      const v = parseOr(raw.slice(5));
      make = () => v;
    } else {
      const v = constant(raw, true);
      make = () => v?.value;
    }
    wrap(chain, (target, thisArg, args) => {
      const i = pos < 0 ? args.length + pos : pos;
      if (i >= 0 && i < args.length && when(text(args[i]))) { args = [...args]; args[i] = make(args[i]); }
      return N.apply(target, thisArg, args);
    });
  },
  'trusted-prevent-dom-bypass'(chain = '', property = '') {
    wrap(chain, (target, thisArg, args) => {
      const node = args[0];
      let frames = [];
      try {
        if (node instanceof HTMLIFrameElement) frames = [node];
        else if (node instanceof Element || node instanceof DocumentFragment) frames = [...node.querySelectorAll('iframe')];
      } catch {}
      const out = N.apply(target, thisArg, args);
      for (const frame of frames) {
        let w;
        try { w = frame.contentWindow; } catch {}
        if (!w || property === '') continue;
        try {
          const [mine, name] = resolve(property, self);
          const [theirs, same] = resolve(property, w);
          if (mine !== undefined && theirs !== undefined) N.define(theirs, same, { value: mine[name], configurable: true, writable: true });
        } catch {}
      }
      return out;
    });
  },
  'remove-attr'(rawAttrs = '', selector = '', behavior = '') {
    const attrs = rawAttrs.split(/\s*\|\s*/).filter(Boolean);
    if (attrs.length === 0) return;
    const query = selector || attrs.map(a => `[${CSS.escape(a)}]`).join(',');
    onElements(behavior, () => {
      for (const el of document.querySelectorAll(query)) for (const a of attrs) el.removeAttribute(a);
    });
  },
  'remove-class'(rawClasses = '', selector = '', behavior = '') {
    const classes = rawClasses.split(/\s*\|\s*/).filter(Boolean);
    if (classes.length === 0) return;
    const query = selector || classes.map(c => '.' + CSS.escape(c)).join(',');
    onElements(behavior, () => {
      for (const el of document.querySelectorAll(query)) el.classList.remove(...classes);
    });
  },
  'set-attr'(selector = '', attr = '', raw = '') { attributes(selector, attr, raw, false); },
  'trusted-set-attr'(selector = '', attr = '', raw = '') { attributes(selector, attr, raw, true); },
  'href-sanitizer'(selector = '', source = '') {
    if (selector === '') return;
    onElements('stay', () => {
      for (const el of document.querySelectorAll(selector)) {
        let url = '';
        try {
          if (source === '') url = el.textContent.trim();
          else if (/^\[.+\]$/.test(source)) url = el.getAttribute(source.slice(1, -1)) ?? '';
          else if (source.startsWith('?')) url = new URL(el.href).searchParams.get(source.slice(1)) ?? '';
          if (/^https?:\/\//.test(url) && el.getAttribute('href') !== url) el.setAttribute('href', url);
        } catch {}
      }
    });
  },
  'set-cookie'(name = '', value = '', path = '') { setCookie(name, value, path, false); },
  'trusted-set-cookie'(name = '', value = '', _offset = '', path = '') { setCookie(name, value, path, true); },
  'remove-cookie'(pattern = '') { removeCookie(pattern); },
  'set-local-storage-item'(key = '', value = '') { storage('localStorage', key, value, false); },
  'trusted-set-local-storage-item'(key = '', value = '') { storage('localStorage', key, value, true); },
  'set-session-storage-item'(key = '', value = '') { storage('sessionStorage', key, value, false); },
  'trusted-set-session-storage-item'(key = '', value = '') { storage('sessionStorage', key, value, true); },
  'nowebrtc'() {
    for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection']) {
      if (typeof self[name] !== 'function') continue;
      self[name] = new N.Proxy(self[name], {
        construct() {
          const peer = new EventTarget();
          for (const m of ['close', 'setConfiguration', 'addIceCandidate', 'setLocalDescription', 'setRemoteDescription']) peer[m] = () => N.Promise.resolve();
          peer.createDataChannel = () => new EventTarget();
          peer.createOffer = peer.createAnswer = () => N.Promise.resolve({});
          return peer;
        },
      });
    }
  },
  'nofab'() {
    const Fab = function () {};
    Fab.prototype = {
      check() {}, clearEvent() {}, emitEvent() {}, setOption() { return this; },
      on(detected, fn) { if (!detected && typeof fn === 'function') fn(); return this; },
      onDetected() { return this; },
      onNotDetected(fn) { if (typeof fn === 'function') fn(); return this; },
    };
    for (const name of ['FuckAdBlock', 'BlockAdBlock']) {
      try { N.define(self, name, { value: Fab, configurable: false }); } catch {}
    }
    for (const name of ['fuckAdBlock', 'blockAdBlock']) {
      try { N.define(self, name, { value: new Fab(), configurable: false }); } catch {}
    }
  },
  'popads-dummy'() {
    for (const name of ['PopAds', 'popns']) {
      try { delete self[name]; N.define(self, name, { value: {}, configurable: false }); } catch {}
    }
  },
  'popads.net'() {
    for (const name of ['PopAds', 'popns']) S['abort-on-property-read'](name);
  },
};

for (const [name, ...args] of calls) {
  try { S[name]?.(...args); } catch {}
}
})();
"""#
}

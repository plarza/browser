extension ScriptletLibrary {
    /// What the scriptlets are written with: patterns from a filter's text,
    /// property chains and the traps set on them, and the fetch and
    /// XMLHttpRequest responses a scriptlet can rewrite.
    static let helpers = #"""
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
"""#
}

extension ScriptletLibrary {
    /// What several scriptlets share: a plain scriptlet and its `trusted-`
    /// twin, or the setTimeout and setInterval pair, are one body each.
    static let bodies = #"""
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
"""#
}

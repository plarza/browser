extension ScriptletLibrary {
    /// The scriptlets by uBlock Origin's names. `names` reads its entries,
    /// so each starts a line as `  'name'(`.
    static let scriptlets = #"""
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
"""#
}

extension UserscriptRuntime {
    /// Whether the script runs here at all, then what every part after
    /// this one stands on: the page's own functions, taken before the page
    /// can replace them, and the way to and from the app.
    ///
    /// `send` posts a message to the bridge with the secret; `receive` is
    /// where each part leaves the function that hears its kind of message
    /// from the app.
    static let start = #"""
      'use strict';
      const W = window, D = document;
      if (!/^(?:https?|file):$/.test(location.protocol)) return;
      const href = location.href;
      const test = r => { try { return new RegExp(r[0], r[1]).test(href); } catch (e) { return false; } };
      if (!(C.everywhere || C.include.some(test)) || C.exclude.some(test)) return;
      if (C.noframes && W.top !== W) return;
      if (C.framesOnly && W.top === W) return;
      const handlers = W.webkit && W.webkit.messageHandlers;
      const handler = handlers && handlers[C.handler];
      const post = handler ? handler.postMessage.bind(handler) : null;
      const define = Object.defineProperty, keys = Object.keys, apply = Reflect.apply, then = Promise.prototype.then;
      const Proxy_ = Proxy, get = Reflect.get, set = Reflect.set, has = Object.prototype.hasOwnProperty;
      const rand = () => Math.random().toString(36).slice(2);
      const listen = EventTarget.prototype.addEventListener, parse = JSON.parse, stringify = JSON.stringify;
      const URL_ = URL, Blob_ = Blob, TextDecoder_ = TextDecoder, DOMParser_ = DOMParser, atob_ = atob, btoa_ = btoa;
      const timeout = setTimeout, error = console.error.bind(console), log = console.log.bind(console);
      const instance = Math.random().toString(36).slice(2);
      const send = (op, args) => post
        ? post({s: C.secret, id: C.id, instance, op, args: args === undefined ? null : args})
        : Promise.reject(new Error('Userscripts are unavailable here'));
      const quiet = p => { apply(then, p, [undefined, () => {}]); return p; };
      const receive = Object.create(null);
      const name = C.info.script.name;
      const report = e => error('[' + name + ']', e);
      const resolve = url => new URL_(url, href).href;
      const bytes = b64 => { const s = atob_(b64); const a = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return a; };
      const base64 = buffer => {
        const a = new Uint8Array(buffer); let s = '';
        for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode.apply(null, a.subarray(i, i + 0x8000));
        return btoa_(s);
      };
    """#
}

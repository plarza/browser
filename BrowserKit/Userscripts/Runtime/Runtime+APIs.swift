extension UserscriptRuntime {
    /// What the script's function is called with: `GM_info`, `GM`,
    /// `unsafeWindow`, then each API it was granted under its `GM_` name
    /// (the same API is on `GM` too, answering with a promise), and its
    /// own `window` if it was granted `window.close` or `window.focus`.
    static let apis = #"""
      const promised = f => (...a) => { try { return Promise.resolve(f(...a)); } catch (e) { return Promise.reject(e); } };
      const table = {
        getvalue: [getValue, ['getValue', promised(getValue)]],
        setvalue: [(k, v) => { setValue(k, v); }, ['setValue', setValue]],
        deletevalue: [k => { deleteValue(k); }, ['deleteValue', deleteValue]],
        listvalues: [listValues, ['listValues', promised(listValues)]],
        getvalues: [getValues, ['getValues', promised(getValues)]],
        setvalues: [o => { setValues(o); }, ['setValues', setValues]],
        deletevalues: [k => { deleteValues(k); }, ['deleteValues', deleteValues]],
        addvaluechangelistener: [addValueChangeListener, ['addValueChangeListener', promised(addValueChangeListener)]],
        removevaluechangelistener: [removeValueChangeListener, ['removeValueChangeListener', promised(removeValueChangeListener)]],
        getresourcetext: [getResourceText, ['getResourceText', promised(getResourceText)]],
        getresourceurl: [getResourceURL, ['getResourceUrl', promised(getResourceURL)], ['getResourceURL', promised(getResourceURL)]],
        addstyle: [addStyle, ['addStyle', promised(addStyle)]],
        addelement: [addElement, ['addElement', promised(addElement)]],
        openintab: [openInTab, ['openInTab', promised(openInTab)]],
        registermenucommand: [registerMenuCommand, ['registerMenuCommand', promised(registerMenuCommand)]],
        unregistermenucommand: [unregisterMenuCommand, ['unregisterMenuCommand', promised(unregisterMenuCommand)]],
        notification: [notification, ['notification', promised(notification)]],
        setclipboard: [setClipboard, ['setClipboard', setClipboard]],
        xmlhttprequest: [xhr, ['xmlHttpRequest', xhrPromise]],
        download: [download, ['download', download]],
        log: [log, ['log', promised(log)]],
      };
      const info = C.info;
      const gm = {info};
      const api = {GM_info: info, GM: gm, unsafeWindow: W};
      for (const [grant, legacy] of C.apis) {
        const t = table[grant];
        if (!t) continue;
        api[legacy] = t[0];
        for (let i = 1; i < t.length; i++) gm[t[i][0]] = t[i][1];
      }
      if (C.params.includes('window')) {
        // The script's own `window`: the page's, with close and focus that
        // reach its tab. Page methods are called on the real window.
        const own = Object.create(null);
        if (C.grants.includes('window.close')) own.close = () => { quiet(send('closeWindow')); };
        if (C.grants.includes('window.focus')) own.focus = () => { quiet(send('focusWindow')); };
        const bound = new WeakMap();
        api.window = new Proxy_(W, {
          get(target, key) {
            if (apply(has, own, [key])) return own[key];
            const value = get(target, key);
            if (typeof value !== 'function' || 'prototype' in value) return value;
            let b = bound.get(value);
            if (!b) { b = value.bind(target); bound.set(value, b); }
            return b;
          },
          set(target, key, value) { return set(target, key, value); },
        });
      }
      const args = C.params.map(p => api[p]);
    """#
}

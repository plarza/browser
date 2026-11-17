extension UserscriptRuntime {
    /// GM_openInTab. What it returns is there at once, before the app has
    /// opened the tab: a `close()` in between is carried out when it has.
    static let tabs = #"""
      const tabs = Object.create(null);
      const openInTab = (url, opts) => {
        const o = opts && typeof opts === 'object' ? opts : {active: opts === undefined ? true : !opts};
        const active = o.active !== undefined ? !!o.active : !o.loadInBackground;
        let tab = null, closing = false;
        const handle = {closed: false, onclose: null, close() { closing = true; if (tab) quiet(send('closeTab', {tab})); }};
        apply(then, send('openInTab', {url: resolve(url), active}), [id => {
          if (!id) return;
          tab = id;
          tabs[id] = handle;
          if (closing) quiet(send('closeTab', {tab}));
        }, report]);
        return handle;
      };
      receive.tabclosed = msg => {
        const t = tabs[msg.tab];
        if (!t) return;
        delete tabs[msg.tab];
        t.closed = true;
        if (typeof t.onclose === 'function') try { t.onclose(); } catch (e) { report(e); }
      };
    """#
}

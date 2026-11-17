extension UserscriptRuntime {
    /// GM_download. The app does the downloading; `onprogress`, then
    /// `onload`, `onerror` or `onabort`, come back as messages. What it
    /// returns is a promise with `abort()`.
    static let downloads = #"""
      const saving = Object.create(null);
      const download = (url, n) => {
        const o = url && typeof url === 'object' ? url : {url, name: n};
        const did = rand();
        const call = (event, arg) => { const f = o[event]; if (typeof f === 'function') try { f(arg); } catch (e) { report(e); } };
        let ok, fail;
        const p = new Promise((a, b) => { ok = a; fail = b; });
        apply(then, p, [undefined, () => {}]);
        saving[did] = m => {
          const progress = {loaded: m.loaded, total: m.total, lengthComputable: m.total > 0};
          if (m.event === 'progress') return call('onprogress', progress);
          delete saving[did];
          if (m.event === 'load') { call('onload', progress); ok(); return; }
          const e = {error: m.event === 'abort' ? 'aborted' : (m.error || 'failed'), details: m.error || ''};
          call(m.event === 'abort' ? 'onabort' : 'onerror', e);
          fail(e);
        };
        let target;
        try { target = resolve(o.url); } catch (e) { saving[did]({event: 'error', error: String(e)}); return p; }
        const headers = {};
        for (const k of keys(o.headers || {})) headers[k] = String(o.headers[k]);
        apply(then, send('download', {did, url: target, name: o.name || null, headers}), [undefined, e => {
          if (saving[did]) saving[did]({event: 'error', error: String(e && e.message || e)});
        }]);
        p.abort = () => { if (saving[did]) quiet(send('abortDownload', {did})); };
        return p;
      };
      receive.download = msg => {
        const f = saving[msg.did];
        if (f) f(msg);
      };
    """#
}

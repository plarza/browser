extension UserscriptRuntime {
    /// GM_getValue, GM_setValue and the rest. The values are here, each as
    /// JSON, from the moment the script starts, so reading one never
    /// waits; writing one tells the app, which tells the script's other
    /// copies, whose change listeners hear it as remote.
    static let values = #"""
      const values = Object.create(null);
      for (const [k, v] of C.values) values[k] = v;
      const listeners = new Map();
      let nextListener = 1;
      const notify = (key, oldRaw, newRaw, remote) => {
        const decode = raw => { if (raw == null) return undefined; try { return parse(raw); } catch (e) { return undefined; } };
        listeners.forEach(l => { if (l.key === key) try { l.cb(key, decode(oldRaw), decode(newRaw), remote); } catch (e) { report(e); } });
      };
      const getValue = (key, def) => {
        const raw = values[String(key)];
        if (raw === undefined) return def;
        try { return parse(raw); } catch (e) { return def; }
      };
      const deleteValue = key => {
        key = String(key);
        const old = values[key];
        if (old === undefined) return Promise.resolve();
        delete values[key];
        notify(key, old, null, false);
        return quiet(send('setValue', {key, value: null}));
      };
      const setValue = (key, value) => {
        key = String(key);
        if (value === undefined) return deleteValue(key);
        const raw = stringify(value), old = values[key];
        values[key] = raw;
        if (old !== raw) notify(key, old, raw, false);
        return quiet(send('setValue', {key, value: raw}));
      };
      const listValues = () => keys(values);
      const getValues = arg => {
        const out = {};
        if (Array.isArray(arg)) { for (const k of arg) { const v = getValue(k); if (v !== undefined) out[k] = v; } }
        else for (const k of keys(arg || {})) out[k] = getValue(k, arg[k]);
        return out;
      };
      const setValues = obj => { for (const k of keys(obj || {})) setValue(k, obj[k]); return Promise.resolve(); };
      const deleteValues = list => { for (const k of list || []) deleteValue(k); return Promise.resolve(); };
      const addValueChangeListener = (key, cb) => { const id = nextListener++; listeners.set(id, {key: String(key), cb}); return id; };
      const removeValueChangeListener = id => { listeners.delete(id); };
      receive.value = msg => {
        const old = values[msg.key];
        if (msg.value == null) delete values[msg.key]; else values[msg.key] = msg.value;
        if (old !== msg.value) notify(msg.key, old, msg.value, true);
      };
    """#
}

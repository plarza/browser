extension UserscriptRuntime {
    /// GM_notification, in both of its forms: one object, or text, title,
    /// image and onclick. `onclick` and `ondone` come back as messages.
    static let notifications = #"""
      const notes = Object.create(null);
      const notification = (text, title, image, onclick) => {
        const o = text && typeof text === 'object' ? text : {text, title, image, onclick};
        const nid = rand();
        let identifier = null, removed = false;
        notes[nid] = o;
        apply(then, send('notify', {
          nid, text: String(o.text || ''), title: String(o.title || name), image: o.image ? resolve(o.image) : null,
          silent: !!o.silent, tag: o.tag != null ? String(o.tag) : null, timeout: +o.timeout || 0,
        }), [id => { identifier = id; if (removed && id) quiet(send('unnotify', {identifier: id})); }, report]);
        return {remove: () => { removed = true; return identifier ? quiet(send('unnotify', {identifier})) : Promise.resolve(); }};
      };
      receive.notification = msg => {
        const o = notes[msg.nid];
        if (!o) return;
        if (msg.event === 'click' && typeof o.onclick === 'function') try { o.onclick(); } catch (e) { report(e); }
        if (msg.event === 'done') {
          delete notes[msg.nid];
          if (typeof o.ondone === 'function') try { o.ondone(); } catch (e) { report(e); }
        }
      };
    """#
}

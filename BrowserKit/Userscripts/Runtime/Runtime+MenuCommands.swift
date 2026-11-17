extension UserscriptRuntime {
    /// GM_registerMenuCommand and GM_unregisterMenuCommand. The app lists
    /// the commands; picking one comes back here as a `menu` message.
    static let menuCommands = #"""
      const commands = Object.create(null);
      const registerMenuCommand = (caption, cb, opts) => {
        const o = opts && typeof opts === 'object' ? opts : {};
        const id = o.id != null ? String(o.id) : String(caption);
        commands[id] = cb;
        quiet(send('menu', {cmd: id, caption: String(caption)}));
        return id;
      };
      const unregisterMenuCommand = id => { delete commands[String(id)]; quiet(send('unmenu', {cmd: String(id)})); };
      receive.menu = msg => {
        const cb = commands[msg.cmd];
        if (typeof cb === 'function') try { cb(new MouseEvent('click')); } catch (e) { report(e); }
      };
    """#
}

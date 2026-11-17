extension UserscriptRuntime {
    /// GM_setClipboard.
    static let clipboard = #"""
      const setClipboard = (data, info) => {
        const type = typeof info === 'string' ? info : (info && (info.mimetype || info.type)) || 'text/plain';
        return quiet(send('clipboard', {data: String(data), type}));
      };
    """#
}

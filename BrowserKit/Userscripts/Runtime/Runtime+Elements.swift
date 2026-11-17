extension UserscriptRuntime {
    /// GM_addElement and GM_addStyle.
    static let elements = #"""
      const root = () => D.head || D.documentElement || D;
      const addElement = (parent, tag, attrs) => {
        if (typeof parent === 'string') { attrs = tag; tag = parent; parent = null; }
        const el = D.createElement(tag);
        for (const k of keys(attrs || {})) { if (k === 'textContent') el.textContent = attrs[k]; else el.setAttribute(k, attrs[k]); }
        (parent || (/^(?:script|style|link|meta)$/i.test(tag) ? root() : (D.body || root()))).appendChild(el);
        return el;
      };
      const addStyle = css => addElement('style', {textContent: String(css)});
    """#
}

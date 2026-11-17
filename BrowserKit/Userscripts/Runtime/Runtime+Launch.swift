extension UserscriptRuntime {
    /// Leaves the function the app tells this copy things through, under a
    /// name no page can guess, then runs the script at its @run-at, telling
    /// the app as it starts.
    static let launch = #"""
      define(W, C.hook, {configurable: false, enumerable: false, writable: false, value: msg => {
        const f = msg && receive[msg.type];
        if (f) f(msg);
      }});
      const go = () => {
        quiet(send('run', {top: W.top === W}));
        try {
          const r = apply(run, W, args);
          if (r && typeof r.then === 'function') apply(then, r, [undefined, report]);
        } catch (e) { report(e); }
      };
      const at = C.runAt;
      if (at === 'document-start') go();
      else if (at === 'document-body') {
        if (D.body) go();
        else {
          const watch = new MutationObserver(() => { if (D.body) { watch.disconnect(); go(); } });
          watch.observe(D.documentElement || D, {childList: true, subtree: true});
        }
      } else {
        const ready = () => { if (at === 'document-idle') timeout(go, 0); else go(); };
        if (D.readyState === 'loading') apply(listen, D, ['DOMContentLoaded', ready, {once: true}]); else ready();
      }
    """#
}

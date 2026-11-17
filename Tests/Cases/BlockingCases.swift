#if DEBUG
import AppKit
import BrowserKit

/// The filter lists: compiled into WebKit's content rules, with their
/// hides and their scriptlets.
extension SelfTest {
    var blockingCases: [Case] {
        [Case("filter lists") { await self.filterLists() }]
    }

    private func filterLists() async {
        await expect("the filter lists compile into the blocker, split as WebKit needs", seconds: 60, {
            Blocker.shared.ruleCount >= TestSite.ruleCount || Blocker.shared.trouble != nil
        })
        check("…with nothing going wrong", Blocker.shared.trouble == nil && Blocker.shared.ruleCount >= TestSite.ruleCount,
              "rules=\(Blocker.shared.ruleCount) trouble=\(Blocker.shared.trouble ?? "none")")
        let tab = await open(server.url("/page/one"))
        let fetched = await js(tab, "fetch('/ad-banner.js').then(() => 'loaded', () => 'blocked')", in: .page, awaiting: true) as? String
        check("a request a list names is blocked", fetched == "blocked", "fetch=\(fetched ?? "no answer")")
        let scripted = await open(server.url("/scriptlets"))
        let hidden = await js(scripted, "getComputedStyle(document.querySelector('.sponsor')).display", in: .page) as? String
        check("a list's hide for a site hides it there", hidden == "none", "display=\(hidden ?? "nil")")
        let pruned = await js(scripted, "window.pruned", in: .page) as? String
        check("a list's scriptlet runs before the page's own scripts", pruned == #"{"content":2}"#, "pruned=\(pruned ?? "nil")")
        let replaced = await js(scripted, "window.replaced", in: .page) as? Int
        check("a script's text is replaced once, even when the replacement contains what it replaced", replaced == 1,
              "replaced=\(replaced.map(String.init) ?? "nil")")
        await expect("…and in a frame from another site, with that site's rules", {
            await js(scripted, "window.framed", in: .page) as? String == "true"
        })
        let plain = await open(server.url("/scriptlets", on: server.other))
        let untouched = await js(plain, "window.pruned", in: .page) as? String
        let shown = await js(plain, "getComputedStyle(document.querySelector('.sponsor')).display", in: .page) as? String
        check("…and not on another site", shown == "block", "display=\(shown ?? "nil")")
        check("a site the rule doesn't name runs it not", untouched == #"{"ads":1,"content":2}"#, "pruned=\(untouched ?? "nil")")
    }
}
#endif

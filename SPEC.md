# Browser

Browser is a macOS browser with isolated tab identities and system WebKit privacy protections. The UI is kept deliberately plain, just enough to use it as a browser.

## Shape

```
BrowserKit/     Swift framework: tabs, sessions, wipe, blocking, bangs, policy.
             Every rule below lives here or in the system WebKit configuration. Its API has no
             switches that weaken them.
App/         thin AppKit shell: window, vertical tabs, address field, settings
release/     build, sign, notarize, publish to Forgejo, update feed
```

- Apple Silicon only, on the current macOS.
- The app uses the system WebKit and JavaScriptCore. Engine updates follow the operating system.

## Tabs

- Tabs run down the left, in a vertical list, in a pure white sidebar, flush with the page and with no dividing line, whose edge drags (200–420 pt). The page fills the rest of the window. Every launch opens the window filling the screen, short of the menu bar and Dock, not in full screen. There are no pinned tabs, no back/forward buttons and no New Tab button: ⌘T, ⌘[ and ⌘] do those, and a two-finger swipe goes back or forward.
- Each tab is a separate identity, with its own web process and its own network session. The session holds the tab's cookies, localStorage, sessionStorage, IndexedDB, Cache API, service workers, HTTP cache, HSTS, TLS session cache, connection pool and DNS cache.
- **Wipe.** Every reload and every top-level navigation throws the whole session away and starts the next load in a brand-new one. That includes typed URLs, clicked links, back and forward, and redirects initiated by the page. Logins do not survive a reload. The page showing stays up, frozen, until the next one has drawn (or three seconds after it commits), as Safari keeps a page up, so a wipe never flashes blank.
- **Persist** (⌘I, or right-click › Persist Tab). The tab keeps its session through reloads and navigation. The tab turns a soft sky blue while it is on. Persist belongs to the tab, not the site. Turning it on moves the tab into a jar of its own on disk, taking its cookies and the current page's storage with it, so the tab and its session survive quitting Browser. Closing the tab, or turning Persist off, deletes that jar; jars nothing refers to are deleted at launch. Closing a Persist tab yourself (⌘W, its ✕, its menu, middle-click) asks first; a page or extension closing it doesn't.
- **Popups.** A `window.open` popup, such as an OAuth or 3-D Secure window, shares its opener's session and dies with it. Links opened in a new tab (⌘-click, middle-click) start fresh.
- **Closing a tab** destroys its session. Quitting the app destroys every session.

## Whitelist

- Settings holds a list of domains, meant for your self-hosted sites. A whitelisted domain and its subdomains get one jar on disk (encrypted at rest by FileVault), shared by every tab, that survives refresh, close and quit. The jar holds both cookies and site storage.

## Fingerprinting

Browser uses Safari's user agent and WebKit's existing privacy protections. Fingerprint noise is managed by WebKit; wiping a tab clears its website data, with no guarantee that every fingerprint surface changes. Browser does not patch page prototypes to disguise browser APIs.

- **Protections:** baseline protections, fingerprinting protections and link-decoration filtering are enabled through WebKit's private webpage-policy API on every navigation. Browser does not force a hardware concurrency value or the separate script-tracking privacy policy.
- **User agent:** Safari's for this macOS version.
- **Language and time zone:** the app requests en-US and sets UTC for its WebKit process pool.
- **Screen, fonts, canvas, audio and WebGL:** WebKit's own behavior and fingerprinting mitigations apply.
- **JavaScript engine.** JavaScript and WebAssembly use JavaScriptCore's normal JIT policy. There is no Browser setting to disable it.
- **WebRTC.** WebKit's default behavior applies, including its candidate filtering. Browser does not force TURN relays.
- **Media devices.** WebKit's default applies: no labels and no IDs until permission is granted.

## Network

- No proxy or Tor is built in. The user brings their own VPN. Browser does not enable WebKit's enhanced network privacy (iCloud Private Relay); traffic follows the system network configuration.
- **HTTPS-only.** Every load is upgraded to HTTPS, except to this Mac itself (`localhost`, `127.0.0.1`, `::1`), which never leaves the machine. If the upgrade fails, an interstitial offers to continue over HTTP for that one load in that tab.
- **Third-party cookies** are never allowed. Referer is trimmed to the origin when the request crosses sites.
- **Tracking parameters** (`utm_*`, `fbclid`, `gclid`, `mc_eid` and similar) are stripped from every navigation.
- **Content blocking** happens in the engine, through WebKit content rule lists compiled from filter lists (split into lists of at most 150,000 rules, WebKit's limit). The defaults are uBO filters, EasyList, EasyPrivacy, Peter Lowe's list, URLhaus and AdGuard Cookie Notices. The lists are fetched once a day, and their URLs can be edited in Settings. Element-hiding (cosmetic) rules are applied too.

## JavaScript

- JavaScript is on everywhere. **JIT is on** for JavaScript and WebAssembly on macOS. It has no setting.

## Permissions

- Location, notifications, MIDI, USB, serial, HID, Bluetooth, sensors, clipboard reads and persistent storage are always denied.
- Camera and microphone ask every time, and the answer is never remembered.

## Address field and search

- One field takes both URLs and search terms. Browser has **no default search engine**: until you set one in Settings, plain words show "No search engine set".
- **Bangs** (`!g`, `!w`, `!gh` and so on) come from Browser's own table, compiled into the app and matched locally. Nothing is fetched for them. A bang works whether or not a search engine is set.

## Remembered on disk

- **History:** each page's address, title, visit count, when it was last visited and its frecency, with no icons or page contents, in a SQLite file (`history.db`) whose deleted rows are overwritten. Frecency works as Firefox's does: each visit adds its weight (2 typed or picked in the address field, 1 a link, ¼ a reload, a tab reopened at launch, or a page that sent itself on by script) and the total halves every 30 days. History also keeps what was typed before picking a page from the list under the address field; each pick counts more, up to a limit, and fades by 2.5% a day, gone after about 90 days unused. It feeds the address field, looked up off the main thread: inline completion of a visited site's name (the most frecent), and a list of matching pages underneath, with pages picked before for what's typed first (at most half the list), then the rest by where the words match plus frecency. And **about://history** (⌘H): a page of its own, opened in a new tab, that searches every word across addresses and titles, removes entries one at a time, or clears everything. Removing a page or clearing History removes its picks too. Like about://settings and about://help, it is a native view in the tab, not a web page.
- **Open tabs:** URLs, and for a Persist tab the id of its jar. They come back on the next launch: a Persist tab in its jar, every other tab in a fresh session. Until first shown, a reopened tab is titled from History, so no title is written anywhere else; a page not in History shows its host.
- **Whitelist jars**, as described under Whitelist.
- **Extension data.** Extensions' own storage, such as the Bitwarden vault, is kept.
- Settings.
- **Favicons** are read from the page's own `<link rel=icon>` through WebKit's isolated client world (invisible to the page) and fetched with no cookies. An icon is kept on disk, under a hashed name, only for a site already in History or on the whitelist, so it records nothing those don't. Removing a site from History removes its icon; clearing History clears them all. A kept icon is never fetched again.
- **Downloads:** each file's name, where it was saved, its size and the site it came from, for about://downloads, until Clear Downloads.
- Nothing else is written: no cache.

## Extensions

- Only Safari web extensions run: Browser finds them inside the apps in /Applications and ~/Applications and loads them, unmodified, on WebKit's WKWebExtension engine. Settings lists them with a switch each. Their pages load from `safari-web-extension://`, as in Safari, at an address fixed per extension, so what they store survives a relaunch. Each extension's id is Safari's, the bundle id with its signing team (`me.proton.pass.catalyst.safari-extension (2SB5Z68H26)`), because sites that message an extension (`externally_connectable`, as Proton's sign-in does) address it by that id. Bitwarden is the expected password manager. Browser has no built-in password store.
- Extension content scripts can change pages in ways that are visible, so turning an extension on is a fingerprinting trade-off the user chooses to make. Enabled extensions can access Browser’s ephemeral tabs within their requested site permissions.
- Extension buttons can be dragged into a new order, which is saved. Popups fit their contents, with an opaque background unless the extension supplies its own.

## Mouse and trackpad

- The mouse's back and forward buttons, and two-finger swipes, go through Browser's own back and forward lists, the same as ⌘[ and ⌘]. As in Safari, a swipe back slides the page off to the right with the fingers, a picture of the page before coming out from under it; forward slides the page after in over it. Pictures of the last few pages are kept in memory only, never on disk.
- Middle-clicking a link opens it in a fresh tab. Hovering a tab reveals an x to close it.

## Downloads

- Every download opens the save panel at `~/Downloads`. Cancelling one asks first, then deletes the partial file and takes it off the sidebar; about://downloads lists it as Cancelled. Files keep their quarantine flag.
- This session's downloads sit at the foot of the sidebar in the tabs' row style, newest first, each row's background filling as it downloads, its total size on the right. Hovering a download in progress turns the size into an x that cancels it; a finished one has a minus that takes it off, and goes by itself after a minute. Clicking a finished one shows it in Finder.
- Browser's own pages (about://history, downloads, settings, help) show the logo in grey as their icon.
- **about://downloads** (⌘J) lists every download until it is cleared.

## Settings (the whole list)

Settings is a page, **about://settings** (⌘,), with: where new tabs open (below the current tab, at the top, or at the bottom); what a blank tab shows (a picture, the default or one chosen in Finder; a colour; or blank, the desktop frosted through the window), and whether that fills the whole window behind a frosted sidebar, with notched sliders for the sidebar's blur and transparency;

1. Search engine (URL template)
2. Cookie whitelist (domains)
3. Filter list URLs
4. Extensions

## Keyboard

Listed at about://help (⇧⌘/), read from the menus. In every dialog, Return confirms and Escape cancels.

## Builds and updates

- **System engine.** Every build links directly to macOS WebKit. The app contains one executable and its resources.

- **Source.** The repository is `aza/browser` on `git.aza.network` (Forgejo), mirrored publicly to `github.com/plarza/browser` by a Forgejo push mirror on every push (an SSH deploy key, so Forgejo holds no GitHub token); push to Forgejo only. A `forgejo-runner` in host mode runs on this Mac with the label `macos-arm64`.
- **Releases.** Pushing a tag builds the app, signs it with the Developer ID, notarizes them, and uploads the DMG to Forgejo Releases.
- **Updates** are manual: install the new DMG from the release. Browser never checks for updates itself.
- **Telemetry.** None. The only request Browser makes on its own is the daily filter-list fetch.

Appearance in Settings offers Light, Dark and System. System is the default and follows macOS, including changes while Browser is open. Browser’s internal pages use the grey logo glyph with no background.

## Known gaps

System WebKit does not give Browser control over fingerprint noise lifetimes. WebGL results, fonts, speech voices and media device kinds may remain recognisable across identity wipes. Storage isolation does not guarantee anonymity against fingerprinting.

## iPhone

There is no iPhone app in the repository: it is to be built from this section, as `iOS/`, on top of BrowserKit, which already compiles for iOS (UIKit where AppKit differs). Every Tabs, Whitelist, Network, Permissions, Address and History rule above holds. What follows is what differs from the Mac, and what was learned building the last one.

### The app

- Called Browser, bundle id `network.aza.browser`, team `H5A6B4L9W8`, iPhone only, portrait only, iOS 26 and later. Icon from `release/Browser.icon`; the default new tab picture is `release/morning.webp`; search engine icons are in `release/engines`.
- Animations run at up to 120 Hz (`CADisableMinimumFrameDurationOnPhone`).
- Camera and microphone ask every time: "A website asked for the camera. Browser asks you each time." (and the same for the microphone). Saving an image from a page asks for photo library add access.
- Downloads go to `Downloads` in Browser's own folder in the Files app (file sharing on, opened in place). A name already taken gets " 2", " 3" and so on before its extension. Starting one says "Downloading <name>".
- `ITSAppUsesNonExemptEncryption` is NO.
- Only the system's WebKit runs on iOS outside the EU and Japan. Safari extensions belong to other apps and are out of reach, so there are none. Browser uses WebKit's private API, so it is never sent to the App Store; it goes out through TestFlight, to internal testers only.
- `iOS/build.sh` builds for the simulator; `device` installs on a connected iPhone; `testflight` archives a Release build with a build number higher than the last (the UTC time, `YYYYMMDDHHMM`) and uploads it with the App Store Connect key in `ASC_KEY_ID` and `ASC_ISSUER_ID` (the key at `~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8`).
- Before WebKit starts a process, the app sets `AppleLanguages` to `en-US` and `AppleLocale` to `en_US` in its own defaults, so every web process reports en-US. BrowserKit's configuration already sets UTC.
- Open tabs are saved whenever the app leaves the foreground, and come back at launch as on the Mac. http and https links from other apps open in a new tab.

### Look

- Liquid Glass throughout. Behind the grid and the cards, Arc's and Safari's soft lavender: light, a diagonal of `#E8E6F7`, `#DBDBF0`, `#EBE3ED`; dark, `#1F1F2B` to `#141419`.
- Persist is the Mac's blue, `#5C99FF`: a ring on a Persist tab's address bar and on its card.
- A frost behind the clock fades into the page, so text scrolling up never runs into the clock.
- Short messages ("No search engine set. Add one in Settings.") drop in as a glass capsule along the top and go by themselves.
- Appearance (Light, Dark, System) applies to the whole app.

### Bar

- Along the bottom, over the page: Arc's stack of tabs, the address bar (the site's name, without `www.`; Browser's own pages by name), and New Tab.
- **The stack.** Small pictures of the tabs, slightly turned: the tab to the left of the one showing at the back, the one showing in front. A swipe between tabs deals them along with the finger. Tapping it opens the grid.
- Scrolling down the page shrinks the bar to the site's name alone; scrolling back up, reaching the top, or tapping it brings it back.
- A thin line along the address bar's bottom edge shows loading.
- Long press on the address bar: Persist (not for a popup), Reload, Copy Link, Find on Page (the system's find bar), Share.
- Dragging the address bar sideways pulls the next or previous tab in beside the page, 12 pt apart, as in Safari. The address changes as the swipe passes halfway. Letting go past a third of the way (counting the flick) moves to that tab; at the first or last tab the page only gives a little.
- Dragging it up shrinks the page into its card in the grid, under the finger (about 320 pt takes it all the way). Letting go finishes or springs back at the finger's speed.

### Pages

- Back and forward are swipes from the screen's left and right edges, as in Safari. Going back, the page follows the finger off to the right, with a shadow, and the page before comes out from under it, moving a third as far. Going forward, the page after slides in over it. Letting go past a third of the way (counting the flick) finishes; the picture stays until the real page draws (see `Tab.view.hold`). Pull down to reload. There are no buttons.
- The page fills the screen and scrolls under the clock and the bar. WebKit is told what they cover, so a page's top starts below the clock and its end scrolls clear of the bar.
- Browser's own pages (History, Downloads, Settings, Help) show in the tab as native screens. History's search field is at the top: along the bottom, the bar would cover it.
- A tab with nowhere to go shows the new tab page: the picture, colour or blank chosen in Settings.
- A page's alert, confirm and prompt are system alerts. The file picker is WebKit's own.

### Address sheet

- Tapping the address bar (or New Tab) brings up a glass sheet from the bottom. What's behind steps back into a card above it: scaled to 92% from its top, 36 pt down, its corners rounded. Tapping the card, or pulling the sheet down, puts it away.
- At the top of the sheet, the field, already focused, with the address selected to type over (New Tab: empty). Under it, pages from History (BrowserKit's completion, looked up as you type). If what's typed isn't an address, a last row searches for it. Nothing is fetched while typing. The list scrolls clear of the keyboard; the keyboard covers whatever is under it, and nothing moves out of its way.
- Typing more fills in the rest of the most frecent site, selected, as Safari does; deleting never fills back in. Picking a page tells History what was typed.
- New Tab opens no tab until you go somewhere, so there are no blank tabs.

### Tab grid

- Two columns of cards, in the order of the tabs: each a picture of the page, its favicon and title underneath (a tab never shown since launch: its icon and host instead), and an ✕ in its corner. Swiping a card sideways closes it. Long press: Persist, Close Tab. Cards fade out under the clock. Opening the grid scrolls it to the selected card.
- Closing a Persist tab yourself asks first: "Close “<title>”? Its cookies and site data will be deleted." A page closing one doesn't ask.
- Along the bottom: Settings (…) and an address bar that opens a new tab. Closing the last tab leaves the empty grid ("No Tabs").
- Settings is a sheet with the Mac's settings: the search engine (a URL template field, with Google, DuckDuckGo, Brave, Startpage and Kagi to pick), appearance, where new tabs open, the new tab page (a picture from Photos or the default, a colour, or blank), the cookie whitelist, the filter lists (Update Now, Defaults), and links to History and Downloads. Removing a whitelisted domain asks, since its jar goes with it.

### Motion

The point is Safari's smoothness: nothing stutters, nothing flashes, nothing pops.

- One spring for every move: quick and settled, with very little bounce (about 0.34 s), always carrying the finger's speed when a finger lets go. Every move can be grabbed and turned around midway.
- Moves run in Core Animation, off the main thread, so a page loading never stutters them. SwiftUI and UIKit keep step through `context.animate` in a representable, or `UIView.animate` with a SwiftUI `Animation`.
- Opening the grid, the page shrinks into its card: scaled to the card's width, cut to its height, its corners going from the screen's own to the card's (22 pt). Coming back, it grows out of the card. The grid fades up behind it, and the bar sinks and fades. With no card to land on, the page shrinks towards the middle and fades.
- At every handover between the live page and a picture, both look identical.

### Facts that cost time to find out

- WebKit moves a page's scroll position when it sees its own view scaled. The live page is never scaled: a picture of it (`snapshotView(afterScreenUpdates: false)` is exact and costs nothing) does the shrinking. Sliding sideways is fine.
- WebKit keeps a page's place and drawing only while its view is in the window. Keep every shown tab's web view in the window, hidden when it isn't the selected one. A page shown again can take a moment to draw, so it shows its picture until then.
- A page that loaded while hidden starts at offset 0, under the clock, and WebKit can move it back to 0 just after it shows. Until a finger moves it, put its top back below the clock.
- `drawHierarchy` costs several milliseconds on the main thread. Take pictures for the grid, the stack and swipes when nothing moves (a page coming to rest, finishing loading, or coming on screen), never as a move starts. Keep them in memory only: each tab's current page, and the last few others of its back and forward list.
- Every navigation replaces the web view (the wipe). `Tab.view` (BrowserKit's `PageView`) already keeps the old page up until the next one draws; show `tab.view`, not `tab.webView`. Each new web view arrives through `tab(_:didReplace:)` before it loads: give it its insets, pull to reload and find then.
- A view controller's view hosted inside SwiftUI without being a child view controller gets no margins and no safe area. A bottom search field ignores safe area padding.

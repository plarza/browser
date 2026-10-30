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

- `iOS/` runs on the system's WebKit, the one browser engine iOS allows outside the EU and Japan. BrowserKit is shared; every Tabs, Whitelist, Network, Permissions, Address and History rule above holds.
- **Engine.** The same system WebKit configuration as the Mac: normal JIT and WebRTC behavior, UTC, en-US requested by the app, and baseline, fingerprinting and link-decoration protections enabled on every navigation.
- **Bar.** Along the bottom, in Liquid Glass: Arc's stack of tabs (the tab to the left of the one showing at the back, the one showing in front; dealt along with a swipe between tabs; opens the grid), the address bar (the site's name), and New Tab. Scrolling down the page shrinks it to the site's name. Long press on the address bar: Persist, Reload, Copy Link, Find on Page, Share. Dragging it sideways pulls the next or previous tab in beside the page, the address changing as the swipe passes halfway; dragging it up shrinks the page into the grid under the finger, and letting go finishes or springs back at the finger's speed. A Persist tab's address bar has a blue ring.
- **Back and forward** are swipes from the screen's left and right edges, as in Safari: the page follows the finger, the page before (or after) as a picture beside it, and stays as that picture until the real one draws. Pull down to reload. There are no buttons for them. Pictures are taken while nothing moves (a page coming to rest, finishing loading, or coming on screen) and kept in memory only: each tab's current page, and the last twelve others.
- **Address sheet.** Tapping the address bar or New Tab brings up a glass sheet with the page as a card above it: the field (the address selected, to type over), then pages from History, then the typed words as a search. Nothing is fetched while typing. Pulling the sheet down, or tapping the card, puts it away. New Tab opens no tab until you go somewhere, so there are no blank tabs.
- **Tab grid.** Two columns of cards, titles underneath, ✕ on each, a swipe sideways closes; a Persist tab's card has a blue ring. The page shrinks into its card on the way in and grows out of it on the way back. Along the bottom: Settings (…) and an address bar that opens a new tab. Tabs are never synced.
- **Motion.** Every move (the grid, the sheet, swipes between tabs and pages) is one spring that carries the finger's speed, run by Core Animation off the main thread, so a page loading never stutters it. The live page is never scaled; a picture of it does the shrinking.
- about://history's search field sits at the top, clear of the bar.
- **Extensions.** iOS keeps other apps' Safari extensions out of reach, so none are found.
- **Downloads** go to Browser's folder in the Files app.

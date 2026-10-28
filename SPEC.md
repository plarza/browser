# Core

Core is a macOS browser that gives you the privacy and anonymity of Mullvad Browser on a WebKit base. The name says what it is for: a core that other browsers can build on later. The UI is kept deliberately plain, just enough to use it as a browser.

## Shape

```
engine/      patched WebKit: pinned upstream commit + our patch series
CoreKit/     Swift framework: tabs, sessions, wipe, blocking, bangs, policy.
             Every rule below lives here or in the engine. Its API has no
             switches that weaken them.
App/         thin AppKit shell: window, vertical tabs, address field, settings
release/     build, sign, notarize, publish to Forgejo, update feed
```

- Apple Silicon only, on the current macOS.
- The app ships its own `WebKit.framework` and its own `JavaScriptCore.framework`. It never loads the system copies.

## Tabs

- Tabs run down the left, in a vertical list, in a pure white sidebar, flush with the page and with no dividing line, whose edge drags (200–420 pt). The page fills the rest of the window. There are no pinned tabs, no back/forward buttons and no New Tab button: ⌘T, ⌘[ and ⌘] do those, and a two-finger swipe goes back or forward.
- Each tab is a separate identity, with its own web process and its own network session. The session holds the tab's cookies, localStorage, sessionStorage, IndexedDB, Cache API, service workers, HTTP cache, HSTS, TLS session cache, connection pool, DNS cache and its fingerprint seed.
- **Wipe.** Every reload and every top-level navigation throws the whole session away and starts the next load in a brand-new one. That includes typed URLs, clicked links, back and forward, and redirects initiated by the page. Logins do not survive a reload.
- **Persist** (⌘I, or right-click › Persist Tab). The tab keeps its session through reloads and navigation. The tab turns a soft sky blue while it is on. Persist belongs to the tab, not the site. Turning it on moves the tab into a jar of its own on disk, taking its cookies and the current page's storage with it, so the tab and its session survive quitting Core. Closing the tab, or turning Persist off, deletes that jar; jars nothing refers to are deleted at launch.
- **Popups.** A `window.open` popup, such as an OAuth or 3-D Secure window, shares its opener's session and dies with it. Links opened in a new tab (⌘-click, middle-click) start fresh.
- **Closing a tab** destroys its session. Quitting the app destroys every session.

## Whitelist

- Settings holds a list of domains, meant for your self-hosted sites. A whitelisted domain and its subdomains get one jar on disk (encrypted at rest by FileVault), shared by every tab, that survives refresh, close and quit. The jar holds both cookies and site storage.
- Each whitelisted domain has one fixed fingerprint seed.

## Fingerprinting

Core has one user, so there is no crowd of Core users to hide in. It hides in the biggest crowd available instead: **stock Safari on the same macOS version**, with Safari's Private Browsing fingerprinting protections switched on permanently in the engine. Nothing is injected into pages and no prototype is patched, so CreepJS finds no "lies" to report. Whatever varies is derived from the identity's **seed**, so it changes on every wipe.

- **Seeds.** A wiped tab gets a fresh seed. A Persist tab keeps its seed until it is closed, across relaunches. A whitelisted domain keeps its own fixed seed. Each site's noise salt is derived from the seed and the site, so two sites in one identity can't match their readings either.
- **Protections that are always on:** WebKit's baseline protections, fingerprinting protections (canvas, audio and screen), enhanced network privacy, link-decoration filtering, script-tracking privacy, and `hardwareConcurrency` reported as 8.
- **User agent:** exactly Safari's for this macOS version.
- **Language and time zone:** `en-US` everywhere, set in every child process, so `navigator.language(s)`, `Accept-Language` and `Intl` all agree. The time zone is UTC.
- **Screen.** `screen.*` reports the window's own size, as Safari Private Browsing does. The page's viewport sizes are the real ones: rounding them would disagree with CSS media queries, and that disagreement is exactly the kind of lie CreepJS looks for. The window stays freely resizable; there is no letterboxing.
- **Fonts.** Fonts you installed yourself are invisible to pages; only macOS's own fonts can be seen.
- **JavaScript engine.** No JIT and no WebAssembly. That shuts out a large class of exploits and removes two timing surfaces.
- **WebRTC.** WebRTC stays on, but ICE uses TURN relay only. Host and srflx candidates are never gathered, so neither the LAN IP nor the public IP leaks around the VPN.
- **Media devices.** WebKit's default applies: no labels and no IDs until permission is granted.

## Network

- No proxy or Tor is built in. The user brings their own VPN.
- **HTTPS-only.** Every load is upgraded to HTTPS. If the upgrade fails, an interstitial offers to continue over HTTP for that one load in that tab.
- **Third-party cookies** are never allowed. Referer is trimmed to the origin when the request crosses sites.
- **Tracking parameters** (`utm_*`, `fbclid`, `gclid`, `mc_eid` and similar) are stripped from every navigation.
- **Content blocking** happens in the engine, through WebKit content rule lists compiled from filter lists (split into lists of at most 150,000 rules, WebKit's limit). The defaults are uBO filters, EasyList, EasyPrivacy, Peter Lowe's list, URLhaus and AdGuard Cookie Notices. The lists are fetched once a day, and their URLs can be edited in Settings. Element-hiding (cosmetic) rules are applied too.

## JavaScript

- JavaScript is on everywhere. **JIT is off** (JSC runs on its interpreters only) and **WebAssembly is off**. Neither has a setting.

## Permissions

- Location, notifications, MIDI, USB, serial, HID, Bluetooth, sensors, clipboard reads and persistent storage are always denied.
- Camera and microphone ask every time, and the answer is never remembered.

## Address field and search

- One field takes both URLs and search terms. Core has **no default search engine**: until you set one in Settings, plain words show "Set a search engine in Settings".
- **Bangs** (`!g`, `!w`, `!gh` and so on) come from Core's own table, compiled into the app and matched locally. Nothing is fetched for them. A bang works whether or not a search engine is set.

## Remembered on disk

- **History:** each page's address, title and visit count, most recent first, with no visit times, icons or page contents. It feeds the address field (inline completion of a visited site's name, and a ranked list of matching pages underneath) and **about://history** (⌘H): a page of its own, opened in a new tab, that searches every word across addresses and titles, removes entries one at a time, or clears everything. Like about://settings and about://help, it is a native view in the tab, not a web page.
- **Open tabs:** URLs, and for a Persist tab the id of its jar and its seed. They come back on the next launch: a Persist tab in its jar, every other tab in a fresh session.
- **Whitelist jars**, as described under Whitelist.
- **Extension data.** Extensions' own storage, such as the Bitwarden vault, is kept.
- Settings.
- **Favicons** are read from the page's own `<link rel=icon>` through WebKit's isolated client world (invisible to the page) and fetched with no cookies. An icon is kept on disk, under a hashed name, only for a site already in History or on the whitelist, so it records nothing those don't. Removing a site from History removes its icon; clearing History clears them all. A kept icon is never fetched again.
- Nothing else is written: no cache and no downloads list.

## Extensions

- Extensions run on WebKit's WKWebExtension engine and install from the Chrome Web Store. Bitwarden is the expected password manager. Core has no built-in password store.
- Extension content scripts can change pages in ways that are visible, so installing an extension is a fingerprinting trade-off the user chooses to make.

## Mouse and trackpad

- The mouse's back and forward buttons, and two-finger swipes, go through Core's own back and forward lists, the same as ⌘[ and ⌘].

## Downloads

- Every download asks first, showing the file name and size. Files go to `~/Downloads` and keep their quarantine flag. No download history is kept.

## Settings (the whole list)

Settings is a page, **about://settings** (⌘,), with: where new tabs open (below the current tab, at the top, or at the bottom); what a blank tab shows (a picture, the default or one chosen in Finder; a colour; or blank, the desktop frosted through the window), and whether that fills the whole window behind a frosted sidebar;

1. Search engine (URL template)
2. Cookie whitelist (domains)
3. Filter list URLs
4. Extensions

## Keyboard

Listed at about://help (⇧⌘/), read from the menus.

## Builds and updates

- **Source.** The repository lives on `git.aza.network` (Forgejo). A `forgejo-runner` in host mode runs on this Mac with the label `macos-arm64`.
- **Releases.** Pushing a tag builds the engine and the app, signs them with the Developer ID, notarizes them, and uploads the DMG to Forgejo Releases.
- **Updates** are manual: install the new DMG from the release. Core never checks for updates itself.
- **Telemetry.** None. The only request Core makes on its own is the daily filter-list fetch.

## Known gaps

Things CreepJS still sees, measured on 2026-10-28 by loading it, wiping, and loading it again:

- **WebGL pixels and images** come out with the same hash in every identity, so they can link sessions across wipes. To do: patch the engine to add per-seed noise to WebGL `readPixels` and canvas readback of WebGL contexts, the same way canvas 2D and audio already get it.
- **Fonts, speech voices and media device kinds** (microphone, webcam) are the same in every identity. They match what Safari shows on most Macs, so they are left alone for now.

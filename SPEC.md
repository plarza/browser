# Core

Core is a macOS browser that gives you the privacy and anonymity of Mullvad Browser on a WebKit base. Its shell borrows from [Search](https://github.com/driceroland/Search), which is MIT-licensed. The name says what it is for: a core that other browsers can build on later. The UI is kept deliberately plain, just enough to use it as a browser.

Core is fool-proof. None of its protections can be turned off: there is no setting for it, the CoreKit API has no switch for it, and there is no debug flag.

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

- Tabs run down the left, in a vertical list. There are no pinned tabs.
- Each tab is a separate identity, with its own web process and its own network session. The session holds the tab's cookies, localStorage, sessionStorage, IndexedDB, Cache API, service workers, HTTP cache, HSTS, TLS session cache, connection pool, DNS cache and its fingerprint seed.
- **Wipe.** Every reload and every top-level navigation throws the whole session away and starts the next load in a brand-new one. That includes typed URLs, clicked links, back and forward, and redirects initiated by the page. Logins do not survive a reload.
- **Persist** (⌘I, or right-click › Persist Tab). The tab keeps its session through reloads and navigation. A subtle blue glow behind the tab shows it is on. Persist belongs to the tab, not the site, and closing the tab still destroys everything.
- **Popups.** A `window.open` popup, such as an OAuth or 3-D Secure window, shares its opener's session and dies with it. Links opened in a new tab (⌘-click, middle-click) start fresh.
- **Closing a tab** destroys its session. Quitting the app destroys every session.

## Whitelist

- Settings holds a list of domains, meant for your self-hosted sites. A whitelisted domain and its subdomains get one encrypted jar on disk, shared by every tab, that survives refresh, close and quit. The jar holds both cookies and site storage.
- Each whitelisted domain has one fixed fingerprint seed.

## Fingerprinting

Core has one user, so there is no crowd of Core users to hide in. It hides in the biggest crowd available instead: **stock Safari on the same macOS version**. The values below are fixed, or bucketed into coarse ranges, to match what that crowd shows. The values that identify a device most are **re-rolled for every new session** from a seed, inside the engine. Because no JS is injected and no prototypes are patched, CreepJS finds no "lies" to report.

- **Seeds.** A wiped tab gets a fresh seed. A Persist tab keeps its seed until it is closed. A whitelisted domain keeps its own fixed seed.
- **User agent and client hints:** exactly Safari's for this macOS version.
- **Language:** `en-US` everywhere: `navigator.language(s)`, `Accept-Language` and `Intl`. Timezone is UTC.
- **Screen.** `screen.*` reports a common Mac display size. `window.inner*` and `outer*` are rounded down into 100-px buckets, and `devicePixelRatio` is 2. The window itself stays freely resizable; there is no letterboxing.
- **Hardware.** `hardwareConcurrency` is fixed at 8 and `deviceMemory` is absent, as in Safari. Battery, gamepad, sensors, MIDI, USB, serial, HID and Bluetooth are all absent.
- **Canvas, WebGL and audio.** Canvas 2D, WebGL `readPixels`, `OfflineAudioContext` and AnalyserNode output get deterministic per-seed noise, added in the engine at the readback points. WebGL vendor and renderer report `Apple Inc.` / `Apple GPU`, and the parameters and extensions match the common Apple Silicon set.
- **Fonts.** Only a bundled allow-list of system fonts can be seen. Local font enumeration is absent.
- **Timers.** `performance.now()` and event timestamps are clamped to 1 ms with jitter. SharedArrayBuffer is off without COOP/COEP, as in Safari.
- **Media.** `enumerateDevices` returns generic labels and no device IDs until permission is granted. Speech-synthesis voices are limited to a fixed list.
- **WebRTC.** WebRTC is on, but ICE uses TURN relay only. Host and srflx candidates are never gathered, so neither the LAN IP nor the public IP leaks around the VPN.

## Network

- No proxy or Tor is built in. The user brings their own VPN.
- **HTTPS-only.** Every load is upgraded to HTTPS. If the upgrade fails, an interstitial offers to continue over HTTP for that one load in that tab.
- **Third-party cookies** are never allowed. Referer is trimmed to the origin when the request crosses sites.
- **Tracking parameters** (`utm_*`, `fbclid`, `gclid`, `mc_eid` and similar) are stripped from every navigation.
- **Content blocking** happens in the engine, through WebKit content rule lists compiled from filter lists. The defaults are uBO filters, EasyList, EasyPrivacy, Peter Lowe's list, URLhaus and AdGuard Cookie Notices. The lists are fetched once a day, and their URLs can be edited in Settings. Element-hiding (cosmetic) rules are applied too.

## JavaScript

- JavaScript is on everywhere. **JIT is off** (JSC runs on the interpreter only) and **WebAssembly is off**. Neither has a setting.

## Permissions

- Location, notifications, MIDI, USB, serial, HID, Bluetooth, sensors, clipboard reads and persistent storage are always denied.
- Camera and microphone ask every time, and the answer is never remembered.

## Address field and search

- One field takes both URLs and search terms. Core has **no default search engine**: until you set one in Settings, plain words show "Set a search engine in Settings".
- **Bangs** (`!g`, `!w`, `!gh` and so on) come from Core's own table, compiled into the app and matched locally. Nothing is fetched for them. A bang works whether or not a search engine is set.
- Autocomplete draws from history.

## Remembered on disk

- **History:** URLs only, with no titles, times or favicons. It feeds autocomplete.
- **Open tabs:** URLs only. They come back on the next launch, each in a fresh session.
- **Whitelist jars**, as described under Whitelist.
- **Extension data.** Extensions' own storage, such as the Bitwarden vault, is kept.
- Settings.
- Nothing else is written: no cache, no favicons and no downloads list.

## Extensions

- Extensions work the way they do in Search: WebKit's WKWebExtension engine, Chrome Web Store install, and Search's fill-ins for the Chrome APIs WebKit lacks. Bitwarden is the expected password manager. Core has no built-in password store.
- Extension content scripts can change pages in ways that are visible, so installing an extension is a fingerprinting trade-off the user chooses to make.

## Downloads

- Every download asks first, showing the file name and size. Files go to `~/Downloads` and keep their quarantine flag. No download history is kept.

## Settings (the whole list)

1. Search engine (URL template)
2. Cookie whitelist (domains)
3. Filter list URLs
4. Extensions

## Keyboard

The same as Search, wherever the feature exists in Core, plus ⌘I for Persist.

## Builds and updates

- **Source.** The repository lives on `git.aza.network` (Forgejo). A `forgejo-runner` in host mode runs on this Mac with the label `macos-arm64`.
- **Releases.** Pushing a tag builds the engine and the app, signs them with the Developer ID, notarizes them, and uploads the DMG to Forgejo Releases.
- **Updates.** The app checks Forgejo releases once a day, through the system network (your VPN). It checks the Developer ID signature and team, then swaps the new build in on the next launch.
- **Telemetry.** None. The only requests Core makes on its own are the daily update check and the daily filter-list fetch.

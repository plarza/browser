# Core

Core is a private web browser for macOS. It runs on its own patched build of WebKit, the engine Safari uses. Every tab is its own identity, and that identity is thrown away on every load. Core is meant to be a base other browsers can build on, so its interface is deliberately small.

[SPEC.md](SPEC.md) is the full list of what Core does and why. In short:

- **Wiped on every load.** Each reload or navigation starts the tab over in a fresh identity: cookies, every kind of storage, the HTTP cache, connections and the fingerprint seed. **Persist** (⌘I) keeps a tab's identity until you close it. Domains on your whitelist keep their cookies on disk.
- **Hard to fingerprint.** Core looks like Safari on the same macOS. Safari's Private Browsing fingerprinting protections are always on inside the engine, with noise seeded per identity. Pages run in UTC and en-US. WebRTC uses relays only, so your IP never leaks around your VPN. There is no JIT and no WebAssembly.
- **Blocks ads and trackers itself.** Filter lists (uBlock Origin's, EasyList, EasyPrivacy and others) are fetched daily and compiled into WebKit's own content blocker. Core also strips tracking parameters from links and enforces HTTPS-only.
- **No switches.** None of the above can be turned off. Settings has exactly four things: search engine, cookie whitelist, filter lists, extensions.
- **Extensions** install from the Chrome Web Store on WebKit's extension engine, for example Bitwarden for passwords.
- **Bangs** like `!w`, `!gh` and `!yt` resolve locally from Core's own table, and history is searchable at `about://history` (⌘Y).

Core doesn't route your traffic: use your own VPN.

## Using it

| | |
|---|---|
| ⌘T new tab · ⌘W close · ⇧⌘T reopen | ⌘L address · ⌘S show or hide the sidebar |
| ⌘I Persist this tab | ⌘Y history · ⇧⌘S save page |
| ⌘[ ⌘] back, forward · ⌘R reload (a wipe) | ⇧⌘[ ⇧⌘] previous, next tab · ⌘1–⌘9 jump |
| ⌘F find · ⌘, settings | Drag the sidebar's edge to resize it |

## Building

You need Apple Silicon, macOS 26, Xcode 27 and about 60 GB of free disk.

```bash
engine/build.sh
```

This fetches WebKit at the commit in `engine/WEBKIT_COMMIT` into `~/repos/core-engine/webkit`, applies `engine/patches/`, and builds it. The first build takes about an hour; later ones are incremental. `engine/build.sh rebase` moves to WebKit's latest commit.

```bash
./build.sh
```

This builds `build/Core.app` with the engine inside it. Without an engine build, the app runs on the system WebKit and its sidebar says that protection is off. `./build.sh debug` makes a debug build.

```bash
./build.sh release ship
```

This signs the app with your Developer ID, notarizes it, and writes `build/release/Core-<version>.dmg`. It needs a Developer ID Application certificate in the keychain and notary credentials stored once:

```bash
xcrun notarytool store-credentials core
```

Pushing a tag such as `v0.2.0` does all of this on the Forgejo runner (`.forgejo/workflows/release.yml`). `release/runner.sh <token>` sets this Mac up as that runner. Updates are manual: install the new DMG.

### Testing

Debug builds can drive themselves with real key and mouse events:

```bash
build/Core.app/Contents/MacOS/Core -coreStore /tmp/core-test -coreSelfTest YES
```

Each check logs a `PASS` or `FAIL` line. `-coreStore` keeps the test away from your real tabs and history. `-coreProbe <url> -coreProbeOut <file>` writes a page's text before and after a wipe; that's how CreepJS is checked.

## Layout

```
engine/   WebKit commit, patch series, build/embed scripts, dyld launcher
CoreKit/  every privacy rule: identities, tabs, blocker, bangs, history, extensions
App/      the window, sidebar, address field, settings, debug self-test
release/  Info.plist, entitlements, notarization, runner setup
```

Core borrows from [Search](https://github.com/driceroland/Search) by Office Commun (MIT): the Chrome Web Store installer, link cleaning, and the starter block list.

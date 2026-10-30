<div align="center">
    <img src="release/icon.png"
        title="Browser" alt="Browser logo" width="120" />
    <h1>Aza Browser</h1>
    <p>
        A private and opinionated macOS browser
    </p>
</div>

![Browser](release/screenshot.webp)

## WebKit

Browser uses the system WebKit on macOS and iOS, with normal JavaScript and WebAssembly JIT compilation and WebRTC behavior. WebKit is updated with the operating system.

- WebKit's baseline, fingerprinting and link-decoration protections are enabled for every navigation through its private API.
- Fingerprint noise is managed by WebKit.
- Web processes use UTC, and the app requests en-US.
- Browser does not request iCloud Private Relay; traffic uses the system network configuration, including your VPN.

## Browser

- Each tab gets its own data store and network session (cookies, all storage, HTTP cache, HSTS, TLS sessions, connections) and its own web process.
- Every reload and navigation, back and forward included, throws that identity away and loads into a new one.
- Persist (⌘I) keeps a tab's identity until the tab closes, across relaunches.
- Domains on the cookie whitelist keep one jar on disk, shared by all tabs.
- `window.open` popups (sign-in, 3-D Secure) share their opener's identity and close with it; links opened in a new tab start fresh.
- The user agent is Safari's for the installed macOS.
- HTTPS-only: plain HTTP is upgraded, with a one-load fallback page if the site has no HTTPS. Loopback (`localhost`) is left alone.
- Tracking parameters (`utm_*`, `fbclid`, `gclid` and others) are removed from every navigation.
- Ads and trackers are blocked inside WebKit's networking by content rules compiled from filter lists (uBlock Origin's, EasyList, EasyPrivacy, Peter Lowe's, URLhaus, AdGuard cookie notices), fetched daily without cookies.
- Location, notifications, MIDI, USB, serial, HID, Bluetooth and sensors are always denied; camera and microphone ask every time and the answer isn't kept.
- Downloads open the save panel and keep macOS's quarantine flag; about://downloads lists them.
- Bangs (`!w`, `!gh`, `!yt` and about 300 more) resolve from a table inside the app.
- Favicons are read from the page through WebKit's isolated script world, fetched without cookies, and kept on disk only for sites in History.
- History keeps addresses, titles, visit counts, last-visit times and frecency in SQLite, plus which suggestion you picked for what you typed, for address-bar completion and `about://history`.
- Safari web extensions from apps in Applications turn on in Settings and run on WebKit's extension engine; their own storage is kept.
- No telemetry and no update checks. The only request Browser makes by itself is the daily filter-list fetch.
- No proxy or Tor: use a VPN. Browser does not enable WebKit's iCloud Private Relay policy.

Keyboard shortcuts are at `about://help` (⇧⌘/).

## Build

Requires Apple Silicon, macOS 26 and Xcode 27.

```bash
./build.sh               # release build into build/Browser.app
./build.sh debug         # debug build
./build.sh release ship  # Developer ID sign + notarize -> build/release/Browser-<version>.dmg
```

`ship` needs a Developer ID Application certificate and one-time notary setup:

```bash
xcrun notarytool store-credentials browser
```

Pushing a `v*` tag runs the same build on the Forgejo runner (`.forgejo/workflows/release.yml`). `release/runner.sh <token>` registers this Mac as that runner. Updates are manual.

## Test

The UI self-test only works in debug builds:

```bash
build/Browser.app/Contents/MacOS/Browser -browserStore /tmp/browser-test -browserSelfTest YES
```

It logs PASS/FAIL per check, ends with a count and quits, exiting non-zero if any check failed. Every page it loads comes from a web server inside the test, on this Mac, so it needs no internet; each step waits for what it expects rather than a set time, and works with Browser in the background. `-browserStore` uses a separate data folder; `-browserShots <folder>` has the app draw its own window into PNGs at each step (nothing is captured from the screen). `-browserProbe <url> -browserProbeOut <file>` writes a page's text before and after a wipe; it's used for CreepJS.

## Screenshot

`release/screenshot.sh` redraws `release/screenshot.webp` (quality 80) from a debug build: the tabs listed in the script load from the internet into a throwaway data folder, and the new tab page is in front. The settings at the top of the script choose the tabs, the Persist tab, light or dark, and Fill.

## iPhone

`iOS/` is Browser for iPhone. It shares BrowserKit and the same system WebKit configuration with the Mac app. Safari extensions cannot be loaded from other apps, and downloads go to Browser's folder in Files.

```bash
iOS/build.sh          # simulator build into build/ios
iOS/build.sh device   # signed for, and installed on, a connected iPhone
```

It's installed from Xcode with a developer account, never the App Store: it uses WebKit's private API.

## Licence

MIT, in `LICENSE`.

## Layout

| Folder | Contents |
|---|---|
| `BrowserKit/` | Tabs, identities, blocker, bangs, history, extensions |
| `App/` | Window, sidebar, settings |
| `Tests/` | End-to-end app self-test |
| `release/` | Info.plist, entitlements, icon, notarization, runner setup |

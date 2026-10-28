# Core

A private browser for macOS on a patched WebKit. Details in [SPEC.md](SPEC.md).

- Each tab has its own cookies, storage, cache and fingerprint seed, wiped on every reload and navigation.
- ⌘I (Persist) keeps a tab's session until the tab closes.
- Whitelisted domains keep their cookies on disk.
- Fingerprinting protections are always on. Pages see Safari's user agent, UTC and en-US.
- WebRTC is relay-only. No JIT, no WebAssembly.
- Built-in ad and tracker blocking from filter lists, updated daily.
- HTTPS-only. Tracking parameters are stripped from links.
- Bangs (`!w`, `!gh`, …) resolve locally. History search is at `about://history`.
- Chrome Web Store extensions run on WebKit's extension engine.
- No settings turn any of this off. No proxy or Tor: use a VPN.

## Shortcuts

| Key | Action |
|---|---|
| ⌘T / ⌘W / ⇧⌘T | New tab / close / reopen closed |
| ⌘L | Address field |
| ⌘I | Persist tab |
| ⌘S | Toggle sidebar |
| ⇧⌘S | Save page |
| ⌘Y | History |
| ⌘R | Reload (wipes the tab) |
| ⌘[ / ⌘] | Back / forward |
| ⇧⌘[ / ⇧⌘] | Previous / next tab |
| ⌘1–⌘9 | Jump to tab |
| ⌘F | Find |
| ⌘, | Settings (`about://settings`) |
| Two-finger swipe | Back / forward |

## Build

Requires Apple Silicon, macOS 26, Xcode 27 and about 60 GB of disk.

```bash
engine/build.sh          # WebKit at engine/WEBKIT_COMMIT + engine/patches, ~1 h first time
./build.sh               # build/Core.app with the engine embedded
./build.sh debug         # debug build
./build.sh release ship  # Developer ID sign + notarize -> build/release/Core-<version>.dmg
```

`engine/build.sh rebase` moves to the latest WebKit commit.

`ship` needs a Developer ID Application certificate and one-time notary setup:

```bash
xcrun notarytool store-credentials core
```

Pushing a `v*` tag runs the same build on the Forgejo runner (`.forgejo/workflows/release.yml`). `release/runner.sh <token>` registers this Mac as that runner. Updates are manual.

## Test

The self-test only works in debug builds:

```bash
build/Core.app/Contents/MacOS/Core -coreStore /tmp/core-test -coreSelfTest YES
```

It logs PASS/FAIL per check. `-coreStore` uses a separate data folder. `-coreProbe <url> -coreProbeOut <file>` writes a page's text before and after a wipe; it's used for CreepJS.

## Layout

| Folder | Contents |
|---|---|
| `engine/` | WebKit commit, patches, build/embed scripts, launcher |
| `CoreKit/` | Tabs, identities, blocker, bangs, history, extensions |
| `App/` | Window, sidebar, settings, self-test |
| `release/` | Info.plist, entitlements, icon, notarization, runner setup |

Parts are from [Search](https://github.com/driceroland/Search) (MIT): the CRX installer, link cleaning, and the starter block list.

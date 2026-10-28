import Foundation
import WebKit

/// What CoreKit asks of the WebKit it runs on. The patched engine
/// (engine/) adds `_coreFingerprintSeed` to the webpage preferences and does the
/// rest of the fingerprinting work itself: the screen, the clocks, the
/// fonts, canvas, WebGL, audio, JIT and WebAssembly off, UTC and en-US.
@MainActor
public enum Engine {
    /// Whether this process loaded Core's own WebKit rather than the
    /// system's. A release build refuses to start without it.
    public static let isPatched: Bool = {
        WKWebpagePreferences.instancesRespond(to: NSSelectorFromString("_setCoreFingerprintSeed:"))
    }()

    /// Safari's own, for the macOS this runs on: the largest crowd a WebKit
    /// browser can stand in.
    public static let applicationName: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let info = NSDictionary(contentsOf: plist)
        let full = info?["CFBundleShortVersionString"] as? String ?? "26.0"
        let parts = full.split(separator: ".")
        let version = parts.count >= 2 ? "\(parts[0]).\(parts[1])" : "\(full).0"
        return "Version/\(version) Safari/605.1.15"
    }()

    /// A configuration for a page in `identity`. Everything a page can
    /// switch on through preferences is decided here, once.
    static func configuration(for identity: Identity, content: WKUserContentController) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = identity.store
        config.userContentController = content
        StoreRelay.install(in: content)
        config.webExtensionController = Extensions.shared.controller
        config.applicationNameForUserAgent = applicationName
        config.limitsNavigationsToAppBoundDomains = false
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.isFraudulentWebsiteWarningEnabled = false // asks Google; the blocker covers malware lists
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.isSiteSpecificQuirksModeEnabled = true // Safari has them on; off would stand out
        config.preferences.isTextInteractionEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsAirPlayForMediaPlayback = false
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Web Inspector (⇧⌘I) for the person at the keyboard; nothing a page can see.
        let extras = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        if config.preferences.responds(to: extras) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(config.preferences.method(for: extras), to: Setter.self)(config.preferences, extras, true)
        }
        harden(config.defaultWebpagePreferences, seed: identity.seed)
        return config
    }

    /// Safari's Private Browsing protections: canvas, audio and screen
    /// noise, network privacy, link decoration filtering. The patched
    /// engine has them on whatever this says; on the system engine this is
    /// what turns them on.
    ///
    /// The seed goes with every navigation; the engine derives each site's
    /// canvas, audio and WebGL noise and its reported hardware from it.
    static func harden(_ preferences: WKWebpagePreferences, seed: UInt64) {
        let integrity = NSSelectorFromString("_setNetworkConnectionIntegrityEnabled:")
        if preferences.responds(to: integrity) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(preferences.method(for: integrity), to: Setter.self)(preferences, integrity, true)
        }
        let seeding = NSSelectorFromString("_setCoreFingerprintSeed:")
        if preferences.responds(to: seeding) {
            preferences.perform(seeding, with: NSNumber(value: seed))
        }
    }
}

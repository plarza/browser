import Darwin
import Foundation
import WebKit

/// What BrowserKit asks of the WebKit it runs on. The patched engine
/// (engine/) adds `_browserFingerprintSeed` to the webpage preferences and does the
/// rest of the fingerprinting work itself: the screen, the clocks, the
/// fonts, canvas, WebGL, audio, JIT and WebAssembly off, UTC and en-US.
@MainActor
public enum Engine {
    /// This applies to every build and to direct executable launches too.
    public static func requirePatched() {
        guard WKWebpagePreferences.instancesRespond(to: NSSelectorFromString("_setBrowserFingerprintSeed:")) else {
            fputs("Browser cannot start without its patched WebKit. Rebuild Browser with the engine embedded.\n", stderr)
            exit(EX_CONFIG)
        }
    }

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

    static var userAgent: String { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(applicationName)" }

    /// For Browser's own requests (filter lists, icons): no cookies, no
    /// cache, Safari's user agent, nothing that ties one request to the next.
    static func session(timeout: TimeInterval, headers: [String: String] = [:]) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = headers.merging(["User-Agent": userAgent]) { a, _ in a }
        return URLSession(configuration: config)
    }

    /// A configuration for a page in `identity`. Everything a page can
    /// switch on through preferences is decided here, once.
    static func configuration(for identity: Identity, content: WKUserContentController) -> WKWebViewConfiguration {
        requirePatched()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = identity.store
        config.userContentController = content
        Links.install(in: content)
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
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        harden(config.defaultWebpagePreferences, seed: identity.seed)
        return config
    }

    /// Safari's Private Browsing protections: canvas, audio and screen
    /// noise, network privacy and link decoration filtering are forced on
    /// in the engine. Every navigation also carries its identity's seed.
    ///
    /// The seed goes with every navigation; the engine derives each site's
    /// canvas, audio and WebGL noise and its reported hardware from it.
    static func harden(_ preferences: WKWebpagePreferences, seed: UInt64) {
        preferences.perform(NSSelectorFromString("_setBrowserFingerprintSeed:"), with: NSNumber(value: seed))
    }
}

import Darwin
import Foundation
import WebKit
#if os(iOS)
import UIKit
#endif

/// What BrowserKit asks of the WebKit it runs on. On the Mac, the patched
/// engine (engine/) adds `_browserFingerprintSeed` to the webpage preferences
/// and does the rest of the fingerprinting work itself: the screen, the
/// clocks, the fonts, canvas, WebGL, audio, JIT off, UTC and
/// en-US. iOS runs the system's WebKit: its own switches do what they can.
@MainActor
public enum Engine {
    #if os(macOS)
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
    #else
    public static func requirePatched() {}

    /// Safari's own, for the iOS this runs on.
    public static let applicationName: String = {
        let parts = UIDevice.current.systemVersion.split(separator: ".")
        let version = parts.count >= 2 ? "\(parts[0]).\(parts[1])" : "\(parts.first ?? "26").0"
        return "Version/\(version) Mobile/15E148 Safari/604.1"
    }()

    /// The whole string WebKit sends for the pages, read from WebKit itself.
    static let userAgent: String = {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = applicationName
        return WKWebView(frame: .zero, configuration: config).value(forKey: "_userAgent") as? String ?? ""
    }()

    /// Every web process: no JIT, so WebAssembly runs interpreted too, and UTC.
    static let processPool: WKProcessPool = {
        guard let type = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type else { return WKProcessPool() }
        let config = type.init()
        config.setValue(false, forKey: "JITEnabled")
        config.setValue("UTC", forKey: "timeZoneOverride")
        // One pool for the app's life: alloc and init by hand, its
        // reference never given back.
        let make = NSSelectorFromString("_initWithConfiguration:")
        guard let blank = (WKProcessPool.self as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              blank.responds(to: make) else { return WKProcessPool() }
        typealias Init = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<WKProcessPool>
        return unsafeBitCast(blank.method(for: make), to: Init.self)(blank, make, config).takeUnretainedValue()
    }()
    #endif

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
        #if os(iOS)
        config.processPool = processPool
        #endif
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
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        #if os(macOS)
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // Web Inspector (⇧⌘I) for the person at the keyboard; nothing a page can see.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #else
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.allowsInlineMediaPlayback = true
        config.dataDetectorTypes = []
        #endif
        harden(config.defaultWebpagePreferences, seed: identity.seed)
        return config
    }

    /// The identity's seed, sent with every navigation: the engine derives
    /// each site's canvas, audio and WebGL noise and its reported hardware
    /// from it.
    static func harden(_ preferences: WKWebpagePreferences, seed: UInt64) {
        #if os(macOS)
        preferences.perform(NSSelectorFromString("_setBrowserFingerprintSeed:"), with: NSNumber(value: seed))
        #else
        // No seed to give: Safari's Private Browsing protections (baseline,
        // fingerprinting, enhanced network privacy, link decoration), with
        // the system's own noise.
        let set = NSSelectorFromString("_setNetworkConnectionIntegrityEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Call.self)(preferences, set, true)
        #endif
    }
}

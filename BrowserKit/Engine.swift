import Foundation
import WebKit
#if os(iOS)
import UIKit
#endif

/// Browser's configuration of the system WebKit on macOS and iOS.
@MainActor
public enum Engine {
    #if os(macOS)
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
    #endif

    /// UTC in pages and workers; JavaScriptCore keeps its default JIT policy.
    static let processPool: WKProcessPool = {
        let type = NSClassFromString("_WKProcessPoolConfiguration") as! NSObject.Type
        let config = type.init()
        config.setValue("UTC", forKey: "timeZoneOverride")
        let pool = (WKProcessPool.self as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        let initialize = NSSelectorFromString("_initWithConfiguration:")
        typealias Initialize = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<WKProcessPool>
        return unsafeBitCast(pool.method(for: initialize), to: Initialize.self)(pool, initialize, config).takeRetainedValue()
    }()

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
        let config = WKWebViewConfiguration()
        config.websiteDataStore = identity.store
        config.processPool = processPool
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
        harden(config.defaultWebpagePreferences)
        return config
    }

    /// WebKit's baseline, fingerprinting and link-decoration protections.
    /// Enhanced network privacy (Private Relay) is left off.
    static func harden(_ preferences: WKWebpagePreferences) {
        let baseline: UInt = 1 << 0
        let fingerprinting: UInt = 1 << 6
        let linkDecoration: UInt = 1 << 8
        let set = NSSelectorFromString("_setNetworkConnectionIntegrityPolicy:")
        typealias Call = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(preferences.method(for: set), to: Call.self)(preferences, set, baseline | fingerprinting | linkDecoration)
    }
}

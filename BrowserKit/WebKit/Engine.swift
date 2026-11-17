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
        let full = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "26.0"
        let parts = full.split(separator: ".")
        let version = parts.count >= 2 ? "\(parts[0]).\(parts[1])" : "\(full).0"
        return "Version/\(version) Safari/605.1.15"
    }()

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(applicationName)"
    #else
    /// Safari's own, for the iOS this runs on.
    public static let applicationName: String = {
        let parts = UIDevice.current.systemVersion.split(separator: ".")
        let version = parts.count >= 2 ? "\(parts[0]).\(parts[1])" : "\(parts.first ?? "26").0"
        return "Version/\(version) Mobile/15E148 Safari/604.1"
    }()

    /// The whole string WebKit sends for the pages, read from WebKit itself.
    static let userAgent: String = {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = applicationName
        return WKWebView(frame: .zero, configuration: configuration).value(forKey: "_userAgent") as? String ?? ""
    }()
    #endif

    /// UTC in pages and workers; JavaScriptCore keeps its default JIT policy.
    /// A `WKProcessPool`, made through its private configuration (the only
    /// way to set a time zone) and so held as the object it is.
    static let processPool: NSObject = {
        let type = NSClassFromString("_WKProcessPoolConfiguration") as! NSObject.Type
        let configuration = type.init()
        configuration.setValue("UTC", forKey: "timeZoneOverride")
        // A web process started ahead of time, as Safari keeps one, so a load
        // into a new identity doesn't wait for one to launch.
        if configuration.responds(to: NSSelectorFromString("setPrewarmsProcessesAutomatically:")) {
            configuration.setValue(true, forKey: "prewarmsProcessesAutomatically")
        }
        let pool = (NSClassFromString("WKProcessPool")! as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        let initialize = NSSelectorFromString("_initWithConfiguration:")
        typealias Initialize = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<NSObject>
        return unsafeBitCast(pool.method(for: initialize), to: Initialize.self)(pool, initialize, configuration).takeRetainedValue()
    }()

    /// For Browser's own requests (filter lists, icons, userscript updates):
    /// no cookies, no cache, Safari's user agent, nothing that ties one
    /// request to the next.
    static func session(timeout: TimeInterval, headers: [String: String] = [:]) -> URLSession {
        URLSession(configuration: sessionConfiguration(timeout: timeout, headers: headers))
    }

    static func sessionConfiguration(timeout: TimeInterval, headers: [String: String] = [:]) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpAdditionalHeaders = headers.merging(["User-Agent": userAgent]) { given, _ in given }
        return configuration
    }

    /// A configuration for a page in `identity`. Everything a page can
    /// switch on through preferences is decided here, once.
    static func configuration(for identity: Identity) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = identity.store
        configuration.setValue(processPool, forKey: "processPool")
        configuration.userContentController = Blocker.shared.contentController()
        AuxiliaryClicks.install(in: configuration.userContentController)
        configuration.webExtensionController = Extensions.shared.controller
        configuration.applicationNameForUserAgent = applicationName
        configuration.limitsNavigationsToAppBoundDomains = false
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false // asks Google; the blocker covers malware lists
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isSiteSpecificQuirksModeEnabled = true // Safari has them on; off would stand out
        configuration.preferences.isTextInteractionEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        #if os(macOS)
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        // Web Inspector (⇧⌘I) for the person at the keyboard; nothing a page can see.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #else
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = []
        #endif
        harden(configuration.defaultWebpagePreferences)
        return configuration
    }

    /// WebKit's baseline, fingerprinting and link-decoration protections.
    /// Enhanced network privacy (Private Relay) is left off.
    static func harden(_ preferences: WKWebpagePreferences) {
        let baseline: UInt = 1 << 0
        let fingerprinting: UInt = 1 << 6
        let linkDecoration: UInt = 1 << 8
        let set = NSSelectorFromString("_setNetworkConnectionIntegrityPolicy:")
        typealias Set = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(preferences.method(for: set), to: Set.self)(preferences, set, baseline | fingerprinting | linkDecoration)
    }
}

extension WKUserContentController {
    /// Takes one script out, keeping the rest in order.
    func remove(_ script: WKUserScript) {
        let others = userScripts.filter { $0 !== script }
        guard others.count != userScripts.count else { return }
        removeAllUserScripts()
        others.forEach(addUserScript)
    }
}

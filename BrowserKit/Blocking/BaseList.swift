import Foundation

/// The small list built into Browser, in force from the first launch,
/// before any filter list has been fetched.
enum BaseList {
    /// Blocks each of `domains`, and its subdomains, as a third party.
    static var rules: [ContentRule] {
        domains.map { domain in
            .block(ContentRule.Trigger(urlFilter: ContentRule.Trigger.urlFilter(onHost: domain), loadType: [.thirdParty]))
        }
    }

    /// Third parties whose only job is to watch or to sell. Enough to be
    /// useful before the first fetch has finished.
    private static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
    ]
}

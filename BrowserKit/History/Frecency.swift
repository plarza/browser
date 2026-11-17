import Foundation

/// Frecency, as Firefox has it: every visit adds its weight to a page's
/// score, and the score halves every 30 days. What's kept is the day (since
/// 1970) the score falls to 1, `day + ln(score) / λ`, so pages sort by it
/// directly, with nothing to recalculate as time passes.
enum Frecency {
    static let λ = log(2.0) / 30
    /// A reload's or a redirect source's weight.
    static let low = 0.25
    /// Points in a page's rank in the address field's list per day of
    /// frecency: twice the score is 30 days, 15 points.
    static let points = 0.5

    /// Now, in days since 1970.
    static func today() -> Double { Date().timeIntervalSince1970 / 86400 }
}

extension History.Kind {
    /// What a visit of this kind adds to its page's score.
    var weight: Double {
        switch self {
        case .typed: 2
        case .link: 1
        case .reload: Frecency.low
        }
    }
}

/// How a pick's `uses` grows and fades, as Firefox does it: each pick adds
/// 1 to nine tenths of what was there, so it climbs towards 10 and stops;
/// unused, it loses 2.5% a day, and under a tenth (about 90 days) the pick
/// is forgotten.
enum Picks {
    static let most = 10.0
    static let carried = 0.9
    static let fade = 0.975
    static let forgotten = 0.1
}

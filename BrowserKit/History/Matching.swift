import Foundation

/// How History's text is made ready for matching. Beside each page's
/// address and title, history.db keeps lowercased copies to look through:
/// `bare` (the address without scheme or `www.`), `ltitle`, and `words`
/// (both with every non-letter, non-digit made a space, so the start of a
/// word is a space followed by it). `host` is the address's host and `site`
/// the same without `www.`, for completing site names.
enum Matching {
    /// What was typed, as the words to look for.
    static func words(in query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `text` with everything but letters and digits made a space.
    static func spaced(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber ? $0 : " " })
    }

    /// The `words` column for a page: every word of its address and title
    /// with a space before it.
    static func words(bare: String, title: String) -> String {
        " " + spaced(bare) + " " + spaced(title)
    }

    /// `word` as it stands at the start of a word in the `words` column.
    static func start(of word: String) -> String {
        " " + spaced(word).trimmingCharacters(in: .whitespaces)
    }

    static func site(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Just past every text that starts with `prefix`: with `prefix`
    /// itself, a range an index can be searched by.
    static func end(of prefix: String) -> String {
        prefix + "\u{10FFFF}"
    }
}

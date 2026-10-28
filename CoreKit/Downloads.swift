import Foundation
import WebKit

/// Every download asks first, then goes to ~/Downloads with the quarantine
/// flag macOS puts on it (LSFileQuarantineEnabled). No list of them is kept.
@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    private var owners: [ObjectIdentifier: Tab] = [:]

    func adopt(_ download: WKDownload, for tab: Tab) -> WKDownloadDelegate {
        owners[ObjectIdentifier(download)] = tab
        return self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let tab = owners[ObjectIdentifier(download)]
        let size = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        let name = Downloads.safeName(suggestedFilename)
        guard let tab, let delegate = tab.delegate, await delegate.tab(tab, allowDownload: name, size: size) else {
            owners[ObjectIdentifier(download)] = nil
            return nil
        }
        return Downloads.destination(for: name)
    }

    func downloadDidFinish(_ download: WKDownload) {
        owners[ObjectIdentifier(download)] = nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        owners[ObjectIdentifier(download)] = nil
    }

    static func safeName(_ suggested: String) -> String {
        let cleaned = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "download" : cleaned
    }

    /// `name`, or `name 2`, `name 3`… when it is taken.
    static func destination(for name: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

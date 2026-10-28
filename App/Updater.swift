import AppKit
import CryptoKit
import Security

/// Once a day: is there a newer Core? The feed (Info.plist `CoreUpdateFeed`)
/// is a small JSON file published with each release:
///
///     {"version": "0.2.0", "build": 42, "url": "https://…/Core.zip", "sha256": "…"}
///
/// A newer build is downloaded, checked against the hash and then against
/// Core's own Developer ID team, and swapped in when Core quits. Nothing
/// restarts on its own, and with no feed set nothing is ever asked.
@MainActor
final class Updater {
    static let shared = Updater()

    private var staged: URL?
    private let feed = (Bundle.main.object(forInfoDictionaryKey: "CoreUpdateFeed") as? String).flatMap(URL.init(string:))
    private let team = Bundle.main.object(forInfoDictionaryKey: "CoreTeamID") as? String

    private struct Release: Decodable {
        let version: String
        let build: Int
        let url: URL
        let sha256: String
    }

    func start() {
        guard feed != nil, team?.isEmpty == false else { return }
        check()
        Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in Updater.shared.check() }
        }
    }

    private func check() {
        let key = "core.update.checked"
        let last = UserDefaults.standard.double(forKey: key)
        guard staged == nil, let feed, Date().timeIntervalSince1970 - last > 24 * 60 * 60 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        Task {
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            guard let (data, _) = try? await session.data(from: feed),
                  let release = try? JSONDecoder().decode(Release.self, from: data),
                  release.build > (Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0),
                  let (file, _) = try? await session.download(from: release.url),
                  let zip = try? Data(contentsOf: file),
                  SHA256.hash(data: zip).map({ String(format: "%02x", $0) }).joined() == release.sha256.lowercased()
            else { return }
            staged = await Task.detached { [team] in Updater.unpack(file, team: team ?? "") }.value
        }
    }

    nonisolated static func unpack(_ zip: URL, team: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("core-update-\(UUID().uuidString)")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        guard (try? ditto.run()) != nil else { return nil }
        ditto.waitUntilExit()
        let app = folder.appendingPathComponent("Core.app")
        guard ditto.terminationStatus == 0, verify(app, team: team) else { return nil }
        return app
    }

    /// Signed by Developer ID, by Core's team, intact, every nested piece.
    nonisolated static func verify(_ app: URL, team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// At quit: the old app to the Trash, the new one in its place.
    func install() {
        guard let staged else { return }
        let current = Bundle.main.bundleURL
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
            try FileManager.default.moveItem(at: staged, to: current)
        } catch {
            NSLog("Core: update not installed: \(error.localizedDescription)")
        }
    }
}

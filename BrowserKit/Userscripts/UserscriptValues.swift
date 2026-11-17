import Foundation

/// What the scripts stored with GM_setValue: every script's values in
/// memory, each as JSON, and written to disk as they change.
@MainActor
final class UserscriptValues {
    private var stored: [String: [String: String]] = [:]
    private var pendingWrites: [String: Task<Void, Never>] = [:]
    /// Raised whenever a script's values change. A copy of a script starts
    /// with the values of the moment it was made, so a web view's copy is
    /// made again at its next load.
    private var revisions: [String: Int] = [:]

    func load(for scripts: [Userscript]) {
        for script in scripts {
            if let values = UserscriptStore.values(of: script.id) { stored[script.id] = values }
        }
    }

    func values(of id: String) -> [String: String] { stored[id] ?? [:] }
    func revision(of id: String) -> Int { revisions[id, default: 0] }

    /// One value set, or deleted with nil.
    func set(_ value: String?, for key: String, of id: String) {
        stored[id, default: [:]][key] = value
        revisions[id, default: 0] += 1
        writeSoon(id)
    }

    /// All of a script's values at once, from a backup: written now.
    func replace(_ values: [String: String], of id: String) {
        stored[id] = values
        revisions[id, default: 0] += 1
        write(id)
    }

    /// The script has gone, and what it stored with it.
    func remove(_ id: String) {
        pendingWrites.removeValue(forKey: id)?.cancel()
        stored[id] = nil
    }

    /// Values still waiting to be written, written now.
    func flush() {
        for id in Array(pendingWrites.keys) { write(id) }
    }

    /// Values are written a moment after they settle: a script that sets
    /// one on every scroll doesn't write on every scroll.
    private func writeSoon(_ id: String) {
        pendingWrites[id]?.cancel()
        pendingWrites[id] = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            write(id)
        }
    }

    private func write(_ id: String) {
        pendingWrites.removeValue(forKey: id)?.cancel()
        UserscriptStore.write(values(of: id), of: id)
    }
}

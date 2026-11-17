#if DEBUG
import AppKit

/// Debug builds only: what the launch options that drive the window share
/// (the self-test, `-browserScreenshot`, `-browserProbe`).
@MainActor
enum Tooling {
    /// Before anything starts. The self-test and the screenshot delete data
    /// stores, and WebKit keeps those per app, not per `-browserStore`: only
    /// a debug build's own app id keeps the real Browser's cookies out of
    /// reach. Then the self-test's own site, if it is to run.
    static func prepare() {
        guard OutOfTheWay.enabled || Screenshot.file != nil else { return }
        guard Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true else {
            NSLog("Browser tooling: refusing to run as \(Bundle.main.bundleIdentifier ?? "?"); build with ./build.sh debug")
            exit(EXIT_FAILURE)
        }
        SelfTest.prepare()
    }

    /// Waits until `condition` holds, checking every 10 ms, for at most
    /// `seconds`; after two seconds it says what it is waiting for.
    @discardableResult
    static func until(_ what: String, seconds: Double = 15, _ condition: () async -> Bool) async -> Bool {
        let start = ContinuousClock.now
        var said = false
        while !(await condition()) {
            let waited = ContinuousClock.now - start
            if seconds.isFinite, waited > .seconds(seconds) { return false }
            if !said, waited > .seconds(2) {
                NSLog("Browser tooling: waiting for \(what)")
                said = true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
#endif

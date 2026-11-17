import Observation
import WebKit

// STUB: the public surface the shells and the rest of BrowserKit rely on.
// The bodies are to be rebuilt; the signatures here are the contract.
@MainActor @Observable
public final class Blocker {
    public static let shared = Blocker()

    /// The last thing that went wrong fetching or compiling, for Settings.
    public private(set) var trouble: String?
    /// How many rules the lists compiled into.
    public private(set) var ruleCount = 0
    /// A fetch and compile is under way.
    public private(set) var isRefreshing = false
    /// When the lists were last fetched.
    public private(set) var lastFetched: Date?

    /// Loads the compiled lists and keeps them fresh: once at launch.
    public func start() {}
    /// Fetch and compile when a day has passed, or now when `force`.
    public func refresh(force: Bool) {}

    /// Every tab's content controller comes from here, so every tab gets
    /// every list, and a list compiled later reaches tabs already open.
    func contentController() -> WKUserContentController { WKUserContentController() }
}

// STUB
@MainActor
public final class Scriptlets {
    public static let shared = Scriptlets()

    /// Before a frame in `controller`'s web view loads `url`: that host's
    /// scriptlets join the ones its other frames already have.
    func prepare(_ controller: WKUserContentController, for url: URL?) {}
}

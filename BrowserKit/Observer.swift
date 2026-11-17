import Observation

/// Keeps something in step with what it reads: `apply` runs now, and again
/// after anything observable it read has changed, for as long as the
/// observer is kept. How AppKit and UIKit views follow `Browser`, its tabs
/// and the settings; SwiftUI views just read them.
@MainActor
public final class Observer {
    private var apply: (@MainActor () -> Void)?

    public init(_ apply: @escaping @MainActor () -> Void) {
        self.apply = apply
        run()
    }

    private func run() {
        guard let apply else { return }
        withObservationTracking(apply) { [weak self] in
            // Told as the value is about to change: read it once it has.
            Task { @MainActor in self?.run() }
        }
    }

    public func cancel() { apply = nil }
}

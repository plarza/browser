import AppKit

/// Events seen before the window hands them to a view, for as long as the
/// monitor is kept. `handle` says whether the event stops here.
@MainActor
final class EventMonitor {
    private var token: Any?

    init(_ events: NSEvent.EventTypeMask, _ handle: @escaping @MainActor (NSEvent) -> Bool) {
        token = NSEvent.addLocalMonitorForEvents(matching: events) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    isolated deinit {
        if let token { NSEvent.removeMonitor(token) }
    }
}

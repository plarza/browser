import BrowserKit
import UIKit

/// System alerts: a page's alert, confirm and prompt, and Browser's own
/// questions. One at a time, each waiting for the one before.
@MainActor
final class Alerts {
    private weak var presenter: UIViewController?
    private var last: Task<Void, Never>?

    init(presenter: UIViewController) {
        self.presenter = presenter
    }

    /// Who is asking: the page's site.
    static func title(for tab: Tab) -> String {
        tab.site ?? "This page"
    }

    func tell(_ message: String, from tab: Tab) async {
        _ = await ask(Alerts.title(for: tab), detail: message, no: nil)
    }

    func ask(_ question: String, detail: String? = nil, yes: String = "OK", no: String? = "Cancel", destructive: Bool = false) async -> Bool {
        await inTurn { [self] in
            await withCheckedContinuation { answer in
                let alert = UIAlertController(title: question, message: detail, preferredStyle: .alert)
                if let no { alert.addAction(UIAlertAction(title: no, style: .cancel) { _ in answer.resume(returning: false) }) }
                let agree = UIAlertAction(title: yes, style: destructive ? .destructive : .default) { _ in answer.resume(returning: true) }
                alert.addAction(agree)
                alert.preferredAction = agree
                if !show(alert) { answer.resume(returning: false) }
            }
        }
    }

    func prompt(_ message: String, from tab: Tab, defaultText: String?) async -> String? {
        await inTurn { [self] in
            await withCheckedContinuation { answer in
                let alert = UIAlertController(title: Alerts.title(for: tab), message: message, preferredStyle: .alert)
                alert.addTextField { $0.text = defaultText }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer.resume(returning: nil) })
                let agree = UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                    answer.resume(returning: alert?.textFields?.first?.text ?? "")
                }
                alert.addAction(agree)
                alert.preferredAction = agree
                if !show(alert) { answer.resume(returning: nil) }
            }
        }
    }

    /// Over whatever is on top. False if there is nothing to show it on.
    private func show(_ alert: UIAlertController) -> Bool {
        guard var top = presenter, top.view.window != nil else { return false }
        while let above = top.presentedViewController, !above.isBeingDismissed { top = above }
        top.present(alert, animated: true)
        return true
    }

    private func inTurn<Answer: Sendable>(_ ask: @escaping @MainActor () async -> Answer) async -> Answer {
        let before = last
        let mine = Task {
            await before?.value
            return await ask()
        }
        last = Task { _ = await mine.value }
        return await mine.value
    }
}

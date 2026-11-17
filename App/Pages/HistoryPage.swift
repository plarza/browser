import BrowserKit
import SwiftUI

/// What about://history is showing: what was searched for, and the pages
/// History found.
@MainActor @Observable
final class HistoryModel {
    static let shared = HistoryModel()
    var query = ""
    private(set) var results: [History.Visit] = []

    /// History's answer for the query as it stands; an answer overtaken
    /// by a newer search is dropped.
    func refresh() async {
        let found = await History.shared.search(query)
        if !Task.isCancelled { results = found }
    }
}

/// about://history: every word searched across addresses and titles;
/// entries removed one at a time, or all at once.
struct HistoryPage: View {
    let open: (URL) -> Void
    @Bindable private var model = HistoryModel.shared

    /// What the results were looked up for: they are looked up again when
    /// the search or History itself changes.
    private struct Lookup: Equatable {
        let query: String
        let version: Int
    }

    var body: some View {
        GeometryReader { geometry in
            let margin = InternalPages.margin(geometry.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SearchField(text: $model.query, placeholder: "Search History") {
                        if let first = model.results.first, let url = URL(string: first.url) { open(url) }
                    }
                    .controlSize(.large)
                    Button("Clear History") {
                        Task {
                            guard await Dialogs.ask("Clear all history?", yes: "Clear History") else { return }
                            History.shared.clear()
                        }
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                }
                .padding(.horizontal, margin + 16)
                .padding(.vertical, 16)
                if !model.results.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.results, id: \.url) { visit in
                                Row(visit: visit, open: open)
                                Divider()
                            }
                        }
                    }
                    .contentMargins(.horizontal, margin + 16, for: .scrollContent)
                } else if model.query.isEmpty {
                    Spacer()
                } else {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                }
            }
        }
        .task(id: Lookup(query: model.query, version: History.shared.version)) { await model.refresh() }
    }

    /// One page: its icon, title and address, and Remove while the pointer
    /// is over it. Clicking opens it in this tab.
    private struct Row: View {
        let visit: History.Visit
        let open: (URL) -> Void
        @State private var hovering = false

        var body: some View {
            let bare = History.bare(visit.url)
            HStack(spacing: 10) {
                SiteIcon(url: URL(string: visit.url))
                VStack(alignment: .leading, spacing: 1) {
                    Text(visit.title.isEmpty ? bare : visit.title).lineLimit(1)
                    Text(bare).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Remove") { History.shared.remove(visit.url) }
                    .buttonBorderShape(.capsule)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if let url = URL(string: visit.url) { open(url) } }
        }
    }
}

import BrowserKit
import SwiftUI

/// about://history: every word searched across addresses and titles.
/// Entries go one at a time, or all at once.
struct HistoryScreen: View {
    let open: (URL) -> Void
    @State private var query = ""
    @State private var visits: [History.Visit] = []
    @State private var clearing = false

    var body: some View {
        List {
            ForEach(visits, id: \.url) { visit in
                Button {
                    if let url = URL(string: visit.url) { open(url) }
                } label: {
                    HStack(spacing: 12) {
                        SiteIcon(url: URL(string: visit.url)).frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(visit.title.isEmpty ? History.bare(visit.url) : visit.title).lineLimit(1).foregroundStyle(.primary)
                            Text(History.bare(visit.url)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .onDelete { rows in
                for row in rows { History.shared.remove(visits[row].url) }
                visits.remove(atOffsets: rows)
            }
        }
        .overlay {
            if visits.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No History", systemImage: "clock")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        // At the top: along the bottom, the bar would cover it.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search History")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar {
            Button("Clear") { clearing = true }.disabled(visits.isEmpty && query.isEmpty)
        }
        .alert("Clear all history?", isPresented: $clearing) {
            Button("Clear History", role: .destructive) { History.shared.clear() }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: Search(query: query, version: History.shared.version)) {
            let found = await History.shared.search(query)
            if !Task.isCancelled { visits = found }
        }
    }

    /// What the list was looked up for: looked up again when either changes.
    private struct Search: Equatable {
        let query: String
        let version: Int
    }
}

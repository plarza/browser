import BrowserKit
import SwiftUI

/// about://downloads: every download until Clear, newest first.
struct DownloadsPage: View {
    var body: some View {
        let items = Downloads.shared.items
        GeometryReader { geometry in
            let margin = InternalPages.margin(geometry.size.width)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Clear Downloads") {
                        Task {
                            if await Dialogs.ask("Clear downloads?", detail: "Files stay on disk.", yes: "Clear") { Downloads.shared.clear() }
                        }
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .disabled(items.allSatisfy { $0.state == .active })
                }
                .padding(.horizontal, margin + 16)
                .padding(.vertical, 16)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            Row(item: item)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .contentMargins(.horizontal, margin, for: .scrollContent)
            }
        }
    }

    /// One download: its file's icon, its name, how it went, and what can
    /// be done with it while the pointer is over it. A double click opens
    /// a finished one.
    private struct Row: View {
        let item: Downloads.Item
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: item.file.pathExtension) ?? .data))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 6) {
                    if item.state == .active {
                        Button("Cancel") { Task { await Dialogs.cancelDownload(item) } }.buttonBorderShape(.capsule)
                    } else {
                        if FileManager.default.fileExists(atPath: item.file.path) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.file]) }.buttonBorderShape(.capsule)
                        }
                        Button("Remove") { Downloads.shared.remove(item) }.buttonBorderShape(.capsule)
                    }
                }
                .opacity(hovering ? 1 : 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { if item.state == .finished { NSWorkspace.shared.open(item.file) } }
        }

        /// How far along it is, or how it ended, its size and the site it came from.
        private var status: String {
            let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            let site = item.site.isEmpty ? "" : " · \(item.site)"
            switch item.state {
            case .active: return item.expected > 0 ? "\(size(item.received)) of \(size(item.expected))" : size(item.received)
            case .failed: return "Failed\(site)"
            case .cancelled: return "Cancelled\(site)"
            case .finished:
                let gone = FileManager.default.fileExists(atPath: item.file.path) ? "" : " · missing"
                return size(item.received) + site + gone
            }
        }
    }
}

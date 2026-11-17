import BrowserKit
import QuickLook
import SwiftUI

/// about://downloads: every download until it is cleared. The files are
/// in `Downloads`, in Browser's folder in the Files app.
struct DownloadsScreen: View {
    @State private var clearing = false
    @State private var cancelling: Downloads.Item?
    @State private var previewed: URL?

    var body: some View {
        let downloads = Downloads.shared
        List {
            ForEach(downloads.items) { item in
                DownloadRow(item: item) {
                    if item.state == .finished { previewed = item.file }
                }
                .swipeActions {
                    if item.state == .active {
                        Button("Cancel", role: .destructive) { cancelling = item }
                    } else {
                        Button("Remove", role: .destructive) { downloads.remove(item) }
                    }
                }
            }
        }
        .overlay {
            if downloads.items.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Files you download are kept in Browser’s folder in the Files app."))
            }
        }
        .toolbar {
            Button("Clear") { clearing = true }.disabled(downloads.items.isEmpty)
        }
        .alert("Clear downloads?", isPresented: $clearing) {
            Button("Clear", role: .destructive) { downloads.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files stay in the Files app.")
        }
        .alert("Cancel this download?", isPresented: Binding { cancelling != nil } set: { if !$0 { cancelling = nil } }, presenting: cancelling) { item in
            Button("Cancel Download", role: .destructive) { downloads.cancel(item) }
            Button("Keep Downloading", role: .cancel) {}
        } message: { item in
            Text(item.name)
        }
        .quickLookPreview($previewed)
    }
}

/// A download: its name, the site it came from, and how it is doing.
private struct DownloadRow: View {
    let item: Downloads.Item
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
                Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if item.state == .active {
                    ProgressView(value: item.fraction)
                }
            }
        }
    }

    private var status: String {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let progress = switch item.state {
        case .active: item.expected > 0 ? "\(size(item.received)) of \(size(item.expected))" : size(item.received)
        case .finished: size(item.received)
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
        return item.site.isEmpty ? progress : "\(item.site) · \(progress)"
    }
}

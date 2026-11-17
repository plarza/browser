import BrowserKit
import SwiftUI

/// A site's icon in a list on one of Browser's pages: a globe until it is
/// known. A site not open in any tab has its icon fetched, once.
struct SiteIcon: View {
    let url: URL?

    var body: some View {
        Group {
            if let icon = Favicons.shared.icon(for: url) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onAppear { if let url { Favicons.shared.fetch(site: url) } }
    }
}

import BrowserKit
import SwiftUI

/// A site's icon, or a globe until it is known. Browser's own pages show
/// the logo in grey.
struct SiteIcon: View {
    let url: URL?

    var body: some View {
        if let icon = InternalPage(url) == nil ? Favicons.shared.icon(for: url) : Favicons.browser {
            Image(uiImage: icon).resizable().interpolation(.high).scaledToFit()
                .clipShape(.rect(cornerRadius: 3.5, style: .continuous))
        } else {
            Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.tertiary)
        }
    }
}

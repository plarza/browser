import BrowserKit
import SwiftUI

/// One of Browser's own pages, as a native screen in the tab.
struct OwnPage: View {
    struct Showing: Equatable {
        let page: InternalPage
        /// The tab it shows in: each tab's page is its own.
        let tab: UUID
    }

    let showing: Showing?
    let browser: Browser

    var body: some View {
        if let showing {
            NavigationStack {
                Group {
                    switch showing.page {
                    case .history: HistoryScreen { browser.selected?.load($0) }
                    case .downloads: DownloadsScreen()
                    case .settings: SettingsForm()
                    case .userscripts: UserscriptsScreen()
                    case .help: HelpScreen { browser.show($0) }
                    }
                }
                .navigationTitle(showing.page.title)
            }
            .id(showing.tab)
        }
    }
}

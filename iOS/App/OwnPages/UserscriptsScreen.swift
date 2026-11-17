import BrowserKit
import SwiftUI

/// about://userscripts: the installed scripts, each with its name, its
/// sites and a switch. A change reaches a page at its next load.
struct UserscriptsScreen: View {
    var body: some View {
        let userscripts = Userscripts.shared
        List {
            ForEach(userscripts.scripts) { script in
                Toggle(isOn: Binding { script.enabled } set: { userscripts.setEnabled(script.id, $0) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(script.name).lineLimit(1)
                        Text(script.meta.sites).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .onDelete { rows in
                for id in rows.map({ userscripts.scripts[$0].id }) { userscripts.remove(id) }
            }
        }
        .overlay {
            if userscripts.scripts.isEmpty {
                ContentUnavailableView("No Userscripts", systemImage: "curlybraces")
            }
        }
    }
}

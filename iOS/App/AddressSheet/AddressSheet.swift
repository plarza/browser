import BrowserKit
import SwiftUI

/// What the address sheet holds: the field at its top, and under it pages
/// from History, looked up as you type. If what's typed isn't an address,
/// a last row searches for it. Nothing is fetched while typing.
struct AddressSheet: View {
    /// What the field starts with, selected.
    let address: String
    let go: (String) -> Void

    /// What was actually typed: the field may show more, filled in.
    @State private var typed = ""
    @State private var completion: History.Completion?

    var body: some View {
        // The keyboard's height comes in as safe area. Nothing moves out of
        // its way, but the list scrolls clear of it.
        GeometryReader { box in
            VStack(spacing: 6) {
                field
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(completion?.pages ?? [], id: \.url) { page in
                            AddressRow(title: page.title.isEmpty ? History.bare(page.url) : page.title, detail: History.bare(page.url)) {
                                SiteIcon(url: URL(string: page.url))
                            } action: {
                                History.shared.picked(page.url, after: typed)
                                go(page.url)
                            }
                        }
                        if searches {
                            AddressRow(title: typed, detail: nil) {
                                Image(systemName: "magnifyingglass").resizable().scaledToFit().foregroundStyle(.secondary)
                            } action: {
                                go(typed)
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.never)
                .contentMargins(.bottom, box.safeAreaInsets.bottom + 12, for: .scrollContent)
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.keyboard)
        }
        .background {
            Color.clear
                .glassEffect(.regular, in: .rect(topLeadingRadius: 38, topTrailingRadius: 38, style: .continuous))
                .ignoresSafeArea()
        }
        .task(id: typed) {
            let looked = await History.shared.complete(typed)
            if !Task.isCancelled { completion = looked }
        }
    }

    /// Words, not an address: the last row searches for them.
    private var searches: Bool {
        !typed.trimmingCharacters(in: .whitespaces).isEmpty && !Address.isAddress(typed)
    }

    private var field: some View {
        AddressField(address: address, typed: $typed, fill: completion?.fill, go: go)
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(.fill.tertiary, in: .capsule)
            .padding(.horizontal, 16)
    }
}

/// A page from History, or the search for what's typed.
private struct AddressRow<Icon: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let icon: Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon.frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 17)).lineLimit(1)
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

import BrowserKit
import SwiftUI

/// Every tab as a card, two to a row, as Safari has them. It stays laid
/// out under the page, so the page always knows where its card is.
struct TabGrid: View {
    @Environment(Browser.self) private var browser
    /// Kept on the selected tab's card, so it's on screen to land on.
    @State private var scrolled: UUID?

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(browser.tabs, id: \.id) { tab in
                        TabCard(tab: tab)
                            .id(tab.id)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .scrollPosition(id: $scrolled, anchor: .center)
            // Cards fade out under the clock rather than run into it.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 70)
                    Color.black
                }
                .ignoresSafeArea()
            }
            .overlay {
                if browser.tabs.isEmpty {
                    Text("No Tabs").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            bar
                .modifier(GridBarReveal())
        }
        .onChange(of: browser.selected?.id, initial: true) { _, id in
            if !browser.gridShown { scrolled = id }
        }
    }

    private var bar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                GlassCircle(symbol: "ellipsis", label: "Settings") { browser.showingSettings = true }
                Text("Search or enter website name")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(.capsule)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .onTapGesture { browser.edit(.newTab) }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 4)
    }
}

/// The grid's bar rises as the grid comes.
private struct GridBarReveal: ViewModifier {
    @Environment(Browser.self) private var browser

    func body(content: Content) -> some View {
        let p = browser.gridProgress
        content.opacity(p).offset(y: (1 - p) * 40)
    }
}

/// A card is hidden while the page is on its way to or from it.
private struct CardLanding: ViewModifier {
    @Environment(Browser.self) private var browser
    let tab: Tab

    func body(content: Content) -> some View {
        content.modifier(Settled(progress: tab === browser.selected ? browser.gridProgress : 1, showsAt: 1))
    }
}

struct TabCard: View {
    let tab: Tab
    @Environment(Browser.self) private var browser
    @State private var swipe: CGFloat = 0
    static let radius: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TabPicture(image: browser.snapshots[tab.id])
                .overlay {
                    if browser.snapshots[tab.id] == nil { placeholder }
                }
                .aspectRatio(0.78, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .overlay {
                    if tab.persist {
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.persist, lineWidth: 3)
                    }
                }
                .shadow(color: .black.opacity(0.13), radius: 10, y: 4)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { browser.cardFrames[tab.id] = $0 }
                // Hidden while the page is on its way to or from it.
                .modifier(CardLanding(tab: tab))
                .overlay(alignment: .topTrailing) {
                    Button { close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .padding(7)
                    .accessibilityLabel("Close Tab")
                }
            HStack(spacing: 6) {
                icon.frame(width: 16, height: 16)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .offset(x: swipe)
        .opacity(1 - min(0.7, abs(swipe) / 260))
        .onTapGesture { browser.showPage(tab) }
        .contextMenu {
            if tab.opener == nil {
                Toggle(isOn: Binding(get: { tab.persist }, set: { tab.persist = $0 })) {
                    Label("Persist", systemImage: "lock")
                }
            }
            Button(role: .destructive) { close() } label: { Label("Close Tab", systemImage: "xmark") }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    swipe = value.translation.width
                }
                .onEnded { value in
                    let x = value.predictedEndTranslation.width
                    if abs(x) > 160, abs(value.translation.width) > abs(value.translation.height) {
                        withAnimation(Motion.snappy) { swipe = x > 0 ? 420 : -420 }
                        close()
                    } else {
                        withAnimation(Motion.spring()) { swipe = 0 }
                    }
                }
        )
    }

    /// Closed, or back where it was if a Persist tab's question was cancelled.
    private func close() {
        Task {
            if await !browser.closeAsking(tab) {
                withAnimation(Motion.spring()) { swipe = 0 }
            }
        }
    }

    private var title: String {
        if let page = tab.internalPage { return page.capitalized }
        if !tab.title.isEmpty { return tab.title }
        return tab.url?.host ?? "New Tab"
    }

    @ViewBuilder private var icon: some View {
        if let image = Favicons.shared.icon(for: tab.url) {
            Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        } else {
            Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    /// A tab with no picture yet (one restored at launch): its icon and site.
    private var placeholder: some View {
        VStack(spacing: 10) {
            icon.frame(width: 34, height: 34)
            Text(tab.url?.host ?? "").font(.caption).foregroundStyle(.secondary)
        }
    }
}

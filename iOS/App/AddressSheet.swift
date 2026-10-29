import BrowserKit
import SwiftUI

/// Arc's sheet: glass from the bottom, the field at its top and the pages
/// from History under it. Nothing typed leaves the phone until Go.
struct AddressSheet: View {
    @Environment(Browser.self) private var browser
    @State private var text = ""
    @State private var selection: TextSelection?
    /// What was actually typed; the rest of `text` is the filled-in site.
    @State private var typed = ""
    @State private var pages: [History.Visit] = []
    @FocusState private var focused: Bool
    /// How far the sheet has been pulled down; far enough closes it.
    @State private var pull: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // The page above, as a card: tapping it goes back to it.
            Color.clear
                .frame(height: 250)
                .contentShape(Rectangle())
                .onTapGesture { browser.edit(nil) }
            VStack(alignment: .leading, spacing: 4) {
                field
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(pages, id: \.url) { page in
                            row(icon: Favicons.shared.icon(for: URL(string: page.url)).map { Image(uiImage: $0) }, symbol: "globe",
                                title: page.title.isEmpty ? page.url : page.title, detail: Self.shortAddress(page.url)) {
                                browser.go(typed, picked: page.url)
                            }
                        }
                        if !typed.trimmingCharacters(in: .whitespaces).isEmpty, Address.url(from: typed) == nil {
                            row(icon: nil, symbol: "magnifyingglass", title: typed, detail: nil) { browser.go(typed) }
                        }
                    }
                }
                .scrollDismissesKeyboard(.never)
                // The keyboard sits over the end of the list; it scrolls clear.
                .contentMargins(.bottom, 340, for: .scrollContent)
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38, style: .continuous))
                    .ignoresSafeArea()
            }
        }
        .offset(y: pull)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { pull = max(0, $0.translation.height) }
                .onEnded { value in
                    if value.translation.height + value.velocity.height * 0.15 > 140 {
                        focused = false
                        browser.edit(nil)
                    } else {
                        withAnimation(Motion.spring()) { pull = 0 }
                    }
                }
        )
        .onAppear {
            let current = browser.editing == .current ? browser.selected : nil
            let url = current?.internalPage == nil ? current?.url?.absoluteString ?? "" : ""
            text = url
            typed = url
            focused = true
            #if DEBUG
            if let typed = Shots.typed { text = typed }
            #endif
        }
        .onChange(of: text) { old, new in changed(from: old, to: new) }
        // The address comes up selected, to type over. Once the field is
        // focused: focusing puts the cursor at the end, over any selection.
        .onChange(of: focused) { _, focused in
            guard focused, !text.isEmpty, typed == text else { return }
            Task {
                await Task.yield()
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("Search or enter website name", text: $text, selection: $selection)
                .font(.system(size: 19))
                .focused($focused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { browser.go(text) }
            if !text.isEmpty {
                Button { text = ""; typed = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func row(icon: Image?, symbol: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if let icon { icon.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous)) }
                    else { Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(.secondary) }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 17)).lineLimit(1)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func shortAddress(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Typing more fills in the rest of a site you've been to, selected, as
    /// Safari does; deleting doesn't.
    private func changed(from old: String, to new: String) {
        if new == filled { return }
        // Deleting (the text got shorter from its end) never fills back in.
        let grew = !(new.count < old.count && old.lowercased().hasPrefix(new.lowercased()))
        typed = new
        let input = new
        Task {
            let completion = await History.shared.complete(input)
            guard input == typed else { return }
            pages = completion.pages
            guard grew, !input.isEmpty, let fill = completion.fill,
                  fill.lowercased().hasPrefix(input.lowercased()), fill.count > input.count else { return }
            let full = input + fill.dropFirst(input.count)
            filled = full
            text = full
            selection = TextSelection(range: full.index(full.startIndex, offsetBy: input.count)..<full.endIndex)
        }
    }

    @State private var filled = ""
}

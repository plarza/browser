import AppKit
import BrowserKit
import SwiftUI

/// One of a setting's choices, as a segmented control.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    init(selection: Binding<Value>, _ options: [(Value, String)]) {
        _selection = selection
        self.options = options
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// A slider from 0 to `Settings.fillMax` that applies as it moves, not
/// only where it's let go.
struct SmoothSlider: NSViewRepresentable {
    @Binding var value: Double

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: 0, maxValue: Settings.fillMax,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SmoothSlider
        init(parent: SmoothSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) { parent.value = slider.doubleValue }
    }
}

/// A list edited a row at a time: each row with its site's icon and a ✕
/// that shows on hover; the last row is where a new one is typed. Taking a
/// row away asks first.
struct RowList: View {
    let items: [String]
    let placeholder: String
    let icon: (String) -> URL?
    let removal: (String) -> (title: String, detail: String)
    let normalise: (String) -> String?
    let save: ([String]) -> Void
    @State private var adding = ""
    @State private var hovered: String?

    var body: some View {
        ForEach(items, id: \.self) { item in
            HStack(spacing: 10) {
                SiteIcon(url: icon(item))
                Text(item).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    Task {
                        if await Dialogs.ask(removal(item).title, detail: removal(item).detail, yes: "Remove") { save(items.filter { $0 != item }) }
                    }
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(hovered == item ? 1 : 0)
                .help("Remove")
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        }
        HStack(spacing: 10) {
            Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 16)
            // In a form, a field's title is a label beside it; the prompt is
            // the text inside it, which is what this row wants.
            TextField("", text: $adding, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit(add)
        }
    }

    private func add() {
        let text = adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = normalise(text), !items.contains(item) else { return }
        save(items + [item])
        adding = ""
    }
}

/// The picture blank tabs show now, small.
struct NewTabThumbnail: View {
    /// Which choice of picture this is, so a new one is drawn.
    let version: Int

    var body: some View {
        Group {
            if let url = Settings.newTabImageInUse, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.1)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .id(version)
    }
}

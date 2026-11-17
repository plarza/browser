import SwiftUI

/// A list you add to and remove from: the whitelist, the filter lists.
struct EditableList: View {
    let items: [String]
    let placeholder: String
    /// What to ask before removing an item, and what removing it costs;
    /// without it, an item just goes.
    var question: ((String) -> (title: String, detail: String))?
    /// An item as it should be kept, or nil if it can't be one.
    let normalise: (String) -> String?
    let save: ([String]) -> Void

    @State private var adding = ""
    @State private var removing: String?

    var body: some View {
        ForEach(items, id: \.self) { item in
            Text(item).lineLimit(1).truncationMode(.middle)
                .swipeActions {
                    Button("Remove") {
                        if question == nil { remove(item) } else { removing = item }
                    }
                    .tint(.red)
                }
        }
        .alert(removing.flatMap { question?($0).title } ?? "", isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } }, presenting: removing) { item in
            Button("Remove", role: .destructive) { remove(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(question?(item).detail ?? "")
        }
        TextField(placeholder, text: $adding)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.done)
            .onSubmit {
                guard let item = normalise(adding.trimmingCharacters(in: .whitespaces)), !items.contains(item) else { return }
                save(items + [item])
                adding = ""
            }
    }

    private func remove(_ item: String) {
        save(items.filter { $0 != item })
    }
}

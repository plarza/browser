import SwiftUI
import UIKit

/// The address sheet's field: focused as it appears, the address selected
/// to type over. Typing more fills in the rest of the most frecent site,
/// selected, as Safari does; deleting never fills back in.
struct AddressField: UIViewRepresentable {
    let address: String
    /// What was typed, without what was filled in after it.
    @Binding var typed: String
    /// The whole site History would fill in for what's typed.
    let fill: String?
    let go: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.text = address
        field.placeholder = Look.placeholder
        field.font = .systemFont(ofSize: 19)
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.clearButtonMode = .whileEditing
        field.enablesReturnKeyAutomatically = true
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.field = self
        context.coordinator.complete(field)
    }

    /// Takes the keyboard as soon as it is on screen.
    final class Field: UITextField {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { becomeFirstResponder() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var field: AddressField
        /// The last change added to the end of what's typed: only then is
        /// the rest filled in.
        private var grew = false

        init(_ field: AddressField) {
            self.field = field
        }

        func textFieldDidBeginEditing(_ text: UITextField) {
            // Once the field has settled: focusing puts the cursor at the
            // end, over any selection made before.
            Task { text.selectAll(nil) }
        }

        func textField(_ text: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let length = (text.text ?? "").utf16.count
            grew = !string.isEmpty && range.location + range.length == length
            return true
        }

        func textFieldShouldClear(_ text: UITextField) -> Bool {
            grew = false
            return true
        }

        @objc func changed(_ text: UITextField) {
            // Mid-composition (an input method's marked text) isn't typed yet.
            guard text.markedTextRange == nil else { return }
            field.typed = text.text ?? ""
        }

        /// Fills in the rest of the site for what's typed, selected, so the
        /// next key types over it.
        func complete(_ text: UITextField) {
            let typed = field.typed
            guard grew, !typed.isEmpty, text.text == typed, text.markedTextRange == nil,
                  let fill = field.fill, fill.count > typed.count, fill.lowercased().hasPrefix(typed.lowercased()) else { return }
            grew = false
            text.text = typed + fill.dropFirst(typed.count)
            if let from = text.position(from: text.beginningOfDocument, offset: typed.utf16.count) {
                text.selectedTextRange = text.textRange(from: from, to: text.endOfDocument)
            }
        }

        func textFieldShouldReturn(_ text: UITextField) -> Bool {
            field.go(text.text ?? "")
            return false
        }
    }
}

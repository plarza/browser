#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// GM_setClipboard: text, or HTML when the script says that's what it is.
@MainActor
enum GMClipboard {
    static func set(_ call: UserscriptCall) throws(UserscriptRefusal) {
        guard call.grants.contains("setclipboard"), let data = call.string("data") else { throw .notGranted }
        let isHTML = (call.string("type") ?? "").contains("html")
        #if os(macOS)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(data, forType: isHTML ? .html : .string)
        #else
        if isHTML {
            UIPasteboard.general.setItems([[UTType.html.identifier: data]])
        } else {
            UIPasteboard.general.string = data
        }
        #endif
    }
}

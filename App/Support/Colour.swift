import AppKit

extension NSColor {
    /// "#RRGGBB"; anything else is black.
    convenience init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// The colour as "#RRGGBB".
    var hex: String {
        let colour = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(colour.redComponent * 255), Int(colour.greenComponent * 255), Int(colour.blueComponent * 255))
    }

    /// Persist's soft sky blue, top to bottom: a tab on Persist, deeper
    /// when selected.
    static func sky(selected: Bool, dark: Bool) -> [NSColor] {
        switch (dark, selected) {
        case (true, true): [NSColor(red: 0.16, green: 0.30, blue: 0.50, alpha: 1), NSColor(red: 0.12, green: 0.25, blue: 0.44, alpha: 1)]
        case (true, false): [NSColor(red: 0.12, green: 0.22, blue: 0.36, alpha: 1), NSColor(red: 0.10, green: 0.19, blue: 0.32, alpha: 1)]
        case (false, true): [NSColor(red: 0.36, green: 0.60, blue: 1, alpha: 1), NSColor(red: 0.45, green: 0.67, blue: 1, alpha: 1)]
        case (false, false): [NSColor(red: 0.50, green: 0.71, blue: 1, alpha: 1), NSColor(red: 0.60, green: 0.78, blue: 1, alpha: 1)]
        }
    }
}

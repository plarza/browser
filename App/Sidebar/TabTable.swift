import AppKit

/// The tab list's table. Pressing a row selects it; dragging lifts the row
/// out to follow the pointer, held where it was grabbed, while the others
/// slide out of its way.
@MainActor
final class TabTable: NSTableView {
    var onClick: (Int) -> Void = { _ in }
    /// The row at the first place now sits at the second.
    var onMove: (Int, Int) -> Void = { _, _ in }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        let grabbed = row(at: start)
        guard grabbed >= 0, let window else { return super.mouseDown(with: event) }
        var current = grabbed
        var lifted: NSImageView?
        let rowFrame = rect(ofRow: grabbed)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            MainActor.assumeIsolated {
                guard let event, event.type == .leftMouseDragged else { stop.pointee = true; return }
                let point = self.convert(event.locationInWindow, from: nil)
                if lifted == nil {
                    guard abs(point.y - start.y) > 3 else { return }
                    lifted = self.lift(row: current, frame: rowFrame)
                }
                // The lifted row keeps the grab point under the pointer.
                let y = min(max(rowFrame.minY + point.y - start.y, -rowFrame.height / 2), self.bounds.height - rowFrame.height / 2)
                lifted?.frame.origin.y = y
                let target = min(max(Int((y + rowFrame.height / 2) / (self.rowHeight + self.intercellSpacing.height)), 0), self.numberOfRows - 1)
                if target != current {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.15
                        self.moveRow(at: current, to: target)
                    }
                    self.onMove(current, target)
                    current = target
                }
            }
        }
        guard let lifted else { return onClick(grabbed) }
        // The row's own view, not its index: the list can change before
        // the animation ends (a tab closed), and the view goes with it.
        let hidden = view(atColumn: 0, row: current, makeIfNecessary: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            lifted.animator().frame.origin.y = rect(ofRow: current).minY
        } completionHandler: { [weak hidden] in
            MainActor.assumeIsolated {
                lifted.removeFromSuperview()
                hidden?.alphaValue = 1
            }
        }
    }

    /// A picture of the row, over the table; the row itself is left empty.
    private func lift(row: Int, frame: NSRect) -> NSImageView? {
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: false), let image = TabTable.picture(of: cell) else { return nil }
        let view = NSImageView(frame: frame)
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.shadowOpacity = 0.15
        view.layer?.shadowRadius = 6
        view.layer?.shadowOffset = NSSize(width: 0, height: -2)
        addSubview(view)
        #if DEBUG
        TabTable.lastLift = image
        #endif
        cell.alphaValue = 0
        return view
    }

    #if DEBUG
    /// The last row lifted, for the self-test to see that it was drawn.
    static var lastLift: NSImage?
    #endif

    /// Drawn now, while the row is still showing: the row's layers
    /// (selection, Persist's blue, the icon and title) at screen scale.
    private static func picture(of cell: NSView) -> NSImage? {
        let scale = cell.window?.backingScaleFactor ?? 2
        let size = cell.bounds.size
        guard size.width > 0, size.height > 0, let layer = cell.layer,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        // A card under it, so the rows it passes over don't show through.
        cell.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.textBackgroundColor.cgColor)
        }
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        cell.displayIfNeeded()
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

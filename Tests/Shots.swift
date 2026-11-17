#if DEBUG
import AppKit
import WebKit

/// Debug builds only: `-browserShots <folder>` has Browser draw its own
/// window, and only its window, into <folder>/<name>.png at each step that
/// asks for one, while it sits behind other windows. Nothing is captured
/// from the screen.
@MainActor
enum Shots {
    static var folder: URL? {
        UserDefaults.standard.string(forKey: "browserShots").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The window as it is now, into the shots folder as `name`.png.
    static func take(_ name: String, of shell: BrowserWindowController) async {
        guard let folder, let window = shell.window else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !(await draw(window, to: folder.appending(path: "\(name).png"))) {
            NSLog("Browser tooling: shot \(name) failed")
        }
    }

    /// The window as a PNG at `file`; false if it couldn't be drawn.
    static func draw(_ window: NSWindow, to file: URL) async -> Bool {
        // macOS doesn't draw a window it thinks nobody can see, and SwiftUI
        // then draws nothing. Lifted on top but all but transparent (and
        // ignoring the mouse) it draws; then back behind everything at full
        // opacity, where the window server still holds what it drew.
        let level = window.level, alpha = window.alphaValue, ignores = window.ignoresMouseEvents
        defer {
            window.alphaValue = alpha
            window.ignoresMouseEvents = ignores
        }
        window.ignoresMouseEvents = true
        window.alphaValue = 0.02
        window.level = .floating
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(600))
        window.level = level
        window.orderBack(nil)
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        try? await Task.sleep(for: .milliseconds(80))
        var picture = composited(window)
        // Without leave to record the screen the window server hands back
        // an empty picture: then Browser draws the window's views itself.
        if picture.map(isEmpty) ?? true { picture = await drawn(window) }
        guard let png = picture?.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: file)) != nil
    }

    /// The window server's own picture of this window, and nothing else:
    /// what AppKit, WebKit and SwiftUI all drew, composited. Only this
    /// window's number is asked for, so no other app can be in it. (The
    /// call is hidden from the SDK, not from macOS.)
    private static func composited(_ window: NSWindow) -> NSBitmapImageRep? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
              let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
        else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    /// One flat colour from edge to edge: no window looks like that.
    private static func isEmpty(_ picture: NSBitmapImageRep) -> Bool {
        let first = picture.colorAt(x: 0, y: 0)
        return stride(from: 0, to: picture.pixelsWide, by: max(1, picture.pixelsWide / 48)).allSatisfy { x in
            stride(from: 0, to: picture.pixelsHigh, by: max(1, picture.pixelsHigh / 48)).allSatisfy { y in
                picture.colorAt(x: x, y: y) == first
            }
        }
    }

    /// The window's own layers, as Core Animation has them, with WebKit's
    /// picture of each page laid in where its web view is (a page's layers
    /// live in another process) and whatever lies over it drawn again on
    /// top. Close to what's on screen, short of the system's glass and
    /// frost, which only the window server makes.
    private static func drawn(_ window: NSWindow) async -> NSBitmapImageRep? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        let scale = window.backingScaleFactor
        guard let context = CGContext(data: nil, width: Int(root.bounds.width * scale), height: Int(root.bounds.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        render(root, in: root, into: context)
        var painted: [NSView] = []
        for webView in showing(WKWebView.self, in: root) {
            do {
                draw(try await webView.takeSnapshot(configuration: nil), at: webView.convert(webView.bounds, to: root), into: context)
            } catch {
                NSLog("Browser tooling: no picture of \(webView.url?.absoluteString ?? "the page"): \(error.localizedDescription)")
            }
            for view in above(webView) {
                paint(view, in: root, into: context)
                painted.append(view)
            }
        }
        // What sits in glass has no layers of its own to render.
        for glass in showing(NSGlassEffectView.self, in: root) where !painted.contains(where: glass.isDescendant) {
            paint(glass, in: root, into: context)
        }
        return context.makeImage().map(NSBitmapImageRep.init(cgImage:))
    }

    private static func paint(_ view: NSView, in root: NSView, into context: CGContext) {
        let glass = showing(NSGlassEffectView.self, in: view)
        render(view, in: root, into: context)
        for view in glass {
            guard let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: picture)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(picture)
            draw(image, at: view.convert(view.bounds, to: root), into: context)
        }
    }

    private static func draw(_ image: NSImage, at frame: NSRect, into context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `view`'s layers where they lie in `root`, the right way up: a
    /// flipped view's layer counts down from its top.
    private static func render(_ view: NSView, in root: NSView, into context: CGContext) {
        guard let layer = view.layer, let rootLayer = root.layer else { return }
        let origin = layer.convert(CGPoint.zero, to: rootLayer)
        let top = layer.convert(CGPoint(x: 0, y: layer.bounds.height), to: rootLayer)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        if top.y < origin.y { context.scaleBy(x: 1, y: -1) }
        layer.render(in: context)
        context.restoreGState()
    }

    /// The views of one kind showing in `view`, itself included, bottom first.
    private static func showing<Kind: NSView>(_ kind: Kind.Type, in view: NSView) -> [Kind] {
        guard !view.isHidden, view.alphaValue > 0 else { return [] }
        if let found = view as? Kind { return [found] }
        return view.subviews.flatMap { showing(kind, in: $0) }
    }

    /// The views drawn over `view`, bottom first: the later subviews of
    /// each view it sits in.
    private static func above(_ view: NSView) -> [NSView] {
        var above: [NSView] = []
        var child = view
        while let parent = child.superview {
            if let place = parent.subviews.firstIndex(of: child) {
                above += parent.subviews[(place + 1)...].filter { !$0.isHidden && $0.alphaValue > 0 && !$0.bounds.isEmpty }
            }
            child = parent
        }
        return above
    }
}
#endif

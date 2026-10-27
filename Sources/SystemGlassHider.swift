import AppKit
import SwiftUI

// MenuBarExtra's .window style renders its own .regular glass layer behind the content; containerBackground(.clear, for: .window) leaves it in place.
struct SystemGlassHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowWatcher() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowWatcher: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { window.map(hideSystemGlass) }
            }
        }
    }
}

@MainActor
func hideSystemGlass(in window: NSWindow) {
    guard let root = window.contentView?.layer else { return }
    let glass = glassLayers(in: root, depth: 0)
    guard glass.count > 1,
          let shallowest = glass.min(by: { $0.depth < $1.depth }),
          glass.count(where: { $0.depth == shallowest.depth }) == 1
    else { return }
    shallowest.layer.isHidden = true
}

func glassLayers(in layer: CALayer, depth: Int) -> [(layer: CALayer, depth: Int)] {
    let isGlass = layer.filters?.contains { ($0 as? NSObject)?.value(forKey: "name") as? String == "glassBackground" } == true
    return (isGlass ? [(layer, depth)] : []) + (layer.sublayers ?? []).flatMap { glassLayers(in: $0, depth: depth + 1) }
}

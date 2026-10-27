#if DEBUG
import AppKit
import SwiftUI
import TapeCore

@MainActor
enum SettingsSnapshot {
    nonisolated static let output = UserDefaults.standard.string(forKey: "settingsSnapshot").map { URL(filePath: $0) }

    static func capture(to output: URL, updater: AppUpdater) async {
        SnapshotCapture.prepare()
        let base = output.deletingPathExtension().path
        let general = GeneralSettings(settings: .shared).environment(updater).frame(width: 480)
        guard await SnapshotCapture.write(general, title: "General", to: URL(filePath: "\(base)-general.png")),
              await SnapshotCapture.write(AboutSettings().frame(width: 480), title: "About", to: URL(filePath: "\(base)-about.png"))
        else { fail(#line) }
        exit(0)
    }
}

@MainActor
enum LabelSnapshot {
    nonisolated static let output = UserDefaults.standard.string(forKey: "labelSnapshot").map { URL(filePath: $0, directoryHint: .isDirectory) }

    static func capture(to directory: URL, recorder: Recorder) async {
        SnapshotCapture.prepare()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let labels: [(String, Recorder.Phase, Int)] = [
            ("idle", .idle, 0),
            ("recording", .recording(since: .now), 754),
            ("recording-hours", .recording(since: .now), 3725),
        ]
        for (name, phase, elapsed) in labels {
            let image = menuBarImage(phase: phase, elapsed: elapsed)
            for (bar, glyph, suffix) in [(NSColor(white: 0.93, alpha: 1), NSColor.black, "light"), (NSColor(white: 0.12, alpha: 1), .white, "dark")] {
                for scale in [1, 2] {
                    guard let png = menuBar(image, bar: bar, glyph: glyph, scale: CGFloat(scale)) else { fail(#line) }
                    try? png.write(to: directory.appending(path: "label-\(name)-\(suffix)@\(scale)x.png"))
                }
            }
            print("label-\(name): \(image.size.width)x\(image.size.height) pt, \(image.accessibilityDescription ?? "")")
        }
        recorder.simulate(since: .now.addingTimeInterval(-754), microphone: "MacBook Pro Microphone", notice: nil)
        guard await SnapshotCapture.write(RecordingView(recorder: recorder), title: "Tape", to: directory.appending(path: "recording-window.png")) else { fail(#line) }
        exit(0)
    }

    // Fills the template the way the menu bar does (.sourceAtop keeps its alpha), on a 24 pt bar.
    private static func menuBar(_ template: NSImage, bar: NSColor, glyph: NSColor, scale: CGFloat) -> Data? {
        let size = NSSize(width: template.size.width + 16, height: 24)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        let filled = NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            glyph.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        bar.setFill()
        NSRect(origin: .zero, size: size).fill()
        filled.draw(at: NSPoint(x: 8, y: ((size.height - template.size.height) / 2).rounded()), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

@MainActor
enum MenuSnapshot {
    nonisolated static let output = UserDefaults.standard.string(forKey: "menuSnapshot").map { URL(filePath: $0, directoryHint: .isDirectory) }

    // Off screen only the custom-view rows and item images can be drawn; standard items are printed as an outline.
    static func capture(to directory: URL, recorder: Recorder, updater: AppUpdater, recent: RecentRecordings) async {
        SnapshotCapture.prepare()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let statusMenu = StatusMenu(recorder: recorder, settings: .shared, updater: updater, recent: recent)
        let today = Calendar.current.startOfDay(for: .now)
        let recordings = [
            RecentRecordings.Item(url: URL(filePath: "/a.m4a"), startedAt: today.addingTimeInterval(13 * 3600 + 120), duration: 1451),
            RecentRecordings.Item(url: URL(filePath: "/b.m4a"), startedAt: today.addingTimeInterval(9 * 3600 + 1800), duration: 2512),
            RecentRecordings.Item(url: URL(filePath: "/c.m4a"), startedAt: today.addingTimeInterval(-7 * 3600), duration: 4983),
        ]
        let started = Date.now.addingTimeInterval(-1451)
        let scenarios: [(name: String, since: Date?, notice: Notice?, staged: String?, items: [RecentRecordings.Item], highlighted: NSUserInterfaceItemIdentifier?, reducesEcho: Bool, microphone: String?)] = [
            ("idle", nil, nil, nil, recordings, nil, false, "MacBook Pro Microphone"),
            ("idle-record-highlighted", nil, nil, nil, recordings, StatusMenu.recordItem, true, "MacBook Pro Microphone"),
            ("idle-echo-highlighted", nil, nil, nil, recordings, StatusMenu.reduceEchoItem, true, "MacBook Pro Microphone"),
            ("recording", started, nil, nil, recordings, nil, true, "MacBook Pro Microphone"),
            ("recording-highlighted", started, nil, nil, recordings, StatusMenu.recordItem, true, "MacBook Pro Microphone"),
            ("recording-notice", started, .reduceEchoUnavailable, "0.3.0", recordings, nil, true, "MacBook Pro Microphone"),
            ("notice", nil, .microphoneDenied, nil, recordings, nil, true, "MacBook Pro Microphone"),
            ("notice-info", nil, .fellBack(folder: "Call Recordings"), nil, recordings, nil, true, "MacBook Pro Microphone"),
            ("update", nil, nil, "0.3.0", recordings, nil, true, "MacBook Pro Microphone"),
            ("empty", nil, nil, nil, [], nil, false, "MacBook Pro Microphone"),
            ("no-microphone", nil, nil, nil, recordings, nil, false, nil),
        ]
        for scenario in scenarios {
            recorder.simulate(since: scenario.since, microphone: scenario.since == nil ? nil : "AirPods Pro", notice: scenario.notice)
            updater.simulateStaged(scenario.staged)
            recent.simulate(scenario.items)
            AppSettings.shared.reducesEcho = scenario.reducesEcho
            statusMenu.microphone.simulate(scenario.microphone)
            statusMenu.rebuild()
            statusMenu.highlight.item = scenario.highlighted
            print("menu-\(scenario.name):")
            for item in statusMenu.menu.items {
                print("  \(outline(of: item))")
            }
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let background = menuBackground(rows: statusMenu.menu.items.compactMap(row(for:)))
                let window = UnconstrainedWindow(contentRect: background.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = background
                window.appearance = NSAppearance(named: appearance)
                guard await SnapshotCapture.write(window, to: directory.appending(path: "menu-\(scenario.name)-\(suffix).png")) else { fail(#line) }
            }
        }
        exit(0)
    }

    private static func outline(of item: NSMenuItem) -> String {
        if item.isSeparatorItem { return "──" }
        let kind = item.view != nil ? "view" : item.isSectionHeader ? "header" : "item"
        let details = [
            item.subtitle.map { "subtitle \"\($0)\"" },
            item.keyEquivalent.isEmpty ? nil : "⌘\(item.keyEquivalent.uppercased())",
            item.isEnabled ? nil : "disabled",
            item.image == nil ? nil : imageVisibility(of: item),
        ].compactMap { $0 }
        return "[\(kind)] \(item.title)\(details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")"
    }

    private static func row(for item: NSMenuItem) -> NSView? {
        if let view = item.view { return view }
        if #available(macOS 27, *), item.preferredImageVisibility == .hidden { return nil }
        return item.image.map(imageView)
    }

    private static func imageVisibility(of item: NSMenuItem) -> String {
        guard #available(macOS 27, *) else { return "image" }
        if item.preferredImageVisibility == .hidden { return "image hidden" }
        return item.preferredImageVisibility == .visible ? "image visible" : "image automatic"
    }

    private static func imageView(_ image: NSImage) -> NSView {
        let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        view.image = image
        return view
    }

    private static func menuBackground(rows: [NSView]) -> NSView {
        let gap: CGFloat = 12
        let height = rows.map(\.frame.height).reduce(gap, +) + gap * CGFloat(rows.count)
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: StatusMenu.width, height: height))
        background.material = .menu
        background.state = .active
        var top = height - gap
        for row in rows {
            let slot = NSView(frame: NSRect(x: 0, y: top - row.frame.height, width: row.frame.width, height: row.frame.height))
            row.removeFromSuperview()
            row.setFrameOrigin(.zero)
            slot.addSubview(row)
            background.addSubview(slot)
            top -= row.frame.height + gap
        }
        return background
    }
}

func fail(_ line: Int) -> Never {
    FileHandle.standardError.write(Data("snapshot failed at line \(line)\n".utf8))
    exit(1)
}

@MainActor
enum SnapshotCapture {
    static func prepare() {
        NSApp.setActivationPolicy(.prohibited)
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
    }

    static func write(_ view: some View, title: String, to output: URL) async -> Bool {
        let window = UnconstrainedWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = title
        return await write(window, to: output)
    }

    static func write(_ window: NSWindow, to output: URL) async -> Bool {
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { fail(#line) }
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5))
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { fail(#line) }
        guard let image = image(of: window),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        window.orderOut(nil)
        return (try? png.write(to: output)) != nil
    }

    // cacheDisplay skips Liquid Glass; CGWindowListCreateImage is SDK-obsoleted but still exported and captures own windows without Screen Recording.
    private static func image(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }
}
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
#endif

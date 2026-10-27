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
enum PanelSnapshot {
    nonisolated static let output = UserDefaults.standard.string(forKey: "panelSnapshot").map { URL(filePath: $0, directoryHint: .isDirectory) }

    static func capture(to directory: URL, recorder: Recorder, updater: AppUpdater, recent: RecentRecordings) async {
        SnapshotCapture.prepare()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let today = Calendar.current.startOfDay(for: .now)
        let recordings = [
            RecentRecordings.Item(url: URL(filePath: "/a.m4a"), startedAt: today.addingTimeInterval(13 * 3600 + 120), duration: 1451),
            RecentRecordings.Item(url: URL(filePath: "/b.m4a"), startedAt: today.addingTimeInterval(9 * 3600 + 1800), duration: 2512),
            RecentRecordings.Item(url: URL(filePath: "/c.m4a"), startedAt: today.addingTimeInterval(-7 * 3600), duration: 4983),
        ]
        let started = Date.now.addingTimeInterval(-1451)
        let scenarios: [(name: String, since: Date?, notice: Notice?, staged: String?, items: [RecentRecordings.Item])] = [
            ("idle", nil, nil, nil, recordings),
            ("recording", started, nil, nil, recordings),
            ("recording-notice", started, .reduceEchoUnavailable, "0.3.0", recordings),
            ("notice", nil, .microphoneDenied, nil, recordings),
            ("notice-info", nil, .fellBack(folder: "Call Recordings"), nil, recordings),
            ("update", nil, nil, "0.3.0", recordings),
            ("empty", nil, nil, nil, []),
        ]
        for scenario in scenarios {
            recorder.simulate(since: scenario.since, microphone: scenario.since == nil ? nil : "AirPods Pro", notice: scenario.notice)
            updater.simulateStaged(scenario.staged)
            recent.simulate(scenario.items)
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let panel = TapePanel(recorder: recorder, settings: .shared, updater: updater, recent: recent)
                    .environment(\.controlActiveState, .key)
                    .padding(24)
                    .background(LinearGradient(colors: [.orange, .pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                let window = UnconstrainedWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: panel)
                window.setContentSize(window.contentView?.fittingSize ?? .zero)
                window.backgroundColor = .windowBackgroundColor
                window.appearance = NSAppearance(named: appearance)
                guard await SnapshotCapture.write(window, to: directory.appending(path: "panel-\(scenario.name)-\(suffix).png")) else { fail(#line) }
            }
        }
        exit(0)
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

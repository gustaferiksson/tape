#if DEBUG
import AppKit
import SwiftUI

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
            let scaled = NSImage(size: NSSize(width: image.size.width * 4, height: image.size.height * 4), flipped: false) { rect in
                image.draw(in: rect)
                return true
            }
            guard let tiff = scaled.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { fail(#line) }
            try? png.write(to: directory.appending(path: "label-\(name).png"))
            print("label-\(name): \(image.size.width)x\(image.size.height) pt, \(image.accessibilityDescription ?? "")")
        }
        recorder.simulateRecording(since: .now.addingTimeInterval(-754), microphone: "MacBook Pro Microphone")
        guard await SnapshotCapture.write(RecordingView(recorder: recorder), title: "Tape", to: directory.appending(path: "recording-window.png")) else { fail(#line) }
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

import SwiftUI
import TapeCore

@main
struct TapeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarInserted) {
            TapeMenu(recorder: appDelegate.recorder, settings: .shared, updater: appDelegate.updater)
        } label: {
            Image(nsImage: menuBarImage(phase: appDelegate.recorder.phase, elapsed: appDelegate.recorder.elapsed))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: .shared)
                .environment(appDelegate.updater)
        }
    }

    private var menuBarInserted: Binding<Bool> {
        #if DEBUG
        if SettingsSnapshot.output != nil || LabelSnapshot.output != nil { return .constant(false) }
        #endif
        return .constant(true)
    }
}

private struct TapeMenu: View {
    let recorder: Recorder
    let settings: AppSettings
    let updater: AppUpdater

    var body: some View {
        if let since = recorder.startedAt {
            Button("Stop Recording") { Task { await recorder.stop() } }
                .disabled(!recorder.isRecording)
            Text("Recording audio · since \(since.formatted(date: .omitted, time: .shortened))\(recorder.isSavingToFallback ? " · saving to Movies › Tape" : "")")
            Text(recorder.microphoneName.map { "Microphone: \($0)" } ?? "Microphone unavailable")
            if let notice = recorder.notice { Text(notice.text) }
            Toggle("Reduce Echo", isOn: Bindable(settings).reducesEcho)
                .disabled(true)
            Divider()
            Button("Open Recordings Folder", action: openFolder)
            Divider()
            UpdateMenuItems(updater: updater, isRecording: true)
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Stop and Quit Tape") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } else {
            Button("Record Audio") { Task { await recorder.start() } }
                .disabled(recorder.phase == .starting)
            if let notice = recorder.notice {
                Text(notice.text)
                if let pane = notice.privacyPane {
                    Button("Open Privacy Settings…") { NSWorkspace.shared.open(pane.url) }
                }
            }
            Divider()
            Toggle("Reduce Echo", isOn: Bindable(settings).reducesEcho)
            Divider()
            Button("Show Last Recording in Finder") {
                if let url = recorder.lastRecording { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(recorder.lastRecording.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
            Button("Open Recordings Folder", action: openFolder)
            Divider()
            UpdateMenuItems(updater: updater, isRecording: false)
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Quit Tape") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func openFolder() {
        let folder = FileManager.default.fileExists(atPath: settings.saveFolder.path) ? settings.saveFolder : AppSettings.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

private struct UpdateMenuItems: View {
    let updater: AppUpdater
    let isRecording: Bool

    var body: some View {
        if let staged = updater.staged {
            Button(isRecording ? "Tape \(staged.version) installs after recording" : "Install Tape \(staged.version) and Relaunch", action: updater.installAndRelaunch)
                .disabled(isRecording)
        } else {
            Button(checkTitle) { updater.check(.manual) }
                .disabled(updater.isBusy)
        }
        if let note {
            Text(note)
        }
    }

    private var checkTitle: String {
        if updater.status == .checking { return "Checking for Updates…" }
        if updater.status == .downloading { return "Downloading Update…" }
        return "Check for Updates…"
    }

    private var note: String? {
        if case .upToDate(let version) = updater.status { return "Tape \(version) is the latest version." }
        if case .blocked(let message) = updater.status { return message }
        if case .failed(let message) = updater.status { return message }
        return nil
    }
}

// MenuBarExtra flattens its label to plain title text, so the glyph and time are drawn into one template image.
@MainActor
func menuBarImage(phase: Recorder.Phase, elapsed: Int) -> NSImage {
    let font = NSFont.menuBarFont(ofSize: 0)
    let isIdle = phase == .idle || phase == .starting
    let symbol = NSImage(systemSymbolName: isIdle ? "record.circle" : "record.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium))
    let title = NSAttributedString(
        string: isIdle ? "" : ElapsedTime.clock(elapsed),
        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)]
    )
    let symbolSize = symbol?.size ?? .zero
    let titleSize = isIdle ? .zero : title.size()
    let gap: CGFloat = isIdle ? 0 : 4
    let height = max(symbolSize.height, titleSize.height).rounded(.up)
    let size = NSSize(width: (symbolSize.width + gap + titleSize.width).rounded(.up), height: height)
    let image = NSImage(size: size, flipped: false) { _ in
        symbol?.draw(in: NSRect(x: 0, y: (height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
        title.draw(at: NSPoint(x: symbolSize.width + gap, y: (height - titleSize.height) / 2))
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = switch phase {
    case .idle: "Tape"
    case .starting: "Tape, starting"
    case .recording: "Tape, recording, \(ElapsedTime.spoken(elapsed))"
    case .stopping: "Tape, saving"
    }
    return image
}

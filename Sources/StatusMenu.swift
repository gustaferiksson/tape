import AppKit
import SwiftUI
import TapeCore

@MainActor @Observable
final class MenuHighlight {
    var item: NSUserInterfaceItemIdentifier?
}

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let width: CGFloat = 300
    static let recordItem = NSUserInterfaceItemIdentifier("record")
    static let reduceEchoItem = NSUserInterfaceItemIdentifier("reduceEcho")

    private static let dateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // Drawn per appearance, so the neutral fill follows light and dark.
    private static let recentBadge = NSImage(size: NSSize(width: 28, height: 28), flipped: false) { @Sendable rect in
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(ovalIn: rect).fill()
        guard let glyph = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.labelColor])))
        else { return true }
        glyph.draw(in: NSRect(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height))
        return true
    }

    let menu = NSMenu()
    let highlight = MenuHighlight()
    private let recorder: Recorder
    private let settings: AppSettings
    private let updater: AppUpdater
    private let recent: RecentRecordings
    private var statusItem: NSStatusItem?

    init(recorder: Recorder, settings: AppSettings, updater: AppUpdater, recent: RecentRecordings) {
        self.recorder = recorder
        self.settings = settings
        self.updater = updater
        self.recent = recent
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = Self.width
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item
        Task { [recorder] in
            for await (phase, elapsed) in Observations({ (recorder.phase, recorder.elapsed) }) {
                item.button?.image = menuBarImage(phase: phase, elapsed: elapsed)
            }
        }
        Task { [recorder, recent] in
            for await _ in Observations({ recorder.isActive }) {
                recent.refresh()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        recorder.refreshPermissions()
        recent.refresh()
        rebuild()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        highlight.item = item?.identifier
    }

    func menuDidClose(_ menu: NSMenu) {
        highlight.item = nil
    }

    func rebuild() {
        let isActive = recorder.isActive
        var items = [recordItem()]
        if let notice = recorder.notice {
            let item = viewItem(NSHostingView(rootView: NoticeRow(notice: notice)))
            item.title = notice.text
            items.append(item)
            if let pane = notice.privacyPane {
                items.append(actionItem("Open Privacy Settings…", #selector(openPrivacySettings), value: pane.url))
            }
        }
        items += [reduceEchoItem(), .separator(), .sectionHeader(title: "Recent")]
        if let recordings = recent.items {
            items += recordings.isEmpty ? [disabledItem("No recordings yet.")] : recordings.map(recentItem)
        }
        items += [actionItem("Show All Recordings…", #selector(openRecordingsFolder)), .separator()]
        if let staged = updater.staged {
            let install = actionItem(isActive ? "Tape \(staged.version) installs after recording" : "Install Tape \(staged.version) and Relaunch", #selector(installUpdate))
            install.isEnabled = !isActive
            items.append(install)
        }
        items += [
            actionItem("Tape Settings…", #selector(openSettings), key: ","),
            actionItem(isActive ? "Stop and Quit Tape" : "Quit Tape", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp),
        ]
        menu.items = items
    }

    private func recordItem() -> NSMenuItem {
        let item = viewItem(MenuRowHostingView(rootView: RecordRow(recorder: recorder, highlight: highlight)))
        item.identifier = Self.recordItem
        item.title = recorder.startedAt == nil ? "Record Audio" : "Stop Recording"
        item.target = self
        item.action = #selector(toggleRecording)
        item.isEnabled = recorder.startedAt == nil ? recorder.phase == .idle : recorder.isRecording
        return item
    }

    private func reduceEchoItem() -> NSMenuItem {
        let item = viewItem(MenuRowHostingView(rootView: ReduceEchoRow(settings: settings, recorder: recorder, highlight: highlight)))
        item.identifier = Self.reduceEchoItem
        item.title = "Reduce Echo"
        item.target = self
        item.action = #selector(toggleReduceEcho)
        item.isEnabled = recorder.phase == .idle
        return item
    }

    private func recentItem(_ recording: RecentRecordings.Item) -> NSMenuItem {
        let item = actionItem(Self.dateFormatter.string(from: recording.startedAt), #selector(revealRecording), value: recording.url)
        item.subtitle = recording.duration.map(ElapsedTime.clock)
        item.image = Self.recentBadge
        if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
        item.toolTip = "Show in Finder"
        return item
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        view.setFrameSize(view.fittingSize)
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil, value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        item.representedObject = value
        // macOS assigns symbols to items like Settings… and Quit, and 27 shows only some of them; Wi-Fi's menu shows none.
        if #available(macOS 27, *) { item.preferredImageVisibility = .hidden }
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleRecording() {
        menu.cancelTracking()
        if recorder.startedAt == nil {
            Task { await recorder.start() }
        } else if recorder.elapsed > 0 {
            Task { await recorder.stop() }
        }
    }

    @objc private func toggleReduceEcho() {
        guard recorder.phase == .idle else { return }
        settings.reducesEcho.toggle()
    }

    @objc private func revealRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, FileManager.default.fileExists(atPath: url.path) else { return recent.refresh() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openPrivacySettings(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openRecordingsFolder() {
        let folder = FileManager.default.fileExists(atPath: settings.saveFolder.path) ? settings.saveFolder : AppSettings.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func installUpdate() {
        updater.installAndRelaunch()
    }

    @objc private func openSettings() {
        showSettingsWindow()
    }
}

// Custom menu item views get mouse events but no action; sending it here matches a standard item's click.
private final class MenuRowHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, item.isEnabled, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

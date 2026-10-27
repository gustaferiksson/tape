import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updater = AppUpdater()
    let recorder = Recorder(settings: .shared)
    private(set) lazy var recent = RecentRecordings(settings: .shared, recorder: recorder)
    private lazy var statusMenu = StatusMenu(recorder: recorder, settings: .shared, updater: updater, recent: recent)
    private var observers: [NSObjectProtocol] = []
    private lazy var recordingWindow: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: RecordingView(recorder: recorder)))
        window.styleMask = [.titled, .closable]
        window.title = "Tape"
        window.identifier = RecordingView.windowID
        window.isReleasedWhenClosed = false
        return window
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let output = SettingsSnapshot.output {
            Task { await SettingsSnapshot.capture(to: output, updater: updater) }
            return
        }
        if let output = LabelSnapshot.output {
            Task { await LabelSnapshot.capture(to: output, recorder: recorder) }
            return
        }
        if let output = MenuSnapshot.output {
            Task { await MenuSnapshot.capture(to: output, recorder: recorder, updater: updater, recent: recent) }
            return
        }
        #endif
        statusMenu.install()
        updater.isInstallBlocked = { [recorder] in recorder.isActive }
        updater.start()
        Task { await recorder.recoverInterruptedRecording() }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [recorder] _ in
                Task { @MainActor in await recorder.stop(reason: .sleep) }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [recorder] _ in
                MainActor.assumeIsolated { recorder.refreshPermissions() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [recorder] _ in
                MainActor.assumeIsolated { recorder.refreshPermissions() }
            },
        ]
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.isActive else { return .terminateNow }
        Task { [recorder] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await recorder.stop()
                    while await recorder.isActive { try? await Task.sleep(for: .milliseconds(50)) }
                }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        updater.installOnQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if recorder.isActive {
            NSApp.activate()
            if !recordingWindow.isVisible { recordingWindow.center() }
            recordingWindow.makeKeyAndOrderFront(nil)
            return true
        }
        showSettingsWindow()
        return true
    }
}

// SwiftUI rejects showSettingsWindow: sent from code ("use SettingsLink") but honours its own app-menu item.
@MainActor
func showSettingsWindow() {
    guard let menu = NSApp.mainMenu?.items.first?.submenu,
          let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," })
    else { return }
    NSApp.activate()
    menu.performActionForItem(at: index)
}

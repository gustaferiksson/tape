import ServiceManagement
import SwiftUI

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    @Environment(AppUpdater.self) private var updater
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var folderError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    Menu {
                        Button("Choose…", action: chooseFolder)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.saveFolder])
                        }
                        if settings.customFolder != nil {
                            Divider()
                            Button("Use Tape (Movies)") {
                                settings.customFolder = nil
                                folderError = nil
                            }
                        }
                    } label: {
                        Label("\(settings.saveFolder.lastPathComponent) (\(settings.saveFolder.deletingLastPathComponent().lastPathComponent))", systemImage: "folder")
                    }
                    .fixedSize()
                }
                if let folderError {
                    Text(folderError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Recordings")
            } footer: {
                Text("Applies from the next recording.")
            }

            Section {
                Toggle(isOn: $settings.reducesEcho) {
                    Text("Reduce Echo")
                    Text("Removes other people’s voices from your microphone when you’re on speakers. Experimental.")
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Applies from the next recording.")
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin
                ))
                if loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Approval needed")
                        Text("Allow Tape in System Settings to finish turning this on.")
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Updates") {
                LabeledContent("Version", value: AppUpdater.currentVersion)
                HStack(spacing: 8) {
                    updateStatus
                    Spacer()
                    if updater.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(updater.status == .checking ? "Checking" : "Downloading")
                    }
                    if let staged = updater.staged {
                        Button("Install Tape \(staged.version) and Relaunch", action: updater.installAndRelaunch)
                    } else {
                        Button("Check for Updates") { updater.check(.manual) }
                            .disabled(updater.isBusy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 496)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    @ViewBuilder private var updateStatus: some View {
        if updater.status == .checking {
            Text("Checking for updates…").font(.callout).foregroundStyle(.secondary)
        } else if updater.status == .downloading {
            Text("Downloading the update…").font(.callout).foregroundStyle(.secondary)
        } else if case .upToDate(let version) = updater.status {
            Text("Tape \(version) is the latest version.").font(.callout).foregroundStyle(.secondary)
        } else if case .ready(let version) = updater.status {
            Text("Tape \(version) is ready to install.").font(.callout)
        } else if case .blocked(let message) = updater.status {
            Text(message).font(.callout).foregroundStyle(.orange)
        } else if case .failed(let message) = updater.status {
            Text(message).font(.callout).foregroundStyle(.red)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let probe = folder.appending(path: ".tape-write-test-\(UUID().uuidString)")
        guard (try? Data().write(to: probe)) != nil else {
            folderError = "Tape can’t save to “\(folder.lastPathComponent)”. Choose another folder."
            return
        }
        try? FileManager.default.removeItem(at: probe)
        folderError = nil
        settings.customFolder = folder == AppSettings.defaultFolder ? nil : folder
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        do {
            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn’t change Launch at login: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}

import SwiftUI
import TapeCore

struct TapePanel: View {
    let recorder: Recorder
    let settings: AppSettings
    let updater: AppUpdater
    let recent: RecentRecordings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(alignment: .leading, spacing: 12) {
                RecordButton(recorder: recorder)
                details
            }
            reduceEcho
            RecentSection(recent: recent)
            updateRow
        }
        .padding([.horizontal, .bottom], 16)
        .padding(.top, 8)
        .frame(width: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
        .containerBackground(.clear, for: .window)
        .background { shortcuts }
        .onExitCommand { NSApp.keyWindow?.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in recent.refresh() }
        .onChange(of: recorder.isActive) { recent.refresh() }
        .task { recent.refresh() }
    }

    private var header: some View {
        HStack {
            Text("Tape").font(.headline)
            Spacer()
            Menu {
                Button("Settings…", action: showSettings).keyboardShortcut(",")
                Button("Open Recordings Folder", action: openFolder)
                Divider()
                UpdateMenuItems(updater: updater, isRecording: recorder.isActive)
                Divider()
                Button(recorder.isActive ? "Stop and Quit Tape" : "Quit Tape") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .frame(height: 24)
        .padding(.trailing, -6)
    }

    @ViewBuilder private var details: some View {
        if let since = recorder.startedAt {
            VStack(alignment: .leading, spacing: 4) {
                Label("Recording audio · since \(since.formatted(date: .omitted, time: .shortened))\(recorder.isSavingToFallback ? " · saving to Movies › Tape" : "")", systemImage: "waveform")
                Label(recorder.microphoneName.map { "Microphone: \($0)" } ?? "Microphone unavailable", systemImage: recorder.microphoneName == nil ? "mic.slash" : "mic")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if let notice = recorder.notice {
            NoticeLine(notice: notice)
        }
    }

    private var reduceEcho: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reduce Echo")
                if recorder.phase != .idle {
                    Text("Applies from the next recording.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Reduce Echo", isOn: Bindable(settings).reducesEcho)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(recorder.phase != .idle)
                .accessibilityHint(recorder.phase == .idle ? "" : "Applies from the next recording.")
        }
    }

    @ViewBuilder private var updateRow: some View {
        if let staged = updater.staged {
            Divider()
            HStack(spacing: 12) {
                Text(recorder.isActive ? "Tape \(staged.version) installs after recording." : "Tape \(staged.version) is ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Install and Relaunch", action: updater.installAndRelaunch)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(recorder.isActive)
            }
        }
    }

    private var shortcuts: some View {
        ZStack {
            Button("Settings…", action: showSettings).keyboardShortcut(",")
            Button("Quit Tape") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func showSettings() {
        NSApp.keyWindow?.close()
        showSettingsWindow()
    }

    private func openFolder() {
        let folder = FileManager.default.fileExists(atPath: settings.saveFolder.path) ? settings.saveFolder : AppSettings.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

private struct RecordButton: View {
    let recorder: Recorder

    var body: some View {
        if recorder.startedAt == nil {
            Button { Task { await recorder.start() } } label: {
                Label(recorder.phase == .starting ? "Starting…" : "Record Audio", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(recorder.phase == .starting)
        } else {
            Button { Task { await recorder.stop() } } label: {
                HStack {
                    Label(recorder.isRecording ? "Stop Recording" : "Saving…", systemImage: "stop.fill")
                    Spacer()
                    Text(ElapsedTime.clock(recorder.elapsed)).monospacedDigit()
                }
                .frame(minHeight: 24)
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(!recorder.isRecording)
            .accessibilityLabel(recorder.isRecording ? "Stop Recording" : "Saving")
            .accessibilityValue(ElapsedTime.spoken(recorder.elapsed))
        }
    }
}

private struct NoticeLine: View {
    let notice: Notice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(notice.text, systemImage: symbol)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let pane = notice.privacyPane {
                Button("Open Privacy Settings…") { NSWorkspace.shared.open(pane.url) }
                    .buttonStyle(.link)
                    .padding(.leading, 24)
            }
        }
        .font(.callout)
    }

    private var symbol: String {
        if case .recovered = notice { return "info.circle" }
        if case .fellBack = notice { return "info.circle" }
        return "exclamationmark.triangle"
    }
}

private struct RecentSection: View {
    let recent: RecentRecordings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            if let items = recent.items {
                if items.isEmpty {
                    Text("No recordings yet.")
                        .foregroundStyle(.secondary)
                        .frame(height: 28)
                }
                VStack(spacing: 0) {
                    ForEach(items) { RecentRow(item: $0, recent: recent) }
                }
                .padding(.horizontal, -8)
            }
        }
    }
}

private struct RecentRow: View {
    private static let dateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    let item: RecentRecordings.Item
    let recent: RecentRecordings
    @State private var isHovered = false

    var body: some View {
        Button(action: reveal) {
            HStack(spacing: 8) {
                Text(Self.dateFormatter.string(from: item.startedAt))
                Spacer(minLength: 8)
                if let duration = item.duration {
                    Text(ElapsedTime.clock(duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect)
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .draggable(item.url)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder", action: reveal)
        }
        .help("Show in Finder")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([Self.dateFormatter.string(from: item.startedAt), item.duration.map(ElapsedTime.spoken)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows the recording in Finder")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open") { NSWorkspace.shared.open(item.url) }
    }

    private func reveal() {
        guard FileManager.default.fileExists(atPath: item.url.path) else { return recent.refresh() }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}

struct UpdateMenuItems: View {
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

import AVFoundation
import AppKit
import SwiftUI
import TapeCore

@MainActor @Observable
final class Recorder {
    enum Phase: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case stopping(since: Date)
    }

    private static let minimumFreeBytesToStart: Int64 = 500_000_000
    private static let minimumFreeBytesWhileRecording: Int64 = 200_000_000

    private(set) var phase = Phase.idle
    private(set) var elapsed = 0
    private(set) var notice: Notice?
    private(set) var microphoneName: String?
    private(set) var isSavingToFallback = false
    private(set) var lastRecording: URL? {
        didSet { settings.store.set(lastRecording?.path, forKey: "lastRecording") }
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var session: CaptureSession?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var lastDiskCheck = Date.distantPast
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var recordingVolume = ""
    @ObservationIgnored private var fallbackFrom: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?

    var isActive: Bool {
        if case .recording = phase { return true }
        if case .stopping = phase { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var startedAt: Date? {
        if case .recording(let since) = phase { return since }
        if case .stopping(let since) = phase { return since }
        return nil
    }

    init(settings: AppSettings) {
        self.settings = settings
        lastRecording = settings.store.string(forKey: "lastRecording").map { URL(filePath: $0) }
    }

    func start() async {
        guard phase == .idle else { return }
        let microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneAccess == .denied || microphoneAccess == .restricted {
            notice = .microphoneDenied
            NSWorkspace.shared.open(PrivacyPane.microphone.url)
            return
        }
        phase = .starting
        if microphoneAccess == .notDetermined, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            notice = .microphoneDenied
            phase = .idle
            return
        }

        let folder = writableFolder()
        guard let space = Self.freeSpace(at: folder), space.bytes >= Self.minimumFreeBytesToStart else {
            notice = .notEnoughSpace(volume: Self.freeSpace(at: folder)?.volume ?? folder.lastPathComponent)
            phase = .idle
            return
        }
        let url = RecordingFile.url(in: folder, startedAt: .now, fileExtension: "m4a") { FileManager.default.fileExists(atPath: $0.path) }
        settings.store.set(["path": url.path, "pid": Int(getpid())], forKey: "inProgressRecording")
        let id = UUID()
        sessionID = id
        let session = try? CaptureSession(url: url, probesTap: settings.store.bool(forKey: "systemAudioConfirmed")) { [weak self] event in
            Task { @MainActor in self?.handle(event, from: id) }
        }
        guard let session, (try? await session.start()) != nil else {
            sessionID = nil
            _ = await session?.finish()
            try? FileManager.default.removeItem(at: url)
            settings.store.removeObject(forKey: "inProgressRecording")
            notice = .stopped(.audioFailed)
            phase = .idle
            return
        }

        self.session = session
        recordingURL = url
        recordingVolume = space.volume
        notice = nil
        elapsed = 0
        let since = Date.now
        phase = .recording(since: since)
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Recording a call")
        lastDiskCheck = .now
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(since: since) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        AccessibilityNotification.Announcement("Recording started").post()
    }

    func stop(reason: StopReason? = nil) async {
        guard case .recording(let since) = phase, let session, let url = recordingURL else { return }
        phase = .stopping(since: since)
        timer?.invalidate()
        let hadSystemAudio = await session.finish()
        if hadSystemAudio { settings.store.set(true, forKey: "systemAudioConfirmed") }
        lastRecording = url
        notice = reason.map(Notice.stopped)
            ?? fallbackFrom.map { Notice.fellBack(folder: $0) }
            ?? (!hadSystemAudio && elapsed >= 60 ? .noSystemAudio : nil)
        finishCleanup()
        AccessibilityNotification.Announcement(reason.map { Notice.stopped($0).text } ?? "Recording saved").post()
    }

    func recoverInterruptedRecording() async {
        guard let marker = settings.store.dictionary(forKey: "inProgressRecording"), let path = marker["path"] as? String else { return }
        if let pid = marker["pid"] as? Int, pid != Int(getpid()),
           NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        settings.store.removeObject(forKey: "inProgressRecording")
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 4096 {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let duration = try? await AVURLAsset(url: url).load(.duration), duration.seconds < 1 {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard phase == .idle else { return }
        lastRecording = url
        notice = .recovered(name: RecordingFile.displayName(of: url))
    }

    func refreshPermissions() {
        guard notice == .microphoneDenied, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        notice = nil
    }

    #if DEBUG
    func simulateRecording(since: Date, microphone: String) {
        phase = .recording(since: since)
        elapsed = Int(Date.now.timeIntervalSince(since))
        microphoneName = microphone
    }
    #endif

    private func handle(_ event: CaptureEvent, from id: UUID) {
        guard id == sessionID else { return }
        if case .microphone(let name) = event {
            microphoneName = name
            return
        }
        if event == .systemAudioDenied {
            Task { await stopForDeniedSystemAudio() }
            return
        }
        Task { await stop(reason: event == .deviceFailed ? .audioFailed : failureReason()) }
    }

    private func stopForDeniedSystemAudio() async {
        guard let url = recordingURL else { return }
        await stop()
        if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 4096 { try? FileManager.default.removeItem(at: url) }
        notice = .systemAudioDenied
    }

    private func finishCleanup() {
        settings.store.removeObject(forKey: "inProgressRecording")
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        timer = nil
        session = nil
        sessionID = nil
        recordingURL = nil
        fallbackFrom = nil
        isSavingToFallback = false
        microphoneName = nil
        phase = .idle
    }

    private func tick(since: Date) {
        guard case .recording = phase else { return }
        elapsed = Int(Date.now.timeIntervalSince(since))
        guard Date.now.timeIntervalSince(lastDiskCheck) >= 30, let folder = recordingURL?.deletingLastPathComponent() else { return }
        lastDiskCheck = .now
        guard FileManager.default.fileExists(atPath: folder.path), let space = Self.freeSpace(at: folder) else {
            Task { await stop(reason: failureReason()) }
            return
        }
        guard space.bytes < Self.minimumFreeBytesWhileRecording else { return }
        Task { await stop(reason: .diskFull(volume: space.volume)) }
    }

    private func failureReason() -> StopReason {
        guard let folder = recordingURL?.deletingLastPathComponent(), FileManager.default.fileExists(atPath: folder.path) else {
            return .volumeDisconnected(volume: recordingVolume)
        }
        if let space = Self.freeSpace(at: folder), space.bytes < Self.minimumFreeBytesWhileRecording { return .diskFull(volume: space.volume) }
        return .writeFailed
    }

    private func writableFolder() -> URL {
        let fileManager = FileManager.default
        fallbackFrom = nil
        isSavingToFallback = false
        if let custom = settings.customFolder {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: custom.path, isDirectory: &isDirectory), isDirectory.boolValue, fileManager.isWritableFile(atPath: custom.path) {
                return custom
            }
            fallbackFrom = custom.lastPathComponent
            isSavingToFallback = true
        }
        try? fileManager.createDirectory(at: AppSettings.defaultFolder, withIntermediateDirectories: true)
        return AppSettings.defaultFolder
    }

    private static func freeSpace(at folder: URL) -> (bytes: Int64, volume: String)? {
        guard let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (bytes, values.volumeLocalizedName ?? folder.lastPathComponent)
    }
}

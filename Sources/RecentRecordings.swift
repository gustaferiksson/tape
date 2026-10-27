import AVFoundation
import Observation
import TapeCore

@MainActor @Observable
final class RecentRecordings {
    struct Item: Identifiable, Equatable, Sendable {
        let url: URL
        let startedAt: Date
        let duration: Int?

        var id: URL { url }
    }

    private struct CachedDuration: Sendable {
        let modified: Date
        let seconds: Int
    }

    nonisolated private static let limit = 3

    private(set) var items: [Item]?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let recorder: Recorder
    @ObservationIgnored private var durations: [URL: CachedDuration] = [:]
    @ObservationIgnored private var scan: Task<Void, Never>?

    init(settings: AppSettings, recorder: Recorder) {
        self.settings = settings
        self.recorder = recorder
    }

    func refresh() {
        #if DEBUG
        if MenuSnapshot.output != nil { return }
        #endif
        scan?.cancel()
        let folder = settings.saveFolder, last = recorder.lastRecording, cache = durations
        let current = recorder.phase == .idle ? nil : (settings.store.dictionary(forKey: "inProgressRecording")?["path"] as? String).map { URL(filePath: $0) }
        scan = Task {
            let (items, durations) = await Self.scan(folder: folder, including: last, excluding: current, cache: cache)
            guard !Task.isCancelled else { return }
            self.items = items
            self.durations = durations
        }
    }

    #if DEBUG
    func simulate(_ items: [Item]) {
        self.items = items
    }
    #endif

    @concurrent nonisolated private static func scan(folder: URL, including last: URL?, excluding current: URL?, cache: [URL: CachedDuration]) async -> ([Item], [URL: CachedDuration]) {
        let listed = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        let candidates = Set((listed + [last].compactMap { $0 }).map(\.standardizedFileURL)).subtracting([current?.standardizedFileURL].compactMap { $0 })
        let newest = candidates
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .lazy
            .compactMap { url in RecordingFile.startDate(of: url).map { (url: url, startedAt: $0) } }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .prefix(limit)
        var items: [Item] = []
        var durations: [URL: CachedDuration] = [:]
        for (url, startedAt) in newest {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let cached = cache[url].flatMap { $0.modified == modified ? $0.seconds : nil }
            let loaded = if let cached { cached } else { try? await Int(AVURLAsset(url: url).load(.duration).seconds.rounded()) }
            if let loaded { durations[url] = CachedDuration(modified: modified, seconds: loaded) }
            items.append(Item(url: url, startedAt: startedAt, duration: loaded))
        }
        return (items, durations)
    }
}

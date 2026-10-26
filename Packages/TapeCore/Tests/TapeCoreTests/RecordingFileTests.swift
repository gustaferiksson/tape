import Foundation
import Testing
@testable import TapeCore

struct RecordingFileTests {
    let folder = URL(filePath: "/Users/me/Movies/Tape", directoryHint: .isDirectory)
    let start = Date(timeIntervalSince1970: 1_793_023_385)
    let utc = TimeZone(identifier: "UTC")!

    @Test func namesAfterStartTime() {
        let url = RecordingFile.url(in: folder, startedAt: start, fileExtension: "m4a", timeZone: utc) { _ in false }
        #expect(url.path == "/Users/me/Movies/Tape/Tape 2026-10-26 at 14.03.05.m4a")
        #expect(RecordingFile.displayName(of: url) == "Tape 2026-10-26 at 14.03.05")
    }

    @Test func appendsNumberOnCollision() {
        let taken: Set = ["Tape 2026-10-26 at 14.03.05.m4a", "Tape 2026-10-26 at 14.03.05 2.m4a"]
        let url = RecordingFile.url(in: folder, startedAt: start, fileExtension: "m4a", timeZone: utc) { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "Tape 2026-10-26 at 14.03.05 3.m4a")
    }

    @Test func usesTwentyFourHourClockRegardlessOfLocale() {
        let evening = start.addingTimeInterval(8 * 3600)
        let url = RecordingFile.url(in: folder, startedAt: evening, fileExtension: "m4a", timeZone: utc) { _ in false }
        #expect(url.lastPathComponent == "Tape 2026-10-26 at 22.03.05.m4a")
    }
}

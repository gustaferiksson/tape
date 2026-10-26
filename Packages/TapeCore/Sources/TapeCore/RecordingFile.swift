import Foundation

public enum RecordingFile {
    public static func url(in folder: URL, startedAt date: Date, fileExtension: String, timeZone: TimeZone = .current, exists: (URL) -> Bool) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Tape \(formatter.string(from: date))"
        return (1...).lazy
            .map { folder.appending(path: "\($0 == 1 ? base : "\(base) \($0)").\(fileExtension)", directoryHint: .notDirectory) }
            .first { !exists($0) }!
    }

    public static func displayName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

import Foundation

public enum RecordingFile {
    public static func url(in folder: URL, startedAt date: Date, fileExtension: String, timeZone: TimeZone = .current, exists: (URL) -> Bool) -> URL {
        let base = "Tape \(formatter(timeZone).string(from: date))"
        return (1...).lazy
            .map { folder.appending(path: "\($0 == 1 ? base : "\(base) \($0)").\(fileExtension)", directoryHint: .notDirectory) }
            .first { !exists($0) }!
    }

    public static func displayName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    public static func startDate(of url: URL, timeZone: TimeZone = .current) -> Date? {
        guard ["m4a", "mov"].contains(url.pathExtension.lowercased()) else { return nil }
        let name = displayName(of: url)
        guard name.hasPrefix("Tape ") else { return nil }
        let stamp = name.dropFirst(5).prefix(22)
        let suffix = name.dropFirst(5 + stamp.count)
        guard suffix.isEmpty || (suffix.first == " " && suffix.dropFirst().allSatisfy(\.isNumber) && suffix.count > 1) else { return nil }
        return formatter(timeZone).date(from: String(stamp))
    }

    private static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }
}

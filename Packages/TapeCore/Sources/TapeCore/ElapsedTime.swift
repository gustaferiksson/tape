public enum ElapsedTime {
    public static func clock(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        let paddedSeconds = rest < 10 ? "0\(rest)" : "\(rest)"
        guard hours > 0 else { return "\(minutes):\(paddedSeconds)" }
        return "\(hours):\(minutes < 10 ? "0\(minutes)" : "\(minutes)"):\(paddedSeconds)"
    }

    public static func spoken(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes == 0 { return "under a minute" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

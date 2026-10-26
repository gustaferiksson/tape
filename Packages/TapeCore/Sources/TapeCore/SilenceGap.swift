public enum SilenceGap {
    public static func frames(expectedSeconds: Double, actualSeconds: Double, sampleRate: Double, tolerance: Double = 0.05, cap: Double = 600) -> Int {
        let gap = actualSeconds - expectedSeconds
        guard gap > tolerance else { return 0 }
        return Int((min(gap, cap) * sampleRate).rounded())
    }
}

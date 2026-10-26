// Mixes the tap's stream with a microphone on another clock, both at `sampleRate`. Frame indices are absolute output frames.
public struct AlignedMix {
    public let sampleRate: Double
    private let maxMicLag: Int
    private let micBacklog: Int
    private let jumpFrames: Int
    private let deadbandFrames: Double
    private let smoothing: Double
    private var system: [Float] = []
    private var mic: [Float] = []
    private var micStart = 0
    private var written = 0
    private var anchor: (host: Double, frame: Int)?
    private var smoothedError = 0.0

    public init(sampleRate: Double, maxMicLagSeconds: Double = 0.5, micBacklogSeconds: Double = 60, jumpSeconds: Double = 0.05, deadbandSeconds: Double = 0.001, smoothing: Double = 0.05) {
        self.sampleRate = sampleRate
        maxMicLag = Int(maxMicLagSeconds * sampleRate)
        micBacklog = Int(micBacklogSeconds * sampleRate)
        jumpFrames = Int(jumpSeconds * sampleRate)
        deadbandFrames = deadbandSeconds * sampleRate
        self.smoothing = smoothing
    }

    public var systemEnd: Int { written + system.count }
    public var micEnd: Int { micStart + mic.count }

    public mutating func appendSystem(_ samples: [Float], hostSeconds: Double) {
        anchor = (hostSeconds, systemEnd)
        system += samples
    }

    public mutating func appendMic(_ samples: [Float], hostSeconds: Double) {
        guard let anchor, !samples.isEmpty else { return }
        let target = anchor.frame + Int(((hostSeconds - anchor.host) * sampleRate).rounded())
        let correction = correction(for: target - micEnd)
        if correction > micBacklog || (correction > 0 && mic.isEmpty) {
            micStart = micEnd + correction
            mic = []
        } else if correction > 0 {
            mic += repeatElement(correction == 1 ? samples[0] : 0, count: correction)
        }
        mic += samples.dropFirst(max(0, -correction))
        let excess = mic.count - micBacklog
        guard excess > 0 else { return }
        mic.removeFirst(excess)
        micStart += excess
    }

    public mutating func take(flush: Bool = false) -> [Float] {
        let limit = flush ? systemEnd : min(systemEnd, max(micEnd, systemEnd - maxMicLag))
        guard limit > written else { return [] }
        var output = Array(system.prefix(limit - written))
        system.removeFirst(output.count)
        for frame in stride(from: max(written, micStart), to: min(limit, micEnd), by: 1) {
            output[frame - written] += mic[frame - micStart]
        }
        let used = min(mic.count, max(0, limit - micStart))
        mic.removeFirst(used)
        micStart += used
        written = limit
        return output
    }

    private mutating func correction(for error: Int) -> Int {
        guard abs(error) <= jumpFrames else {
            smoothedError = 0
            return error
        }
        smoothedError += smoothing * (Double(error) - smoothedError)
        guard abs(smoothedError) >= deadbandFrames else { return 0 }
        let step = smoothedError > 0 ? 1 : -1
        smoothedError -= Double(step)
        return step
    }
}

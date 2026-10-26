public struct InterleavedStream {
    public let samples: UnsafeBufferPointer<Float>
    public let channels: Int

    public init(samples: UnsafeBufferPointer<Float>, channels: Int) {
        self.samples = samples
        self.channels = channels
    }
}

public enum Mixer {
    public static func mix(_ streams: [InterleavedStream], frames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frames)
        for stream in streams where stream.channels > 0 {
            let available = min(frames, stream.samples.count / stream.channels)
            let scale = 1 / Float(stream.channels)
            for frame in 0..<available {
                let start = frame * stream.channels
                output[frame] += stream.samples[start..<start + stream.channels].reduce(0, +) * scale
            }
        }
        return output
    }
}

public struct PeakLimiter: Sendable {
    public let ceiling: Float
    private let release: Float
    public private(set) var gain: Float = 1

    public init(sampleRate: Double, ceiling: Float = 0.98, releaseSeconds: Double = 0.25) {
        self.ceiling = ceiling
        release = Float(1 / (releaseSeconds * sampleRate))
    }

    public mutating func process(_ samples: inout [Float]) {
        for index in samples.indices {
            let peak = abs(samples[index])
            let allowed = peak > ceiling ? ceiling / peak : 1
            gain = allowed < gain ? allowed : min(allowed, gain + release)
            samples[index] *= gain
        }
    }
}

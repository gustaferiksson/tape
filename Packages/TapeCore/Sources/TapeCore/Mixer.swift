public struct InterleavedStream {
    public let samples: UnsafeBufferPointer<Float>
    public let channels: Int

    public init(samples: UnsafeBufferPointer<Float>, channels: Int) {
        self.samples = samples
        self.channels = channels
    }
}

public enum Mixer {
    public static func addLoudestChannel(of stream: InterleavedStream, into output: UnsafeMutableBufferPointer<Float>) {
        guard stream.channels > 0 else { return }
        let frames = min(output.count, stream.samples.count / stream.channels)
        for frame in 0..<frames {
            var loudest: Float = 0
            for channel in 0..<stream.channels {
                let sample = stream.samples[frame * stream.channels + channel]
                if abs(sample) > abs(loudest) { loudest = sample }
            }
            output[frame] += loudest
        }
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

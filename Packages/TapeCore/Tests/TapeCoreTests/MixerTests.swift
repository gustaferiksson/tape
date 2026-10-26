import Foundation
import Testing
@testable import TapeCore

struct MixerTests {
    private func mix(_ streams: [([Float], Int)], frames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frames)
        output.withUnsafeMutableBufferPointer { out in
            for (samples, channels) in streams {
                samples.withUnsafeBufferPointer { Mixer.addLoudestChannel(of: InterleavedStream(samples: $0, channels: channels), into: out) }
            }
        }
        return output
    }

    @Test func silencePlusSignalIsSignal() {
        let signal: [Float] = [0.1, -0.2, 0.3]
        #expect(mix([([0, 0, 0], 1), (signal, 1)], frames: 3) == signal)
    }

    @Test func takesTheLoudestChannelSoMultichannelInterfacesKeepTheirLevel() {
        let eightChannels: [Float] = [0, 0, 0.5, 0, 0, 0, 0, 0.01] + [0, -0.4, 0, 0, 0, 0, 0, 0]
        #expect(mix([(eightChannels, 8)], frames: 2) == [0.5, -0.4])
    }

    @Test func sumsStreams() {
        let mixed = mix([([0.2, 0.4, -0.2, 0], 2), ([0.1, 0.1], 1)], frames: 2)
        #expect(abs(mixed[0] - 0.5) < 1e-6)
        #expect(abs(mixed[1] - -0.1) < 1e-6)
    }

    @Test func shortStreamLeavesTheRestUntouched() {
        #expect(mix([([0.5], 1)], frames: 3) == [0.5, 0, 0])
    }

    @Test func limiterKeepsTwoFullScaleInputsBelowCeiling() {
        var limiter = PeakLimiter(sampleRate: 48000)
        var samples = (0..<4800).map { index in 2 * sin(Float(index) * 0.05) }
        limiter.process(&samples)
        #expect(samples.allSatisfy { abs($0) <= limiter.ceiling + 1e-6 })
    }

    @Test func limiterPassesQuietSignalUnchanged() {
        var limiter = PeakLimiter(sampleRate: 48000)
        let quiet = (0..<480).map { index in 0.5 * sin(Float(index) * 0.05) }
        var samples = quiet
        limiter.process(&samples)
        #expect(samples == quiet)
    }

    @Test func limiterReleasesAfterPeak() {
        var limiter = PeakLimiter(sampleRate: 1000, releaseSeconds: 0.1)
        var peak: [Float] = [1.96]
        limiter.process(&peak)
        #expect(abs(limiter.gain - 0.5) < 1e-6)
        var quiet = [Float](repeating: 0.1, count: 200)
        limiter.process(&quiet)
        #expect(limiter.gain == 1)
    }
}

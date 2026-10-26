import Foundation
import Testing
@testable import TapeCore

struct MixerTests {
    @Test func silencePlusSignalIsSignal() {
        let silence: [Float] = [0, 0, 0]
        let signal: [Float] = [0.1, -0.2, 0.3]
        let mixed = silence.withUnsafeBufferPointer { a in
            signal.withUnsafeBufferPointer { b in
                Mixer.mix([InterleavedStream(samples: a, channels: 1), InterleavedStream(samples: b, channels: 1)], frames: 3)
            }
        }
        #expect(mixed == signal)
    }

    @Test func averagesChannelsWithinAStreamAndSumsStreams() {
        let stereo: [Float] = [0.2, 0.4, -0.2, 0]
        let mono: [Float] = [0.1, 0.1]
        let mixed = stereo.withUnsafeBufferPointer { a in
            mono.withUnsafeBufferPointer { b in
                Mixer.mix([InterleavedStream(samples: a, channels: 2), InterleavedStream(samples: b, channels: 1)], frames: 2)
            }
        }
        #expect(abs(mixed[0] - 0.4) < 1e-6)
        #expect(abs(mixed[1] - 0) < 1e-6)
    }

    @Test func shortStreamLeavesTheRestUntouched() {
        let short: [Float] = [0.5]
        let mixed = short.withUnsafeBufferPointer { Mixer.mix([InterleavedStream(samples: $0, channels: 1)], frames: 3) }
        #expect(mixed == [0.5, 0, 0])
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

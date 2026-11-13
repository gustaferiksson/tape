import Accelerate
import Foundation
import Testing
@testable import TapeCore

struct EchoCancellerTests {
    private static let rate = 48000.0
    private static let latency = [Float](repeating: 0, count: EchoCanceller.blockSize)

    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    private static func speech(seconds: Double, seed: UInt64) -> [Float] {
        var random = SeededRandom(state: seed)
        let phase = Double.random(in: 0..<1, using: &random)
        var lowPassed: Float = 0
        var samples: [Float] = []
        for index in 0..<Int(seconds * rate) {
            let time = Double(index) / rate + phase
            let talking = time.truncatingRemainder(dividingBy: 1.6) < 1.2
            let syllable = Float(0.5 - 0.5 * cos(2 * Double.pi * 4 * time))
            lowPassed = 0.95 * lowPassed + 0.05 * Float.random(in: -1...1, using: &random)
            samples.append(talking ? 2.4 * syllable * lowPassed : 0)
        }
        return samples
    }

    private static func echo(of far: [Float]) -> [Float] {
        var random = SeededRandom(state: 99)
        let delay = Int(0.05 * rate)
        let tail = Int(0.1 * rate)
        var path = [Float](repeating: 0, count: delay + tail)
        path[delay] = 0.2
        for tap in 1..<tail {
            path[delay + tap] = 0.05 * Float(exp(-Double(tap) / (0.025 * rate))) * Float.random(in: -1...1, using: &random)
        }
        var result = [Float](repeating: 0, count: far.count)
        vDSP_conv([Float](repeating: 0, count: path.count - 1) + far, 1, Array(path.reversed()), 1, &result, 1, vDSP_Length(far.count), vDSP_Length(path.count))
        return result
    }

    private static func run(_ canceller: EchoCanceller, microphone: [Float], reference: [Float]) -> [Float] {
        var output: [Float] = []
        for start in stride(from: 0, to: microphone.count, by: 480) {
            let end = min(start + 480, microphone.count)
            output += canceller.process(microphone: microphone[start..<end], reference: reference[start..<end])
        }
        return output
    }

    private static func doubleTalk() -> (near: [Float], echo: [Float], output: [Float]) {
        var far = speech(seconds: 12, seed: 3)
        for index in Int(5.5 * rate)..<Int(7.5 * rate) {
            far[index] = 0.003 * Float(sin(2 * Double.pi * 150 * Double(index) / rate))
        }
        let echo = echo(of: far)
        var near = [Float](repeating: 0, count: far.count)
        near.replaceSubrange(Int(5 * rate)..<Int(8 * rate), with: speech(seconds: 3, seed: 4))
        return (latency + near, latency + echo, run(EchoCanceller(sampleRate: rate), microphone: zip(echo, near).map(+), reference: far))
    }

    @Test func cancelsADelayedEchoWithATail() {
        let far = Self.speech(seconds: 8, seed: 1)
        let echo = Self.echo(of: far)
        let output = Self.run(EchoCanceller(sampleRate: Self.rate), microphone: echo, reference: far)
        let window = Int(5 * Self.rate)..<Int(8 * Self.rate)
        #expect(10 * log10(vDSP.sumOfSquares((Self.latency + echo)[window]) / vDSP.sumOfSquares(output[window])) >= 20)
    }

    @Test func keepsTheNearEndDuringDoubleTalk() {
        let (near, _, output) = Self.doubleTalk()
        let window = Int(5.2 * Self.rate)..<Int(8 * Self.rate)
        let nearEnergy = vDSP.sumOfSquares(near[window])
        let outputEnergy = vDSP.sumOfSquares(output[window])
        #expect(vDSP.dot(near[window], output[window]) / sqrt(nearEnergy * outputEnergy) > 0.99)
        #expect(abs(10 * log10(outputEnergy / nearEnergy)) < 1)
    }

    @Test func stillCancelsAfterDoubleTalk() {
        let (_, echo, output) = Self.doubleTalk()
        let window = Int(8.5 * Self.rate)..<Int(12 * Self.rate)
        #expect(10 * log10(vDSP.sumOfSquares(echo[window]) / vDSP.sumOfSquares(output[window])) >= 20)
    }

    @Test func passesTheNearEndThroughWhenTheReferenceIsSilent() {
        let near = Self.speech(seconds: 2, seed: 5)
        let output = Self.run(EchoCanceller(sampleRate: Self.rate), microphone: near, reference: [Float](repeating: 0, count: near.count))
        #expect(output == Array((Self.latency + near).prefix(near.count)))
    }

    @Test func returnsAsManyFramesAsItTakesAndFlushesTheRest() {
        let near = Self.speech(seconds: 1, seed: 6)
        let canceller = EchoCanceller(sampleRate: Self.rate)
        var output: [Float] = []
        var start = 0
        for size in [1, 7, 511, 512, 513, 1000, 3, 4096, 2] {
            let chunk = canceller.process(microphone: near[start..<start + size], reference: repeatElement(0, count: size))
            #expect(chunk.count == size)
            output += chunk
            start += size
        }
        let tail = canceller.flush()
        #expect(tail.count == EchoCanceller.blockSize)
        #expect(output + tail == Self.latency + near[0..<start])
    }
}

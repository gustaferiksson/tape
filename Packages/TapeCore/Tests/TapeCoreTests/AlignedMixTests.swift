import Testing
@testable import TapeCore

struct AlignedMixTests {
    private let rate = 48000.0

    @Test func dropsMicBeforeTheFirstSystemAnchor() {
        var mix = AlignedMix(sampleRate: rate)
        mix.appendMic([1, 1], hostSeconds: 0)
        mix.appendSystem([0, 0], hostSeconds: 0)
        #expect(mix.take(flush: true) == [0, 0])
    }

    @Test func placesMicByHostTime() {
        var mix = AlignedMix(sampleRate: 4, maxMicLagSeconds: 10, jumpSeconds: 0.1)
        mix.appendSystem([0, 0, 0, 0, 0, 0, 0, 0], hostSeconds: 10)
        mix.appendMic([1, 2], hostSeconds: 10.5)
        #expect(mix.take(flush: true) == [0, 0, 1, 2, 0, 0, 0, 0])
    }

    @Test func waitsForTheMicUpToTheLag() {
        var mix = AlignedMix(sampleRate: 10, maxMicLagSeconds: 0.5)
        mix.appendSystem([Float](repeating: 0.5, count: 20), hostSeconds: 0)
        #expect(mix.take().count == 15)
        mix.appendMic([0.25, 0.25, 0.25], hostSeconds: 1.5)
        #expect(mix.take() == [0.75, 0.75, 0.75])
        #expect(mix.take(flush: true) == [0.5, 0.5])
    }

    @Test func fillsAMicGapWithSilence() {
        var mix = AlignedMix(sampleRate: 10, maxMicLagSeconds: 10, jumpSeconds: 0.1)
        mix.appendSystem([Float](repeating: 0, count: 10), hostSeconds: 0)
        mix.appendMic([1, 1], hostSeconds: 0)
        mix.appendMic([1, 1], hostSeconds: 0.6)
        #expect(mix.take(flush: true) == [1, 1, 0, 0, 0, 0, 1, 1, 0, 0])
    }

    @Test func dropsMicThatArrivesAfterItsFramesWereWritten() {
        var mix = AlignedMix(sampleRate: 10, maxMicLagSeconds: 0.2)
        mix.appendSystem([Float](repeating: 0, count: 10), hostSeconds: 0)
        #expect(mix.take().count == 8)
        mix.appendMic([1, 1, 1, 1], hostSeconds: 0)
        #expect(mix.take(flush: true) == [0, 0])
    }

    @Test func followsAFastMicClockForAnHour() {
        #expect(abs(endOfHourOffset(micPPM: 100)) <= 96)
    }

    @Test func followsASlowMicClockForAnHour() {
        #expect(abs(endOfHourOffset(micPPM: -100)) <= 96)
    }

    // Returns how many frames a final mic impulse lands from where its host time says it belongs.
    private func endOfHourOffset(micPPM: Double) -> Int {
        var mix = AlignedMix(sampleRate: rate)
        let chunk = 4800
        let seconds = Double(chunk) / rate
        let micSeconds = seconds / (1 + micPPM / 1_000_000)
        var written = 0
        var micHost = 0.0
        var step = 0
        for index in 0..<36000 {
            let systemHost = Double(index) * seconds
            mix.appendSystem([Float](repeating: 0, count: chunk), hostSeconds: systemHost)
            while micHost < systemHost + seconds {
                let jitter = Double((step * 7919) % 11 - 5) / 10_000
                mix.appendMic([Float](repeating: 0, count: chunk), hostSeconds: micHost + jitter)
                micHost += micSeconds
                step += 1
            }
            written += mix.take().count
        }
        var impulse = [Float](repeating: 0, count: chunk)
        impulse[100] = 1
        mix.appendSystem([Float](repeating: 0, count: chunk * 4), hostSeconds: 36000 * seconds)
        mix.appendMic(impulse, hostSeconds: micHost)
        guard let landed = mix.take(flush: true).firstIndex(of: 1) else { return .max }
        return written + landed - 100 - Int((micHost * rate).rounded())
    }
}

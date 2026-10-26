import Testing
@testable import TapeCore

struct SilenceGapTests {
    @Test func noGapWhenOnTime() {
        #expect(SilenceGap.frames(expectedSeconds: 10, actualSeconds: 10.001, sampleRate: 48000) == 0)
    }

    @Test func ignoresEarlyOrOverlappingBuffers() {
        #expect(SilenceGap.frames(expectedSeconds: 10, actualSeconds: 9.5, sampleRate: 48000) == 0)
    }

    @Test func fillsADeviceSwitchGap() {
        #expect(SilenceGap.frames(expectedSeconds: 10, actualSeconds: 10.25, sampleRate: 48000) == 12000)
    }

    @Test func capsAbsurdGaps() {
        #expect(SilenceGap.frames(expectedSeconds: 0, actualSeconds: 1e9, sampleRate: 100, cap: 60) == 6000)
    }
}

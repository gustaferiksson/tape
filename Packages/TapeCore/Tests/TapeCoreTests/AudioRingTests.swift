import Foundation
import Testing
@testable import TapeCore

struct AudioRingTests {
    @Test func readsChunksInOrderWithTheirTiming() {
        let ring = AudioRing(slots: 4, framesPerSlot: 8)
        ring.write(hostSeconds: 1, sampleRate: 48000) { slot in
            slot[0] = 0.25
            return 1
        }
        ring.write(hostSeconds: 2, sampleRate: 24000) { slot in
            slot[0] = 0.5
            slot[1] = 0.75
            return 2
        }
        var seen: [(Double, Double, [Float])] = []
        while ring.read({ chunk, samples in seen.append((chunk.hostSeconds, chunk.sampleRate, Array(samples))) }) {}
        #expect(seen.map(\.0) == [1, 2])
        #expect(seen.map(\.1) == [48000, 24000])
        #expect(seen.map(\.2) == [[0.25], [0.5, 0.75]])
    }

    @Test func dropsWhenFullInsteadOfOverwriting() {
        let ring = AudioRing(slots: 2, framesPerSlot: 1)
        #expect(ring.write(hostSeconds: 0, sampleRate: 1) { _ in 1 })
        #expect(ring.write(hostSeconds: 1, sampleRate: 1) { _ in 1 })
        #expect(!ring.write(hostSeconds: 2, sampleRate: 1) { _ in 1 })
        #expect(ring.dropped == 1)
        var first: Double?
        ring.read { chunk, _ in first = chunk.hostSeconds }
        #expect(first == 0)
    }

    @Test func clampsFramesToTheSlot() {
        let ring = AudioRing(slots: 1, framesPerSlot: 4)
        ring.write(hostSeconds: 0, sampleRate: 1) { _ in 100 }
        var frames = 0
        ring.read { chunk, samples in frames = samples.count + chunk.frames }
        #expect(frames == 8)
    }

    @Test func survivesConcurrentProducerAndConsumer() async {
        let ring = AudioRing(slots: 8, framesPerSlot: 1)
        let total = 20_000
        let producer = Task.detached {
            var next = 0
            while next < total {
                if ring.write(hostSeconds: Double(next), sampleRate: 1, fill: { slot in
                    slot[0] = Float(next)
                    return 1
                }) { next += 1 }
            }
        }
        var received: [Float] = []
        while received.count < total {
            ring.read { _, samples in received.append(samples[0]) }
        }
        await producer.value
        #expect(received == (0..<total).map(Float.init))
    }
}

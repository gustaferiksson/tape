import Synchronization

public struct AudioRingChunk: Sendable {
    public let frames: Int
    public let hostSeconds: Double
    public let sampleRate: Double
}

// Single producer (the realtime IOProc), single consumer. Neither side allocates or locks.
public final class AudioRing: @unchecked Sendable {
    public let framesPerSlot: Int
    private let slotCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let chunks: UnsafeMutablePointer<AudioRingChunk>
    private let writeCount = Atomic<Int>(0)
    private let readCount = Atomic<Int>(0)
    private let droppedCount = Atomic<Int>(0)

    public init(slots: Int, framesPerSlot: Int) {
        slotCount = slots
        self.framesPerSlot = framesPerSlot
        samples = .allocate(capacity: slots * framesPerSlot)
        samples.initialize(repeating: 0, count: slots * framesPerSlot)
        chunks = .allocate(capacity: slots)
        chunks.initialize(repeating: AudioRingChunk(frames: 0, hostSeconds: 0, sampleRate: 0), count: slots)
    }

    deinit {
        samples.deallocate()
        chunks.deallocate()
    }

    public var dropped: Int { droppedCount.load(ordering: .relaxed) }

    @discardableResult
    public func write(hostSeconds: Double, sampleRate: Double, fill: (UnsafeMutableBufferPointer<Float>) -> Int) -> Bool {
        let index = writeCount.load(ordering: .relaxed)
        guard index - readCount.load(ordering: .acquiring) < slotCount else {
            droppedCount.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        let slot = UnsafeMutableBufferPointer(start: samples + (index % slotCount) * framesPerSlot, count: framesPerSlot)
        let frames = max(0, min(fill(slot), framesPerSlot))
        chunks[index % slotCount] = AudioRingChunk(frames: frames, hostSeconds: hostSeconds, sampleRate: sampleRate)
        writeCount.store(index + 1, ordering: .releasing)
        return true
    }

    @discardableResult
    public func read(_ body: (AudioRingChunk, UnsafeBufferPointer<Float>) -> Void) -> Bool {
        let index = readCount.load(ordering: .relaxed)
        guard index < writeCount.load(ordering: .acquiring) else { return false }
        let chunk = chunks[index % slotCount]
        body(chunk, UnsafeBufferPointer(start: samples + (index % slotCount) * framesPerSlot, count: chunk.frames))
        readCount.store(index + 1, ordering: .releasing)
        return true
    }
}

import AVFoundation
import CoreAudio
import Synchronization
import TapeCore

enum CaptureEvent: Sendable, Equatable {
    case microphone(String?)
    case systemAudioDenied
    case deviceFailed
    case writeFailed
}

struct CaptureError: LocalizedError {
    let errorDescription: String?

    init(_ message: String, status: OSStatus = noErr) {
        errorDescription = status == noErr ? message : "\(message) (\(status))"
    }
}

// The realtime IOProc only mixes into `ring`. Device state is owned by `controlQueue`; conversion and writing by `processingQueue`.
final class CaptureSession: @unchecked Sendable {
    private static let outputRate = 48000.0
    private static let rebuildAttemptsWithMicrophone = 3

    private let controlQueue = DispatchQueue(label: "dev.gustaf.tape.control")
    private let processingQueue = DispatchQueue(label: "dev.gustaf.tape.processing", qos: .userInitiated)
    private let ring = AudioRing(slots: 256, framesPerSlot: 8192)
    private let deviceRate = Atomic<UInt64>(0)
    private let heardSystemAudio = Atomic<Bool>(false)
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputFormat: AVAudioFormat
    private let probesTap: Bool
    private let onEvent: @Sendable (CaptureEvent) -> Void

    private var tap: (id: AudioObjectID, description: CATapDescription)?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rateListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var rebuildRequest = 0
    private var isStopping = false
    private var didReportDenial = false

    private var converter: AVAudioConverter?
    private var converterRate = 0.0
    private var limiter = PeakLimiter(sampleRate: CaptureSession.outputRate)
    private var framesWritten: Int64 = 0
    private var expectedHostSeconds: Double?
    private var isFinished = false
    private var drainTimer: DispatchSourceTimer?
    private let silence = [Float](repeating: 0, count: 4096)

    init(url: URL, probesTap: Bool, onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.outputRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false) else {
            throw CaptureError("Couldn’t describe the output format.")
        }
        self.outputFormat = outputFormat
        self.probesTap = probesTap
        self.onEvent = onEvent
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            controlQueue.async { [self] in
                do {
                    guard writer.startWriting() else { throw writer.error ?? CaptureError("Couldn’t create the file.") }
                    writer.startSession(atSourceTime: .zero)
                    processingQueue.sync { startDraining() }
                    tap = try Self.makeTap()
                    try startAggregate(includeMicrophone: true)
                    listenForDefaultInput()
                    if probesTap { scheduleProbes() }
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    func finish() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            controlQueue.async { [self] in
                isStopping = true
                if let defaultInputListener {
                    var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, defaultInputListener)
                }
                defaultInputListener = nil
                stopAggregate()
                if let tap { AudioHardwareDestroyProcessTap(tap.id) }
                tap = nil
                done.resume()
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            processingQueue.async { [self] in
                drainTimer?.cancel()
                drainTimer = nil
                drain()
                flushConverter()
                isFinished = true
                if writer.status == .writing { input.markAsFinished() }
                done.resume()
            }
        }
        if writer.status == .writing { await writer.finishWriting() }
        return heardSystemAudio.load(ordering: .relaxed)
    }

    // MARK: Devices (controlQueue)

    private func startAggregate(includeMicrophone: Bool) throws {
        guard let tap else { throw CaptureError("System audio isn’t tapped.") }
        let micID = includeMicrophone ? Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) : nil
        guard let clockID = micID ?? Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
              let clockUID = Self.string(of: clockID, kAudioDevicePropertyDeviceUID)
        else { throw CaptureError("No audio device is available.") }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tape",
            kAudioAggregateDeviceUIDKey: "dev.gustaf.tape.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID, kAudioSubDeviceDriftCompensationKey: true]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard created == noErr else { throw CaptureError("Couldn’t create the capture device.", status: created) }
        aggregateID = aggregate

        guard let rate = Self.sampleRate(of: aggregate) else { throw CaptureError("The capture device has no sample rate.") }
        deviceRate.store(rate.bitPattern, ordering: .relaxed)

        // Sub-device streams come first in the aggregate (FullSubDeviceList order), then the tap's.
        let tapIndex = Self.inputStreamCount(of: clockID)
        guard Self.inputStreamCount(of: aggregate) > tapIndex else { throw CaptureError("The capture device has no system audio stream.") }

        for object in [aggregate, clockID] {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.sampleRateChanged(on: object) }
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectAddPropertyListenerBlock(object, &address, controlQueue, listener)
            rateListeners.append((object, listener))
        }

        var proc: AudioDeviceIOProcID?
        let createdProc = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { [self] _, inputData, inputTime, _, _ in
            capture(inputData, at: inputTime.pointee, tapIndex: tapIndex)
        }
        guard createdProc == noErr, let proc else { throw CaptureError("Couldn’t read the capture device.", status: createdProc) }
        procID = proc
        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else { throw CaptureError("Couldn’t start the capture device.", status: started) }
        onEvent(.microphone(micID.flatMap { Self.string(of: $0, kAudioObjectPropertyName) }))
    }

    private func stopAggregate() {
        for (object, listener) in rateListeners {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(object, &address, controlQueue, listener)
        }
        rateListeners = []
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func listenForDefaultInput() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.requestRebuild() }
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        defaultInputListener = listener
    }

    private func sampleRateChanged(on device: AudioObjectID) {
        guard let rate = Self.sampleRate(of: device), rate != Double(bitPattern: deviceRate.load(ordering: .relaxed)) else { return }
        requestRebuild()
    }

    private func requestRebuild() {
        guard !isStopping else { return }
        rebuildRequest += 1
        let request = rebuildRequest
        controlQueue.async { [weak self] in self?.rebuild(request: request, attempt: 0) }
    }

    private func rebuild(request: Int, attempt: Int) {
        guard !isStopping, request == rebuildRequest else { return }
        stopAggregate()
        do {
            try startAggregate(includeMicrophone: attempt < Self.rebuildAttemptsWithMicrophone)
            return
        } catch {
            stopAggregate()
        }
        guard attempt < Self.rebuildAttemptsWithMicrophone else {
            onEvent(.deviceFailed)
            return
        }
        controlQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.rebuild(request: request, attempt: attempt + 1) }
    }

    private func scheduleProbes() {
        for delay in [3.0, 8.0] {
            controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.probeSystemAudioPermission() }
        }
    }

    // Undocumented (spike 2): rewriting a tap's description reportedly fails with kAudioDevicePermissionsError once system audio access is denied.
    private func probeSystemAudioPermission() {
        guard !isStopping, !didReportDenial, let tap, !heardSystemAudio.load(ordering: .relaxed) else { return }
        var address = Self.address(kAudioTapPropertyDescription)
        let status = withUnsafePointer(to: tap.description) {
            AudioObjectSetPropertyData(tap.id, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == kAudioDevicePermissionsError else { return }
        didReportDenial = true
        onEvent(.systemAudioDenied)
    }

    // MARK: Realtime IOProc

    private func capture(_ data: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp, tapIndex: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        guard let first = buffers.first(where: { $0.mData != nil && $0.mNumberChannels > 0 }) else { return }
        let available = Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(first.mNumberChannels)
        let hostSeconds = Double(AudioConvertHostTimeToNanos(time.mHostTime)) / 1e9
        let rate = Double(bitPattern: deviceRate.load(ordering: .relaxed))
        ring.write(hostSeconds: hostSeconds, sampleRate: rate) { slot in
            let frames = min(available, slot.count)
            let output = UnsafeMutableBufferPointer(rebasing: slot[0..<frames])
            output.update(repeating: 0)
            for index in buffers.indices {
                let buffer = buffers[index]
                guard let raw = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                let stream = InterleavedStream(
                    samples: UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size),
                    channels: Int(buffer.mNumberChannels)
                )
                if index == tapIndex, !heardSystemAudio.load(ordering: .relaxed), stream.samples.contains(where: { $0 != 0 }) {
                    heardSystemAudio.store(true, ordering: .relaxed)
                }
                Mixer.addLoudestChannel(of: stream, into: output)
            }
            return frames
        }
    }

    // MARK: Writing (processingQueue)

    private func startDraining() {
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    private func drain() {
        while !isFinished, ring.read({ chunk, samples in consume(chunk, samples) }) {}
    }

    private func consume(_ chunk: AudioRingChunk, _ samples: UnsafeBufferPointer<Float>) {
        guard chunk.sampleRate > 0 else { return }
        if chunk.sampleRate != converterRate {
            flushConverter()
            converter = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: chunk.sampleRate, channels: 1, interleaved: false)
                .flatMap { AVAudioConverter(from: $0, to: outputFormat) }
            converterRate = chunk.sampleRate
        }
        var gap = expectedHostSeconds.map { SilenceGap.frames(expectedSeconds: $0, actualSeconds: chunk.hostSeconds, sampleRate: chunk.sampleRate) } ?? 0
        while gap > 0 {
            let count = min(gap, silence.count)
            silence.withUnsafeBufferPointer { push(UnsafeBufferPointer(rebasing: $0[0..<count])) }
            gap -= count
        }
        expectedHostSeconds = chunk.hostSeconds + Double(chunk.frames) / chunk.sampleRate
        push(samples)
    }

    private func push(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty, let converter, let base = samples.baseAddress,
              let source = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(samples.count) * Self.outputRate / converterRate) + 1024),
              let sourceChannel = source.floatChannelData?[0]
        else { return }
        source.frameLength = AVAudioFrameCount(samples.count)
        sourceChannel.update(from: base, count: samples.count)
        var supplied = false
        var error: NSError?
        converter.convert(to: destination, error: &error) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        guard error == nil else { return }
        append(destination)
    }

    private func flushConverter() {
        guard let converter, let destination = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else { return }
        var error: NSError?
        converter.convert(to: destination, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        if error == nil { append(destination) }
        self.converter = nil
        converterRate = 0
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return }
        guard writer.status == .writing else {
            failWriting()
            return
        }
        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        limiter.process(&samples)
        let byteCount = samples.count * MemoryLayout<Float>.size
        let timestamp = CMTime(value: framesWritten, timescale: CMTimeScale(Self.outputRate))
        framesWritten += Int64(samples.count)
        guard input.isReadyForMoreMediaData else { return }
        var block: CMBlockBuffer?
        var sample: CMSampleBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              samples.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }) == noErr,
              CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: outputFormat.formatDescription, sampleCount: samples.count, presentationTimeStamp: timestamp, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
              let sample
        else { return }
        if !input.append(sample) { failWriting() }
    }

    private func failWriting() {
        guard !isFinished else { return }
        isFinished = true
        onEvent(.writeFailed)
    }

    // MARK: Core Audio properties

    private static func makeTap() throws -> (id: AudioObjectID, description: CATapDescription) {
        var pid = getpid()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let translated = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject)
        guard translated == noErr else { throw CaptureError("Couldn’t find Tape’s audio process.", status: translated) }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [processObject])
        description.name = "Tape"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateProcessTap(description, &tapID)
        guard created == noErr else { throw CaptureError("Couldn’t tap system audio.", status: created) }
        return (tapID, description)
    }

    private static func sampleRate(of device: AudioObjectID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = address(kAudioDevicePropertyNominalSampleRate)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    private static func inputStreamCount(of device: AudioObjectID) -> Int {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(selector)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func string(of object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(selector)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

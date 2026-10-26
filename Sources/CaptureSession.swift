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

enum MicrophonePath: Sendable {
    case aggregate
    case voiceProcessing
}

struct CaptureError: LocalizedError {
    let errorDescription: String?

    init(_ message: String, status: OSStatus = noErr) {
        errorDescription = status == noErr ? message : "\(message) (\(status))"
    }
}

// The realtime IOProc only mixes into `ring` (the engine tap into `microphoneRing`). Device state is owned by `controlQueue`; conversion and writing by `processingQueue`.
final class CaptureSession: @unchecked Sendable {
    private static let outputRate = 48000.0
    private static let rebuildAttemptsWithMicrophone = 3

    private let controlQueue = DispatchQueue(label: "dev.gustaf.tape.control")
    private let controlOperations = OperationQueue()
    private let processingQueue = DispatchQueue(label: "dev.gustaf.tape.processing", qos: .userInitiated)
    private let ring = AudioRing(slots: 256, framesPerSlot: 8192)
    private let microphoneRing: AudioRing?
    private let microphoneWriter = Mutex(())
    private let microphonePath: MicrophonePath
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
    private var defaultDeviceListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var rebuildRequest = 0
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var microphoneRequest = 0
    private var isStopping = false
    private var didReportDenial = false

    private let systemResampler: Resampler
    private let microphoneResampler: Resampler
    private var mix = AlignedMix(sampleRate: CaptureSession.outputRate)
    private var limiter = PeakLimiter(sampleRate: CaptureSession.outputRate)
    private var framesWritten: Int64 = 0
    private var expectedHostSeconds: Double?
    private var isFinished = false
    private var drainTimer: DispatchSourceTimer?
    private let silence = [Float](repeating: 0, count: 4096)

    init(url: URL, probesTap: Bool, microphonePath: MicrophonePath, onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws {
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
        systemResampler = Resampler(outputFormat: outputFormat)
        microphoneResampler = Resampler(outputFormat: outputFormat)
        self.microphonePath = microphonePath
        microphoneRing = microphonePath == .voiceProcessing ? AudioRing(slots: 256, framesPerSlot: 8192) : nil
        controlOperations.underlyingQueue = controlQueue
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
                    if microphonePath == .voiceProcessing { try startMicrophone() }
                    tap = try Self.makeTap()
                    try startAggregate(includeMicrophone: microphonePath == .aggregate)
                    listenForDefaultDevices()
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
                for (selector, listener) in defaultDeviceListeners {
                    var address = Self.address(selector)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
                }
                defaultDeviceListeners = []
                stopMicrophone()
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
                output(systemResampler.flush(), hostSeconds: expectedHostSeconds ?? 0)
                if microphonePath == .voiceProcessing { append(mix.take(flush: true)) }
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
        let streamCount = Self.inputStreamCount(of: aggregate)
        guard streamCount > tapIndex else { throw CaptureError("The capture device has no system audio stream.") }
        let firstStream = microphonePath == .voiceProcessing ? tapIndex : 0

        for object in [aggregate, clockID] {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.sampleRateChanged(on: object) }
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectAddPropertyListenerBlock(object, &address, controlQueue, listener)
            rateListeners.append((object, listener))
        }

        var proc: AudioDeviceIOProcID?
        let createdProc = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { [self] _, inputData, inputTime, _, _ in
            capture(inputData, at: inputTime.pointee, tapIndex: tapIndex, firstStream: firstStream)
        }
        guard createdProc == noErr, let proc else { throw CaptureError("Couldn’t read the capture device.", status: createdProc) }
        procID = proc
        if firstStream > 0 { Self.enableInputStreams(from: firstStream, of: streamCount, on: aggregate, for: proc) }
        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else { throw CaptureError("Couldn’t start the capture device.", status: started) }
        guard microphonePath == .aggregate else { return }
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

    private func listenForDefaultDevices() {
        let listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = microphonePath == .aggregate
            ? [(kAudioHardwarePropertyDefaultInputDevice, { [weak self] _, _ in self?.requestRebuild() })]
            : [
                (kAudioHardwarePropertyDefaultOutputDevice, { [weak self] _, _ in self?.requestRebuild() }),
                (kAudioHardwarePropertyDefaultInputDevice, { [weak self] _, _ in self?.requestMicrophoneRestart() }),
            ]
        for (selector, listener) in listeners {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        }
        defaultDeviceListeners = listeners
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
            try startAggregate(includeMicrophone: microphonePath == .aggregate && attempt < Self.rebuildAttemptsWithMicrophone)
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

    private func startMicrophone() throws {
        guard let microphoneRing else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        // The voice-processing unit is duplex and needs its output side in the graph to start.
        engine.mainMixerNode.outputVolume = 0
        let nodeFormat = input.outputFormat(forBus: 0)
        guard nodeFormat.sampleRate > 0, nodeFormat.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nodeFormat.sampleRate, channels: 1, interleaved: false)
        else { throw CaptureError("The microphone has no audio format.") }
        // A stopped engine's tap block can still be in flight while the next engine's starts, and the ring allows one producer.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            self?.microphoneWriter.withLock { _ in Self.capture(buffer, at: time, into: microphoneRing) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: controlOperations) { [weak self] _ in
            self?.requestMicrophoneRestart()
        }
        onEvent(.microphone(Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap { Self.string(of: $0, kAudioObjectPropertyName) }))
    }

    private func stopMicrophone() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func requestMicrophoneRestart() {
        guard !isStopping else { return }
        microphoneRequest += 1
        let request = microphoneRequest
        controlQueue.async { [weak self] in self?.restartMicrophone(request: request, attempt: 0) }
    }

    private func restartMicrophone(request: Int, attempt: Int) {
        guard !isStopping, request == microphoneRequest else { return }
        stopMicrophone()
        do {
            try startMicrophone()
            return
        } catch {
            stopMicrophone()
        }
        guard attempt < Self.rebuildAttemptsWithMicrophone else {
            onEvent(.microphone(nil))
            return
        }
        controlQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restartMicrophone(request: request, attempt: attempt + 1) }
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

    private func capture(_ data: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp, tapIndex: Int, firstStream: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        guard let first = buffers.first(where: { $0.mData != nil && $0.mNumberChannels > 0 }) else { return }
        let available = Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(first.mNumberChannels)
        let hostSeconds = Double(AudioConvertHostTimeToNanos(time.mHostTime)) / 1e9
        let rate = Double(bitPattern: deviceRate.load(ordering: .relaxed))
        ring.write(hostSeconds: hostSeconds, sampleRate: rate) { slot in
            let frames = min(available, slot.count)
            let output = UnsafeMutableBufferPointer(rebasing: slot[0..<frames])
            output.update(repeating: 0)
            for index in buffers.indices where index >= firstStream {
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

    private static func capture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, into ring: AudioRing) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let stride = buffer.stride
        let frames = Int(buffer.frameLength)
        let hostTime = time.isHostTimeValid ? time.hostTime : AudioGetCurrentHostTime()
        ring.write(hostSeconds: Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9, sampleRate: buffer.format.sampleRate) { slot in
            let count = min(frames, slot.count)
            for frame in 0..<count { slot[frame] = channel[frame * stride] }
            return count
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
        guard let microphoneRing else { return }
        while !isFinished, microphoneRing.read({ chunk, samples in consumeMicrophone(chunk, samples) }) {}
    }

    private func consume(_ chunk: AudioRingChunk, _ samples: UnsafeBufferPointer<Float>) {
        guard chunk.sampleRate > 0 else { return }
        var gap = expectedHostSeconds.map { SilenceGap.frames(expectedSeconds: $0, actualSeconds: chunk.hostSeconds, sampleRate: chunk.sampleRate) } ?? 0
        while gap > 0 {
            let count = min(gap, silence.count)
            let converted = silence.withUnsafeBufferPointer { systemResampler.convert(UnsafeBufferPointer(rebasing: $0[0..<count]), rate: chunk.sampleRate) }
            output(converted, hostSeconds: chunk.hostSeconds - Double(gap) / chunk.sampleRate)
            gap -= count
        }
        expectedHostSeconds = chunk.hostSeconds + Double(chunk.frames) / chunk.sampleRate
        output(systemResampler.convert(samples, rate: chunk.sampleRate), hostSeconds: chunk.hostSeconds)
    }

    private func consumeMicrophone(_ chunk: AudioRingChunk, _ samples: UnsafeBufferPointer<Float>) {
        guard chunk.sampleRate > 0 else { return }
        mix.appendMic(microphoneResampler.convert(samples, rate: chunk.sampleRate), hostSeconds: chunk.hostSeconds)
        append(mix.take())
    }

    private func output(_ samples: [Float], hostSeconds: Double) {
        guard microphonePath == .voiceProcessing else {
            append(samples)
            return
        }
        mix.appendSystem(samples, hostSeconds: hostSeconds)
        append(mix.take())
    }

    private func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard writer.status == .writing else {
            failWriting()
            return
        }
        var samples = samples
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

    private static func enableInputStreams(from first: Int, of count: Int, on device: AudioObjectID, for proc: AudioDeviceIOProcID) {
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 0
        let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams) ?? 0
        let size = flagsOffset + count * MemoryLayout<UInt32>.stride
        let usage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { usage.deallocate() }
        usage.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        usage.storeBytes(of: UInt32(count), toByteOffset: countOffset, as: UInt32.self)
        for stream in 0..<count {
            usage.storeBytes(of: UInt32(stream >= first ? 1 : 0), toByteOffset: flagsOffset + stream * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), usage)
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

private final class Resampler {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var rate = 0.0

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ samples: UnsafeBufferPointer<Float>, rate: Double) -> [Float] {
        let flushed = rate == self.rate ? [] : flush()
        if converter == nil {
            converter = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
                .flatMap { AVAudioConverter(from: $0, to: outputFormat) }
            self.rate = rate
        }
        guard !samples.isEmpty, let converter, let base = samples.baseAddress,
              let source = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(samples.count) * outputFormat.sampleRate / rate) + 1024),
              let sourceChannel = source.floatChannelData?[0]
        else { return flushed }
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
        guard error == nil else { return flushed }
        return flushed + Self.samples(of: destination)
    }

    func flush() -> [Float] {
        defer {
            converter = nil
            rate = 0
        }
        guard let converter, let destination = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else { return [] }
        var error: NSError?
        converter.convert(to: destination, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        return error == nil ? Self.samples(of: destination) : []
    }

    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

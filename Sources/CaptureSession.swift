import AVFoundation
import CoreAudio
import TapeCore

enum CaptureEvent: Sendable {
    case microphone(String?)
    case systemAudioDenied
    case failed
}

struct CaptureError: LocalizedError {
    let errorDescription: String?

    init(_ message: String, status: OSStatus = noErr) {
        errorDescription = status == noErr ? message : "\(message) (\(status))"
    }
}

// Device state lives on `controlQueue`, sample state on `ioQueue`. AudioDeviceStop waits for the IOProc, so it must never run on the IOProc's own queue.
final class CaptureSession: @unchecked Sendable {
    private static let outputRate = 48000.0

    private let controlQueue = DispatchQueue(label: "dev.gustaf.tape.control")
    private let ioQueue = DispatchQueue(label: "dev.gustaf.tape.io", qos: .userInteractive)
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputFormat: AVAudioFormat
    private let sampleFormat: CMAudioFormatDescription
    private let probesTap: Bool
    private let onEvent: @Sendable (CaptureEvent) -> Void

    private var tap: (id: AudioObjectID, description: CATapDescription)?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var limiter = PeakLimiter(sampleRate: CaptureSession.outputRate)
    private var framesWritten: Int64 = 0
    private var expectedHostSeconds: Double?
    private var hasSystemAudio = false
    private var isFinished = false
    private var probeTimer: DispatchSourceTimer?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

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
        sampleFormat = outputFormat.formatDescription
        self.probesTap = probesTap
        self.onEvent = onEvent
    }

    func start() throws {
        guard writer.startWriting() else { throw writer.error ?? CaptureError("Couldn’t create the file.") }
        writer.startSession(atSourceTime: .zero)
        try controlQueue.sync {
            tap = try Self.makeTap()
            try startAggregate()
            listenForDefaultInput()
            if probesTap { startProbe() }
        }
    }

    func finish() async -> Bool {
        controlQueue.sync {
            probeTimer?.cancel()
            if let defaultInputListener {
                var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, defaultInputListener)
            }
            stopAggregate()
            if let tap { AudioHardwareDestroyProcessTap(tap.id) }
        }
        let hadSystemAudio = ioQueue.sync {
            isFinished = true
            if writer.status == .writing { input.markAsFinished() }
            return hasSystemAudio
        }
        if writer.status == .writing { await writer.finishWriting() }
        return hadSystemAudio
    }

    private func startAggregate() throws {
        guard let tap else { return }
        let micID = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let micUID = micID.flatMap { Self.string(of: $0, kAudioDevicePropertyDeviceUID) }
        let clockUID = micUID ?? Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).flatMap { Self.string(of: $0, kAudioDevicePropertyDeviceUID) }
        guard let clockUID else { throw CaptureError("No audio device is available.") }
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

        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectGetPropertyData(aggregate, &rateAddress, 0, nil, &size, &rate)
        guard rate > 0, let deviceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw CaptureError("The capture device has no sample rate.")
        }
        ioQueue.sync { converter = AVAudioConverter(from: deviceFormat, to: outputFormat) }

        var proc: AudioDeviceIOProcID?
        let createdProc = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) { [weak self] _, inputData, inputTime, _, _ in
            self?.process(inputData, at: inputTime.pointee, sampleRate: rate)
        }
        guard createdProc == noErr, let proc else { throw CaptureError("Couldn’t read the capture device.", status: createdProc) }
        procID = proc
        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else { throw CaptureError("Couldn’t start the capture device.", status: started) }
        onEvent(.microphone(micID.flatMap { Self.string(of: $0, kAudioObjectPropertyName) }))
    }

    private func stopAggregate() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        ioQueue.sync { converter = nil }
    }

    private func listenForDefaultInput() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !ioQueue.sync(execute: { isFinished }) else { return }
            stopAggregate()
            do {
                try startAggregate()
            } catch {
                onEvent(.failed)
            }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        defaultInputListener = listener
    }

    // Undocumented (spike 2): rewriting a tap's description reportedly fails with kAudioDevicePermissionsError once system audio access is denied.
    private func startProbe() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, let tap else { return }
            let (finished, heard) = ioQueue.sync { (isFinished, hasSystemAudio) }
            guard !finished, !heard else {
                probeTimer?.cancel()
                return
            }
            var address = Self.address(kAudioTapPropertyDescription)
            let status = withUnsafePointer(to: tap.description) {
                AudioObjectSetPropertyData(tap.id, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
            }
            guard status == kAudioDevicePermissionsError else { return }
            probeTimer?.cancel()
            onEvent(.systemAudioDenied)
        }
        timer.resume()
        probeTimer = timer
    }

    private func process(_ data: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp, sampleRate: Double) {
        guard !isFinished, let converter else { return }
        let streams = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data)).compactMap { buffer -> InterleavedStream? in
            guard let raw = buffer.mData, buffer.mNumberChannels > 0 else { return nil }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return InterleavedStream(samples: UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: count), channels: Int(buffer.mNumberChannels))
        }
        guard let first = streams.first else { return }
        let frames = first.samples.count / first.channels
        // The aggregate lists sub-device streams before tap streams, so the tap is the last buffer.
        if !hasSystemAudio, let system = streams.last, system.samples.contains(where: { $0 != 0 }) { hasSystemAudio = true }

        let hostSeconds = Double(AudioConvertHostTimeToNanos(time.mHostTime)) / 1e9
        let gap = expectedHostSeconds.map { SilenceGap.frames(expectedSeconds: $0, actualSeconds: hostSeconds, sampleRate: sampleRate) } ?? 0
        expectedHostSeconds = hostSeconds + Double(frames) / sampleRate
        let mixed = [Float](repeating: 0, count: gap) + Mixer.mix(streams, frames: frames)
        guard var samples = convert(mixed, with: converter, sampleRate: sampleRate), !samples.isEmpty else { return }
        limiter.process(&samples)
        append(samples)
    }

    private func convert(_ samples: [Float], with converter: AVAudioConverter, sampleRate: Double) -> [Float]? {
        guard let source = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(samples.count) * Self.outputRate / sampleRate) + 1024),
              let sourceChannel = source.floatChannelData?[0]
        else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { sourceChannel.update(from: $0.baseAddress!, count: samples.count) }
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
        guard error == nil, let channel = destination.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(destination.frameLength)))
    }

    private func append(_ samples: [Float]) {
        let byteCount = samples.count * MemoryLayout<Float>.size
        let timestamp = CMTime(value: framesWritten, timescale: CMTimeScale(Self.outputRate))
        framesWritten += Int64(samples.count)
        guard input.isReadyForMoreMediaData else { return }
        var block: CMBlockBuffer?
        var sample: CMSampleBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              samples.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }) == noErr,
              CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: sampleFormat, sampleCount: samples.count, presentationTimeStamp: timestamp, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
              let sample
        else { return }
        guard input.append(sample) else {
            isFinished = true
            onEvent(.failed)
            return
        }
    }

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

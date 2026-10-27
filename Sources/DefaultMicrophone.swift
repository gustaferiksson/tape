import CoreAudio
import Observation

// Reads Core Audio device metadata only and never opens the device, so it needs no microphone permission.
@MainActor @Observable
final class DefaultMicrophone {
    private(set) var name: String?
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?

    func refresh() {
        name = CaptureSession.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap { CaptureSession.string(of: $0, kAudioObjectPropertyName) }
    }

    func startListening() {
        guard listener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        var address = CaptureSession.address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else { return }
        self.listener = listener
    }

    func stopListening() {
        guard let listener else { return }
        var address = CaptureSession.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        self.listener = nil
    }

    #if DEBUG
    func simulate(_ name: String?) {
        self.name = name
    }
    #endif
}

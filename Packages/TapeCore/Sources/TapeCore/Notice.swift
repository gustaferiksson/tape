import Foundation

public enum PrivacyPane: Sendable {
    case microphone, systemAudio

    public var url: URL {
        let anchor = self == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum StopReason: Sendable, Equatable {
    case sleep
    case diskFull(volume: String)
    case volumeDisconnected(volume: String)
    case writeFailed
    case audioFailed
}

public enum Notice: Sendable, Equatable {
    case microphoneDenied
    case systemAudioDenied
    case recovered(name: String)
    case stopped(StopReason)
    case fellBack(folder: String)
    case noSystemAudio
    case notEnoughSpace(volume: String)

    public var text: String {
        switch self {
        case .microphoneDenied: "Microphone access is off."
        case .systemAudioDenied: "System audio access is off."
        case .recovered(let name): "Recovered “\(name)”."
        case .stopped(.sleep): "Recording stopped when your Mac went to sleep."
        case .stopped(.diskFull(let volume)): "Recording stopped: “\(volume)” is full."
        case .stopped(.volumeDisconnected(let volume)): "Recording stopped: “\(volume)” was disconnected."
        case .stopped(.writeFailed): "Recording stopped: couldn’t write to the file."
        case .stopped(.audioFailed): "Recording stopped: the audio device stopped working."
        case .fellBack(let folder): "Saved to Movies › Tape. “\(folder)” wasn’t available."
        case .noSystemAudio: "The last recording has no system audio."
        case .notEnoughSpace(let volume): "Not enough space on “\(volume)” to record."
        }
    }

    public var privacyPane: PrivacyPane? {
        if self == .microphoneDenied { return .microphone }
        if self == .systemAudioDenied || self == .noSystemAudio { return .systemAudio }
        return nil
    }
}

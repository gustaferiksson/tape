import Foundation
import Observation

@MainActor @Observable
final class AppSettings {
    static let shared: AppSettings = {
        #if DEBUG
        if SettingsSnapshot.output != nil || LabelSnapshot.output != nil || MenuSnapshot.output != nil {
            let suite = "dev.gustaf.tape.snapshot"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            return AppSettings(store: UserDefaults(suiteName: suite) ?? .standard)
        }
        #endif
        return AppSettings(store: .standard)
    }()

    static let defaultFolder = URL.moviesDirectory.appending(path: "Tape", directoryHint: .isDirectory)

    @ObservationIgnored let store: UserDefaults

    var customFolder: URL? { didSet { store.set(customFolder?.path, forKey: "saveFolder") } }

    var reducesEcho: Bool { didSet { store.set(reducesEcho, forKey: "reduceEcho") } }

    var saveFolder: URL { customFolder ?? Self.defaultFolder }

    init(store: UserDefaults) {
        self.store = store
        customFolder = store.string(forKey: "saveFolder").map { URL(filePath: $0, directoryHint: .isDirectory) }
        reducesEcho = store.bool(forKey: "reduceEcho")
    }
}

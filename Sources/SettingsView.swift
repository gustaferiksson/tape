import SwiftUI

enum SettingsTab: String {
    case general, about
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @AppStorage("settingsTab") private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettings(settings: settings)
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                AboutSettings()
            }
        }
        .frame(width: 480)
        .onAppear {
            #if DEBUG
            guard SettingsSnapshot.output == nil else { return }
            #endif
            // Without a Dock icon, macOS leaves the menu bar blank after a Space switch while Settings is key.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            #if DEBUG
            guard SettingsSnapshot.output == nil else { return }
            #endif
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

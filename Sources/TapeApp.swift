import SwiftUI
import TapeCore

@main
struct TapeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(settings: .shared)
                .environment(appDelegate.updater)
        }
    }
}

@MainActor
func menuBarImage(phase: Recorder.Phase, elapsed: Int) -> NSImage {
    let font = NSFont.menuBarFont(ofSize: 0)
    let isIdle = phase == .idle || phase == .starting
    let symbol = NSImage(systemSymbolName: "waveform", variableValue: isIdle ? 0 : 1, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium))
    let title = NSAttributedString(
        string: isIdle ? "" : ElapsedTime.clock(elapsed),
        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)]
    )
    let symbolSize = symbol?.size ?? .zero
    let titleSize = isIdle ? .zero : title.size()
    let gap: CGFloat = isIdle ? 0 : 4
    let height = max(symbolSize.height, titleSize.height).rounded(.up)
    let size = NSSize(width: (symbolSize.width + gap + titleSize.width).rounded(.up), height: height)
    let image = NSImage(size: size, flipped: false) { _ in
        symbol?.draw(in: NSRect(x: 0, y: (height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
        title.draw(at: NSPoint(x: symbolSize.width + gap, y: (height - titleSize.height) / 2))
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = switch phase {
    case .idle: "Tape"
    case .starting: "Tape, starting"
    case .recording: "Tape, recording, \(ElapsedTime.spoken(elapsed))"
    case .stopping: "Tape, saving"
    }
    return image
}

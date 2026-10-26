import SwiftUI
import TapeCore

struct RecordingView: View {
    static let windowID = NSUserInterfaceItemIdentifier("recording")

    let recorder: Recorder

    var body: some View {
        VStack(spacing: 12) {
            Text(recorder.isSavingToFallback ? "Recording audio to Movies › Tape" : "Recording audio")
                .foregroundStyle(.secondary)
            Text(ElapsedTime.clock(recorder.elapsed))
                .font(.system(size: 32, weight: .medium).monospacedDigit())
                .accessibilityLabel("Elapsed \(ElapsedTime.spoken(recorder.elapsed))")
            Button("Stop Recording") { Task { await recorder.stop() } }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!recorder.isRecording)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .frame(minWidth: 240)
        .onChange(of: recorder.isActive) { _, isActive in
            guard !isActive else { return }
            NSApp.windows.first { $0.identifier == Self.windowID }?.close()
        }
    }
}

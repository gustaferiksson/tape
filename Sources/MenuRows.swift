import SwiftUI
import TapeCore

struct RecordRow: View {
    let recorder: Recorder
    let highlight: MenuHighlight

    var body: some View {
        MenuRow(isHighlighted: highlight.item == StatusMenu.recordItem) {
            HStack(spacing: 8) {
                MenuBadge(symbol: recorder.startedAt == nil ? "circle.fill" : "stop.fill", tint: recorder.startedAt == nil ? nil : .red)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(title)
                        Spacer(minLength: 8)
                        if recorder.startedAt != nil {
                            Text(ElapsedTime.clock(recorder.elapsed))
                                .monospacedDigit()
                                .accessibilityLabel(ElapsedTime.spoken(recorder.elapsed))
                        }
                    }
                    if let since = recorder.startedAt {
                        Group {
                            Text("Recording audio · since \(since.formatted(date: .omitted, time: .shortened))\(recorder.isSavingToFallback ? " · saving to Movies › Tape" : "")")
                            Text(recorder.microphoneName.map { "Microphone: \($0)" } ?? "Microphone unavailable")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var isEnabled: Bool {
        recorder.startedAt == nil ? recorder.phase == .idle : recorder.isRecording
    }

    private var title: String {
        if recorder.startedAt != nil { return recorder.isRecording ? "Stop Recording" : "Saving…" }
        return recorder.phase == .starting ? "Starting…" : "Record Audio"
    }
}

struct ReduceEchoRow: View {
    let settings: AppSettings
    let recorder: Recorder
    let highlight: MenuHighlight

    var body: some View {
        MenuRow(isHighlighted: highlight.item == StatusMenu.reduceEchoItem) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Reduce Echo")
                        .font(.headline)
                    if recorder.phase != .idle {
                        Text("Applies from the next recording.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Toggle("Reduce Echo", isOn: Bindable(settings).reducesEcho)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(recorder.phase != .idle)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct NoticeRow: View {
    let notice: Notice

    var body: some View {
        MenuRow(isHighlighted: false) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(notice.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        if case .recovered = notice { return "info.circle" }
        if case .fellBack = notice { return "info.circle" }
        return "exclamationmark.triangle"
    }
}

private struct MenuRow<Content: View>: View {
    let isHighlighted: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(isHighlighted ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: .rect(cornerRadius: 8))
            .padding(.horizontal, 5)
            .frame(width: StatusMenu.width)
    }
}

private struct MenuBadge: View {
    let symbol: String
    let tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint == nil ? Color.primary : .white)
            .frame(width: 28, height: 28)
            .background(tint ?? Color.primary.opacity(0.1), in: .circle)
            .accessibilityHidden(true)
    }
}

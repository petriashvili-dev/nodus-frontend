import SwiftUI

/// A deliberate two-step voice flow: record with an explicit control, then
/// review the exact words before creating a knot.
struct VoiceInputComposer: View {
    @ObservedObject var speech: SpeechTranscriptionService
    let language: AppLanguage
    let isSubmitting: Bool
    let cancel: () -> Void
    let submit: (String) -> Void

    @FocusState private var isTranscriptFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            topBar
            header
            recordingControl
            transcriptEditor
            actions
        }
        .padding(22)
        .frame(maxWidth: 520)
        .background(NodusPalette.surface.opacity(0.99), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(NodusPalette.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.success, trigger: speech.isRecording) { _, isRecording in isRecording }
    }

    private var topBar: some View {
        HStack {
            Text(language.localizedString("Voice note"))
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(NodusPalette.secondary.opacity(0.72))

            Spacer()

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(NodusPalette.background.opacity(0.56), in: Circle())
                    .overlay {
                        Circle().stroke(NodusPalette.primary.opacity(0.07), lineWidth: 1)
                    }
            }
            .buttonStyle(NodeButtonStyle(intensity: .subtle))
            .accessibilityLabel(language.localizedString("Cancel"))
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(language.localizedString(speech.isRecording ? "Recording thoughts…" : (speech.isPreparing ? "Opening microphone" : "Voice note")))
                .font(.cormorant(32, weight: .medium))
                .foregroundStyle(NodusPalette.primary.opacity(0.96))
                .contentTransition(.opacity)

            Text(language.localizedString(speech.isRecording ? "Speak freely. Tap stop when you are done." : (speech.isPreparing ? "Getting your voice note ready." : "Record a thought, then make it your own.")))
                .font(.system(size: 14, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(NodusPalette.secondary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: speech.isRecording)
    }

    private var recordingControl: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(NodusPalette.softLine.opacity(0.68), lineWidth: 1)

                Circle()
                    .stroke(NodusPalette.accent.opacity(speech.isRecording ? 0.18 : 0.08), lineWidth: 1)
                    .padding(9)

                VStack(spacing: 10) {
                    Group {
                        if speech.isRecording {
                            VoiceRecordingMeter()
                                .transition(.opacity)
                        } else if speech.isPreparing {
                            ProgressView()
                                .tint(NodusPalette.accent)
                                .frame(height: 36)
                        } else {
                            Image(systemName: speech.transcript.isEmpty ? "waveform" : "text.quote")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(NodusPalette.accent.opacity(0.82))
                                .frame(height: 36)
                        }
                    }
                    .frame(height: 40)

                    Button(action: toggleRecording) {
                        Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(speech.isRecording ? NodusPalette.background : Color(hex: 0xF5D7A8))
                            .frame(width: 64, height: 64)
                            .background(speech.isRecording ? NodusPalette.accent : NodusPalette.accent.opacity(0.18), in: Circle())
                            .overlay {
                                Circle().stroke(NodusPalette.accent.opacity(speech.isRecording ? 0 : 0.4), lineWidth: 1)
                            }
                    }
                    .buttonStyle(NodeButtonStyle(intensity: .subtle))
                    .disabled(isSubmitting || speech.isPreparing)
                    .accessibilityLabel(language.localizedString(recordingButtonTitle))
                    .accessibilityHint(language.localizedString(speech.isRecording ? "Stops recording and lets you edit the text" : "Starts a new voice recording"))
                }
            }
            .frame(width: 160, height: 160)
            .animation(.easeInOut(duration: 0.2), value: speech.isRecording)

            if speech.isRecording {
                Text(language.localizedString(recordingButtonTitle))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.74))

                if let startedAt = speech.recordingStartedAt {
                    VoiceRecordingProgress(startedAt: startedAt, maximumDuration: SpeechTranscriptionService.maximumRecordingDuration)
                        .transition(.opacity)
                }
            } else {
                Text(language.localizedString(recordingButtonTitle))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.74))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var recordingButtonTitle: String {
        if speech.isRecording { return "Stop recording" }
        if speech.isPreparing { return "Opening microphone" }
        return speech.transcript.isEmpty ? "Start recording" : "Record again"
    }

    private func toggleRecording() {
        if speech.isRecording {
            speech.stop()
        } else {
            speech.reset()
            Task { await speech.start(language: language) }
        }
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(language.localizedString("Your words"))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(NodusPalette.secondary.opacity(0.7))

                Spacer()

                if !speech.transcript.isEmpty {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NodusPalette.accent.opacity(0.7))
                        .accessibilityHidden(true)
                }
            }

            TextField(language.localizedString("What needs tying?"), text: editableTranscript, axis: .vertical)
                .font(.cormorant(22, weight: .regular))
                .foregroundStyle(NodusPalette.primary.opacity(0.96))
                .lineLimit(3...5)
                .focused($isTranscriptFocused)
                .disabled(speech.isRecording || isSubmitting)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
                .background(NodusPalette.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(NodusPalette.primary.opacity(0.06), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if let errorMessage = speech.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(hex: 0xD9947A))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !speech.isRecording {
                Button {
                    submit(speech.transcript)
                } label: {
                    HStack(spacing: 9) {
                        if isSubmitting {
                            ProgressView().tint(NodusPalette.background)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text(language.localizedString("Tie"))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(NodusPalette.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(NodusPalette.accent, in: Capsule(style: .continuous))
                }
                .buttonStyle(NodeButtonStyle())
                .disabled(speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            }
        }
    }

    private var editableTranscript: Binding<String> {
        Binding(get: { speech.transcript }, set: { speech.transcript = $0 })
    }

}

/// A short illuminated segment of the thread: it borrows the warm metal
/// treatment used by Nodus' controls instead of introducing a system-style
/// progress bar into the recording ritual.
private struct VoiceRecordingProgress: View {
    let startedAt: Date?
    let maximumDuration: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = min(context.date.timeIntervalSince(startedAt ?? context.date), maximumDuration)
            NodusRecordingThread(progress: elapsed / maximumDuration)
        }
    }
}

private struct NodusRecordingThread: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let completedWidth = max(5, proxy.size.width * progress)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(NodusPalette.softLine.opacity(0.82))

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                NodusPalette.accent.opacity(0.42),
                                Color(hex: 0xF0C98B).opacity(0.92),
                                NodusPalette.accent.opacity(0.72)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: completedWidth)
                    .shadow(color: NodusPalette.accent.opacity(0.36), radius: 5)

                Circle()
                    .fill(Color(hex: 0xF7D9A5))
                    .frame(width: 5, height: 5)
                    .shadow(color: NodusPalette.accent.opacity(0.75), radius: 4)
                    .offset(x: max(0, completedWidth - 5))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

private struct VoiceRecordingMeter: View {
    private let heights: [CGFloat] = [12, 20, 32, 18, 40, 24, 34, 16, 28]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                bars(phase: 0)
            } else {
                TimelineView(.animation) { context in
                    bars(phase: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(phase: TimeInterval) -> some View {
        HStack(spacing: 5) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(NodusPalette.accent.opacity(0.72))
                    .frame(width: 4, height: animatedHeight(for: index, phase: phase))
            }
        }
        .frame(height: 40)
    }

    private func animatedHeight(for index: Int, phase: TimeInterval) -> CGFloat {
        let wave = (sin(phase * 4 + Double(index) * 0.72) + 1) / 2
        return 10 + heights[index] * (0.35 + 0.65 * wave)
    }
}

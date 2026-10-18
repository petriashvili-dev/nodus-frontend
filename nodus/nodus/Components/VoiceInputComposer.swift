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
        VStack(spacing: 24) {
            header
            recordingControl
            transcriptEditor
            actions
        }
        .padding(24)
        .background(NodusPalette.surface.opacity(0.99), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(NodusPalette.accent.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.success, trigger: speech.isRecording) { _, isRecording in isRecording }
        .onChange(of: speech.isRecording) { _, isRecording in
            if !isRecording, !speech.transcript.isEmpty {
                isTranscriptFocused = true
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(language.localizedString(speech.isRecording ? "Recording thoughts…" : (speech.isPreparing ? "Opening microphone" : "Voice note")))
                .font(.cormorant(30, weight: .medium))
                .foregroundStyle(NodusPalette.primary.opacity(0.96))

            Text(language.localizedString(speech.isRecording ? "Speak freely. Tap stop when you are done." : (speech.isPreparing ? "Getting your voice note ready." : "Record a thought, then make it your own.")))
                .font(.system(size: 14, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(NodusPalette.secondary.opacity(0.82))
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingControl: some View {
        VStack(spacing: 12) {
            if speech.isRecording {
                VoiceRecordingMeter()
                    .transition(.opacity)
                VoiceRecordingProgress(startedAt: speech.recordingStartedAt, maximumDuration: SpeechTranscriptionService.maximumRecordingDuration)
            } else if speech.isPreparing {
                ProgressView()
                    .tint(NodusPalette.accent)
                    .frame(height: 32)
            } else {
                Image(systemName: speech.transcript.isEmpty ? "mic" : "text.quote")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(NodusPalette.accent.opacity(0.9))
                    .frame(height: 32)
            }

            Button {
                if speech.isRecording {
                    speech.stop()
                } else {
                    speech.reset()
                    Task { await speech.start(language: language) }
                }
            } label: {
                Label(
                    language.localizedString(speech.isRecording ? "Stop recording" : (speech.isPreparing ? "Opening microphone" : (speech.transcript.isEmpty ? "Start recording" : "Record again"))),
                    systemImage: speech.isRecording ? "stop.fill" : "mic.fill"
                )
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(speech.isRecording ? NodusPalette.background : NodusPalette.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(speech.isRecording ? NodusPalette.accent : NodusPalette.primary.opacity(0.1), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(NodusPalette.accent.opacity(speech.isRecording ? 0 : 0.42), lineWidth: 1)
                }
            }
            .buttonStyle(NodeButtonStyle(intensity: .subtle))
            .disabled(isSubmitting || speech.isPreparing)
            .accessibilityHint(language.localizedString(speech.isRecording ? "Stops recording and lets you edit the text" : "Starts a new voice recording"))
        }
        .animation(.easeInOut(duration: 0.2), value: speech.isRecording)
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.localizedString("Your words"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NodusPalette.secondary.opacity(0.82))

            TextField(language.localizedString("What needs tying?"), text: editableTranscript, axis: .vertical)
                .font(.cormorant(22, weight: .regular))
                .foregroundStyle(NodusPalette.primary.opacity(0.96))
                .lineLimit(3...6)
                .focused($isTranscriptFocused)
                .disabled(speech.isRecording || isSubmitting)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                .padding(16)
                .background(NodusPalette.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                HStack(spacing: 16) {
                    Button(language.localizedString("Cancel"), action: cancel)
                        .buttonStyle(NodeButtonStyle(intensity: .subtle))
                        .foregroundStyle(NodusPalette.secondary.opacity(0.92))
                        .frame(minHeight: 44)

                    Spacer()

                    Button {
                        submit(speech.transcript)
                    } label: {
                        HStack(spacing: 8) {
                            if isSubmitting {
                                ProgressView().tint(NodusPalette.background)
                            } else {
                                Image(systemName: "checkmark")
                            }
                            Text(language.localizedString("Tie"))
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NodusPalette.background)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .background(NodusPalette.accent, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(NodeButtonStyle())
                    .disabled(speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
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

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(heights.indices, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(NodusPalette.accent.opacity(0.72))
                        .frame(width: 4, height: animatedHeight(for: index, phase: phase))
                }
            }
            .frame(height: 40)
            .accessibilityHidden(true)
        }
    }

    private func animatedHeight(for index: Int, phase: TimeInterval) -> CGFloat {
        let wave = (sin(phase * 4 + Double(index) * 0.72) + 1) / 2
        return 10 + heights[index] * (0.35 + 0.65 * wave)
    }
}

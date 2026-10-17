import AVFoundation
import Combine
import Foundation
import Speech

/// Owns the short, on-device speech-recognition session used by the home
/// screen. The transcript remains editable in SwiftUI; this service only
/// captures speech and never sends it anywhere itself.
@MainActor
final class SpeechTranscriptionService: NSObject, ObservableObject {
    static let maximumRecordingDuration: TimeInterval = 30

    @Published var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var didReachRecordingLimit = false
    @Published private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recordingLimitTask: Task<Void, Never>?
    private var startToken = UUID()

    func start(language: AppLanguage) async {
        stop()
        let token = UUID()
        startToken = token
        transcript = ""
        errorMessage = nil
        didReachRecordingLimit = false
        isPreparing = true
        defer {
            if startToken == token {
                isPreparing = false
            }
        }

        guard await hasPermissions() else {
            guard startToken == token else { return }
            errorMessage = "Разрешите доступ к микрофону и распознаванию речи."
            return
        }

        guard startToken == token else { return }

        let recognizer = SFSpeechRecognizer(locale: language.locale)
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Распознавание речи сейчас недоступно."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if let error, !self.isRecording {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
            audioEngine.prepare()
            try audioEngine.start()
            recordingStartedAt = .now
            isRecording = true
            recordingLimitTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Self.maximumRecordingDuration))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.stop(reachedLimit: true)
            }
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    func stop(reachedLimit: Bool = false) {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        guard isRecording || recognitionTask != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        recordingStartedAt = nil
        didReachRecordingLimit = reachedLimit
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func reset() {
        startToken = UUID()
        isPreparing = false
        stop()
        transcript = ""
        errorMessage = nil
        didReachRecordingLimit = false
    }

    /// Requests the system permissions after Nodus has explained why they are needed.
    func requestPermissions() async -> Bool {
        await hasPermissions()
    }

    private func hasPermissions() async -> Bool {
        let speech = await requestSpeechAuthorization()
        guard speech == .authorized else { return false }
        return await requestMicrophonePermission()
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}

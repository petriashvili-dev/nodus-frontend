import AppIntents

/// A control itself cannot record through the microphone while the device is
/// locked. It hands off to the app's voice composer instead.
struct OpenVoiceInputIntent: OpenIntent {
    static var title: LocalizedStringResource = "Voice Knot"
    static var description = IntentDescription("Open Nodus ready to create a knot by voice.")

    @Parameter(title: "Target", default: .composer)
    var target: VoiceInputTarget

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: "group.app.nodus")?.set(true, forKey: "openVoiceComposerFromControl")
        return .result()
    }
}

enum VoiceInputTarget: String, AppEnum {
    case composer

    static var typeDisplayRepresentation = TypeDisplayRepresentation("Nodus screen")
    static var caseDisplayRepresentations: [VoiceInputTarget: DisplayRepresentation] = [
        .composer: "Voice Knot"
    ]
}

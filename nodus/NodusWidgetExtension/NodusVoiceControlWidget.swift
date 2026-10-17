import AppIntents
import SwiftUI
import WidgetKit

struct NodusVoiceControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.nodus.voice-knot") {
            ControlWidgetButton(action: OpenVoiceInputIntent()) {
                Label("Voice Knot", systemImage: "mic.fill")
            }
        }
        .displayName("Voice Knot")
        .description("Open Nodus ready for a spoken knot.")
    }
}

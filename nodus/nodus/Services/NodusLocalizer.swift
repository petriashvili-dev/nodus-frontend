import Foundation
import Combine
import SwiftUI

@MainActor
final class NodusLocalizer: ObservableObject {
    @Published var language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    func update(language: AppLanguage) {
        self.language = language
    }

    func string(_ key: String) -> String {
        language.localizedString(key)
    }
}

struct LocalizedText: View {
    @EnvironmentObject private var localizer: NodusLocalizer
    let key: String

    var body: some View {
        Text(localizer.string(key))
    }
}

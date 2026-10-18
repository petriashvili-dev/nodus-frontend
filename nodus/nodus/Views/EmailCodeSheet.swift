import SwiftUI

/// Email + 6-digit code, for saving the account (linking an email) or
/// restoring one on a new device. The server answers the first step the
/// same way for any address.
struct EmailCodeSheet: View {
    enum Mode {
        /// "Save account": the same account gets an email.
        case link
        /// "Restore account": sign in to another account; this device's
        /// anonymous data is not carried over.
        case recover
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let language: AppLanguage
    let account: AccountService
    let completed: () -> Void

    @State private var email = ""
    @State private var code = ""
    @State private var isCodeStep = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var resendAvailableAt: Date?

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()

            VStack(spacing: 0) {
                NodusSheetDragIndicator()
                header
                NodusOrnamentDivider()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        if mode == .recover && !isCodeStep {
                            recoveryWarning
                        }
                        form
                        primaryButton
                        if isCodeStep {
                            resendButton
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 34)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(NodusPalette.background)
    }

    private var recoveryWarning: some View {
        NodusSheetSection {
            Text(language.localizedString("Knots of the current anonymous account on this device will not be carried over."))
                .font(.cormorant(17, weight: .regular))
                .lineSpacing(4)
                .foregroundStyle(NodusPalette.secondary.opacity(0.86))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var form: some View {
        NodusSheetSection {
            if isCodeStep {
                Text(String(format: language.localizedString("We sent a code to %@"), email))
                    .font(.system(size: 13))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)
                codeField
            } else {
                emailField
            }
            if let message {
                NodusInlineValidation(text: LocalizedStringKey(message))
            }
        }
    }

    private var emailField: some View {
        NodusTextField(
            title: LocalizedStringKey(language.localizedString("Email")),
            placeholder: "name@example.com",
            text: $email,
            submitLabel: .send,
            onSubmit: start
        )
        .keyboardType(.emailAddress)
        .textContentType(.emailAddress)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private var codeField: some View {
        NodusTextField(
            title: LocalizedStringKey(language.localizedString("Code from the email")),
            placeholder: "000000",
            text: $code,
            submitLabel: .done,
            onSubmit: verify
        )
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
    }

    private var primaryButton: some View {
        let isDisabled = isWorking || !canSubmit
        return NodusActionButton(
            title: LocalizedStringKey(language.localizedString(isCodeStep ? "Confirm" : "Get a code")),
            systemName: isCodeStep ? "checkmark" : "envelope",
            tone: .primary
        ) {
            if isCodeStep { verify() } else { start() }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }

    private var resendButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Int((resendAvailableAt ?? .distantPast).timeIntervalSince(context.date).rounded(.up))
            let title = remaining > 0
                ? String(format: language.localizedString("Send again in %d s"), remaining)
                : language.localizedString("Send the code again")
            NodusActionButton(title: LocalizedStringKey(title), systemName: "arrow.clockwise", action: start)
                .disabled(remaining > 0 || isWorking)
                .opacity(remaining > 0 ? 0.5 : 1)
        }
    }

    private var title: String {
        language.localizedString(mode == .link ? "Save account" : "Restore account")
    }

    private var canSubmit: Bool {
        isCodeStep
            ? code.filter(\.isNumber).count == 6
            : email.contains("@") && email.contains(".")
    }

    private var header: some View {
        HStack {
            IconCircleButton(systemName: "xmark", accessibilityLabel: "Close") { dismiss() }
            Spacer()
            Text(title)
                .font(.cormorant(21, weight: .light, italic: true))
                .foregroundStyle(NodusPalette.primary.opacity(0.94))
            Spacer()
            Color.clear.frame(width: 46, height: 42)
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 4)
    }

    private func start() {
        guard canSubmit || isCodeStep else { return }
        run {
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            switch mode {
            case .link: try await account.startLinkingEmail(address)
            case .recover: try await account.startRecovery(address)
            }
            resendAvailableAt = Date().addingTimeInterval(60)
            isCodeStep = true
        }
    }

    private func verify() {
        guard canSubmit else { return }
        run {
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = code.filter(\.isNumber)
            switch mode {
            case .link: try await account.verifyLinkingEmail(address, code: digits)
            case .recover: try await account.completeRecovery(address, code: digits)
            }
            completed()
            dismiss()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await work()
            } catch let error as AccountService.EmailError {
                message = language.localizedString(Self.messageKey(for: error))
            } catch {
                message = language.localizedString("Something went wrong. Try again")
            }
        }
    }

    private static func messageKey(for error: AccountService.EmailError) -> String {
        switch error {
        case .invalidEmail: "Check the email address"
        case .invalidCode: "Wrong or expired code"
        case .alreadyLinked: "This email is linked to another account — use Restore account"
        case .tooManyRequests: "Too many attempts. Try again a bit later"
        case .offline: "No connection"
        case .failed: "Something went wrong. Try again"
        }
    }
}

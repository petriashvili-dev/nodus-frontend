import SwiftUI

/// "Connections" in Settings: people a knot can be shared with.
struct ConnectionsSection: View {
    @ObservedObject var connections: ConnectionsService
    @ObservedObject var account: AccountService
    let language: AppLanguage
    let toast: (String) -> Void
    @State private var isInviting = false
    @State private var isEnteringCode = false
    @State private var breaking: Connection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(connections.connections.filter(\.awaitingMyConfirmation)) { connection in
                NodusSheetSection {
                    Text(String(format: language.localizedString("%@ accepted your invitation"), name(of: connection)))
                        .font(.cormorant(19, weight: .regular))
                        .foregroundStyle(NodusPalette.primary.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    NodusActionButton(title: LocalizedStringKey(language.localizedString("Confirm")), systemName: "checkmark", tone: .primary) {
                        try? connections.confirm(connection)
                    }
                    NodusActionButton(title: LocalizedStringKey(language.localizedString("Decline")), systemName: "xmark") {
                        try? connections.remove(connection)
                    }
                }
            }

            let waiting = connections.connections.filter { !$0.isActive && !$0.awaitingMyConfirmation }
            if !waiting.isEmpty {
                NodusSheetSection(title: LocalizedStringKey(language.localizedString("Waiting"))) {
                    ForEach(waiting) { connection in
                        NodusInfoRow(
                            title: LocalizedStringKey(name(of: connection)),
                            value: language.localizedString("Waiting for confirmation")
                        )
                    }
                }
            }

            NodusSheetSection(title: LocalizedStringKey(language.localizedString("Connections"))) {
                if connections.active.isEmpty {
                    Text(language.localizedString("Invite someone you trust to share knots with them."))
                        .font(.system(size: 13))
                        .foregroundStyle(NodusPalette.secondary.opacity(0.78))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(connections.active) { connection in
                        HStack {
                            Text(name(of: connection))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(NodusPalette.primary.opacity(0.88))
                            Spacer()
                            Button {
                                breaking = connection
                            } label: {
                                Image(systemName: "person.crop.circle.badge.minus")
                                    .foregroundStyle(NodusPalette.secondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(language.localizedString("Break the connection"))
                        }
                    }
                }
            }

            NodusActionButton(title: LocalizedStringKey(language.localizedString("Invite")), systemName: "person.badge.plus", tone: .primary) {
                isInviting = true
            }
            NodusActionButton(title: LocalizedStringKey(language.localizedString("Enter a code")), systemName: "number") {
                isEnteringCode = true
            }
        }
        .onAppear { connections.reload() }
        .sheet(isPresented: $isInviting) {
            InviteSheet(connections: connections, account: account, language: language)
        }
        .sheet(isPresented: $isEnteringCode) {
            AcceptCodeSheet(connections: connections, language: language, toast: toast)
        }
        .alert(
            language.localizedString("Break the connection?"),
            isPresented: Binding(get: { breaking != nil }, set: { if !$0 { breaking = nil } })
        ) {
            Button(language.localizedString("Break"), role: .destructive) {
                if let breaking { try? connections.remove(breaking) }
                breaking = nil
            }
            Button(language.localizedString("Cancel"), role: .cancel) { breaking = nil }
        } message: {
            Text(language.localizedString("Knots shared between you will stop being shared."))
        }
    }

    private func name(of connection: Connection) -> String {
        connection.displayName ?? language.localizedString("No name")
    }
}

/// A one-time invite: a link to send and a code to dictate. Valid for 24 h.
struct InviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var connections: ConnectionsService
    @ObservedObject var account: AccountService
    let language: AppLanguage
    @State private var invite: InviteDTO?
    @State private var message: String?
    @State private var name = ""
    @State private var isLoading = false

    var body: some View {
        NodusPlainSheetScaffold(title: LocalizedStringKey(language.localizedString("Invite")), close: { dismiss() }) {
            // Connections see this name; offer it before the first invite.
            if (account.profile?.displayName ?? "").isEmpty && invite == nil {
                NodusSheetSection {
                    NodusTextField(
                        title: LocalizedStringKey(language.localizedString("Name")),
                        placeholder: LocalizedStringKey(language.localizedString("How your connections see you")),
                        text: $name
                    )
                }
            }

            if let invite {
                NodusSheetSection(title: LocalizedStringKey(language.localizedString("Code"))) {
                    Text(invite.groupedCode)
                        .font(.system(size: 34, weight: .medium, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color(hex: 0xF5D7A8))
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                        .accessibilityLabel(invite.code.map(String.init).joined(separator: " "))
                    Text(language.localizedString("Valid for 24 hours, once"))
                        .font(.system(size: 12))
                        .foregroundStyle(NodusPalette.secondary.opacity(0.7))
                        .frame(maxWidth: .infinity)
                }
                ShareLink(item: invite.link) {
                    Label(language.localizedString("Share the link"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(hex: 0xF5D7A8))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(NodusPalette.accent.opacity(0.16), in: Capsule(style: .continuous))
                        .overlay { Capsule(style: .continuous).stroke(NodusPalette.accent.opacity(0.34), lineWidth: 1) }
                }
                NodusActionButton(title: LocalizedStringKey(language.localizedString("Revoke the invite")), systemName: "xmark", tone: .destructive) {
                    Task {
                        await connections.revokeInvite(invite)
                        dismiss()
                    }
                }
            } else {
                NodusActionButton(title: LocalizedStringKey(language.localizedString("Create an invite")), systemName: "link", tone: .primary) {
                    create()
                }
                .disabled(isLoading)
                .opacity(isLoading ? 0.5 : 1)
            }

            if let message {
                NodusInlineValidation(text: LocalizedStringKey(message))
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { try? account.updateDisplayName(trimmed) }
        isLoading = true
        message = nil
        Task {
            defer { isLoading = false }
            do {
                invite = try await connections.createInvite()
            } catch ConnectionsService.InviteError.tooManyInvites {
                message = language.localizedString("Too many active invites. Revoke one or wait a day")
            } catch ConnectionsService.InviteError.offline {
                message = language.localizedString("No connection")
            } catch {
                message = language.localizedString("Something went wrong. Try again")
            }
        }
    }
}

struct AcceptCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var connections: ConnectionsService
    let language: AppLanguage
    let toast: (String) -> Void
    @State private var code = ""
    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        NodusPlainSheetScaffold(title: LocalizedStringKey(language.localizedString("Enter a code")), close: { dismiss() }) {
            NodusSheetSection {
                NodusTextField(
                    title: LocalizedStringKey(language.localizedString("Invitation code")),
                    placeholder: "K7M2 Q9TP",
                    text: $code,
                    submitLabel: .done,
                    onSubmit: accept
                )
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                if let message {
                    NodusInlineValidation(text: LocalizedStringKey(message))
                }
            }
            NodusActionButton(title: LocalizedStringKey(language.localizedString("Connect")), systemName: "link", tone: .primary, action: accept)
                .disabled(isWorking || code.filter(\.isLetter).count + code.filter(\.isNumber).count < 6)
        }
    }

    private func accept() {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                let connection = try await connections.accept(code: code)
                toast(InviteResult.message(for: connection, language: language))
                dismiss()
            } catch let error as ConnectionsService.InviteError {
                message = InviteResult.message(for: error, language: language)
            } catch {
                message = language.localizedString("Something went wrong. Try again")
            }
        }
    }
}

/// What accepting an invitation says, shared by the code sheet and links.
enum InviteResult {
    static func message(for connection: ConnectionDTO, language: AppLanguage) -> String {
        if connection.status == "active" {
            return language.localizedString("Connected")
        }
        let name = connection.displayName ?? language.localizedString("No name")
        return String(format: language.localizedString("Waiting for %@ to confirm"), name)
    }

    static func message(for error: ConnectionsService.InviteError, language: AppLanguage) -> String {
        switch error {
        case .invalid: language.localizedString("The invitation is invalid or has expired")
        case .ownInvite: language.localizedString("This is your own invitation")
        case .alreadyConnected: language.localizedString("You are already connected")
        case .tooManyInvites: language.localizedString("Too many active invites. Revoke one or wait a day")
        case .offline: language.localizedString("No connection")
        case .failed: language.localizedString("Something went wrong. Try again")
        }
    }
}

import SwiftUI

struct NotificationPermissionPromptView: View {
    @Environment(\.dismiss) private var dismiss
    let allow: () async -> Void
    let notNow: () async -> Void

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
                        NodusSheetSection(title: "Thread of Time") {
                            VStack(spacing: 20) {
                                NodusKnotShape()
                                    .stroke(NodusPalette.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                    .frame(width: 76, height: 96)

                                VStack(spacing: 12) {
                                    Text("Never lose a knot.")
                                        .font(.cormorant(28, weight: .regular, italic: true))
                                        .foregroundStyle(NodusPalette.primary.opacity(0.94))

                                    VStack(spacing: 16) {
                                        Text("Nodus can gently keep the knots you tie within reach.")
                                        Text("Notifications are used only for knots you tie yourself.")
                                        Text("Nothing more.")
                                    }
                                    .font(.cormorant(17, weight: .regular))
                                    .lineSpacing(5)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(NodusPalette.secondary.opacity(0.82))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        }

                        NodusSheetSection(title: "Notification") {
                            NodusActionButton(title: "Allow Notifications", systemName: "bell", tone: .primary) {
                                Task {
                                    await allow()
                                    dismiss()
                                }
                            }

                            NodusActionButton(title: "Not Now", systemName: "bell.slash") {
                                Task {
                                    await notNow()
                                    dismiss()
                                }
                            }
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

    private var header: some View {
        HStack {
            IconCircleButton(systemName: "xmark", accessibilityLabel: "Close") {
                dismiss()
            }

            Spacer()

            Text("Notifications")
                .font(.cormorant(21, weight: .light, italic: true))
                .foregroundStyle(NodusPalette.primary.opacity(0.94))

            Spacer()

            Color.clear
                .frame(width: 46, height: 42)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

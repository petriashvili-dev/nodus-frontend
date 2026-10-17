import SwiftUI

/// The translucent fill shared by the primary creation controls on the home screen.
struct NodusTranslucentCapsuleBackground: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(Color(hex: 0x0B1020).opacity(0.58))
            .overlay {
                Capsule(style: .continuous)
                    .fill(NodusPalette.accent.opacity(0.05))
            }
    }
}

struct NewNodeButton: View {
    enum IconAlignment {
        case leading
        case trailing
    }

    var title: String
    var systemName: String? = nil
    var iconAlignment: IconAlignment = .leading
    var height: CGFloat = 46
    var minimumWidth: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if iconAlignment == .leading {
                    icon
                }

                Text(title)
                    .font(.cormorant(height > 46 ? 17 : 16, weight: .regular))

                if iconAlignment == .trailing {
                    icon
                }
            }
            .foregroundStyle(Color(hex: 0xF5D7A8).opacity(0.9))
            .padding(.horizontal, height > 46 ? 21 : 18)
            .frame(minWidth: minimumWidth)
            .frame(height: height)
            .background {
                NodusTranslucentCapsuleBackground()
            }
            .overlay {
                // Traces the border itself rather than just casting an
                // ambient shadow behind the whole shape, so the glow reads
                // as coming from the edge.
                Capsule(style: .continuous)
                    .stroke(Color(hex: 0xF7D9A5).opacity(0.4), lineWidth: 2.5)
                    .blur(radius: 3.5)
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(hex: 0xF0C98B).opacity(0.55),
                                NodusPalette.accent.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.22), radius: 16, y: 10)
            .shadow(color: NodusPalette.accent.opacity(0.08), radius: 16)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(NodeButtonStyle(intensity: .subtle))
        .accessibilityLabel(Text(title))
    }

    @ViewBuilder
    private var icon: some View {
        if let systemName {
            Image(systemName: systemName)
                .font(.system(size: height > 46 ? 15 : 14, weight: .medium))
        }
    }
}

struct IconCircleButton: View {
    let systemName: String
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(Color(hex: 0xF5D7A8).opacity(0.86))
                .frame(width: 46, height: 42)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color(hex: 0x0B1020).opacity(0.58))
                        .overlay {
                            Capsule(style: .continuous)
                                .fill(NodusPalette.accent.opacity(0.05))
                        }
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(hex: 0xF0C98B).opacity(0.44),
                                    NodusPalette.accent.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                .shadow(color: NodusPalette.accent.opacity(0.06), radius: 14)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(NodeButtonStyle(intensity: .subtle))
        .accessibilityLabel(accessibilityLabel)
    }
}

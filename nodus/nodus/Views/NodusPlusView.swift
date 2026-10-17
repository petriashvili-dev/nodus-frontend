import SwiftUI

struct NodusPlusView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: SettingsStore

    private var language: AppLanguage { settings.appLanguage }

    private let benefits: [(title: String, detail: String, symbol: String)] = [
        ("Voice", "Tie a knot by saying what matters.", "waveform"),
        ("Siri", "Create a knot without opening Nodus.", "sparkles"),
        ("Share text", "Turn any text into knots.", "square.and.arrow.up"),
        ("Thread continuation", "Nodus suggests what might come next.", "arrow.triangle.branch")
    ]

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()

            VStack(spacing: 0) {
                NodusSheetDragIndicator()
                header
                NodusOrnamentDivider()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 32) {
                        introduction
                        benefitsList
                        actionArea
                        previewControl
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 34)
                    .padding(.bottom, 32)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(NodusPalette.background)
        .sensoryFeedback(.selection, trigger: settings.isNodusPlusActive)
    }

    private var header: some View {
        HStack {
            IconCircleButton(systemName: "chevron.left", accessibilityLabel: "Close") { dismiss() }
            Spacer()
            Text(language.localizedString("Subscription"))
                .font(.cormorant(22, weight: .light, italic: true))
                .foregroundStyle(NodusPalette.primary.opacity(0.94))
            Spacer()
            Color.clear.frame(width: 46, height: 42)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.localizedString(settings.isNodusPlusActive ? "Nodus+ is with you." : "Unlock Nodus+"))
                .font(.cormorant(34, weight: .regular))
                .foregroundStyle(NodusPalette.primary.opacity(0.95))

            Text(language.localizedString(settings.isNodusPlusActive ? "All possibilities are already available." : "More possibilities for your thread."))
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(NodusPalette.secondary.opacity(0.8))
                .lineSpacing(3)

        }
    }

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(benefits, id: \.title) { benefit in
                SubscriptionBenefitRow(
                    title: language.localizedString(benefit.title),
                    detail: language.localizedString(benefit.detail),
                    symbol: benefit.symbol,
                    isActive: settings.isNodusPlusActive
                )
            }
        }
    }

    @ViewBuilder private var actionArea: some View {
        if settings.isNodusPlusActive {
            NewNodeButton(
                title: language.localizedString("Manage subscription"),
                systemName: "arrow.up.right",
                iconAlignment: .trailing,
                height: 58,
                minimumWidth: 276
            ) { }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            NewNodeButton(
                title: language.localizedString("Get Nodus+"),
                systemName: nil,
                height: 58,
                minimumWidth: 276
            ) { }
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var previewControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.localizedString("Preview"))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(NodusPalette.secondary.opacity(0.55))

            NodusToggleRow(
                title: LocalizedStringKey(language.localizedString("Subscription active")),
                subtitle: nil,
                hapticsEnabled: settings.hapticsEnabled,
                isOn: $settings.isNodusPlusActive
            )
        }
        .padding(.top, 8)
    }

}

private struct SubscriptionBenefitRow: View {
    let title: String
    let detail: String
    let symbol: String
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NodusPalette.accent.opacity(isActive ? 0.94 : 0.56))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.cormorant(23, weight: .medium))
                        .foregroundStyle(NodusPalette.primary.opacity(0.94))
                }
                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.76))
                    .lineSpacing(2)
            }
            .padding(.top, 4)
        }
        .frame(height: 76, alignment: .top)
    }
}

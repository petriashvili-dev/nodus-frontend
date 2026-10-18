import WidgetKit
import SwiftUI
import CoreText

// MARK: - Shared App Group

/// Must match the app group registered in both `nodus.entitlements` and
/// `NodusWidgetExtension.entitlements`; the app writes the widget snapshot
/// there.
let nodusAppGroupID = "group.app.nodus"

private enum WidgetFontRegistrar {
    private static var didRegister = false

    static func registerCustomFontsIfNeeded() {
        guard !didRegister else { return }
        didRegister = true

        for name in ["CormorantGaramond-Light", "CormorantGaramond-Regular", "CormorantGaramond-LightItalic"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

private extension Font {
    static func nodusCormorant(_ size: CGFloat, weight: Weight = .regular, italic: Bool = false) -> Font {
        let name: String
        switch (weight, italic) {
        case (.light, true): name = "CormorantGaramondItalic-LightItalic"
        case (.light, false): name = "CormorantGaramond-Light"
        default: name = "CormorantGaramond-Regular"
        }
        return .custom(name, size: size)
    }
}

// MARK: - Shared read model
//
// The widget never opens the app's SwiftData store: a second copy of the
// schema in this target could drift and make SwiftData migrate the shared
// store to the wrong shape. Instead the app writes a small JSON snapshot of
// the knots it would show (`WidgetSnapshotWriter` in the app) to the app
// group, and the widget only reads it. Keep `WidgetSnapshot` in sync with
// the app's copy by hand — it is the whole contract between the two.

struct WidgetSnapshot: Codable {
    struct Item: Codable {
        let id: String
        let title: String
        let date: Date
    }

    /// Active (tied) occurrences of today and tomorrow, already filtered for
    /// pauses and hidden occurrences by the app. Tomorrow's items keep the
    /// widget right after midnight even if the app has not run yet.
    let items: [Item]
    let generatedAt: Date

    static let fileName = "widget-snapshot.json"

    static func load() -> WidgetSnapshot? {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: nodusAppGroupID)?
            .appending(path: fileName),
            let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

// MARK: - Today's nodes

struct TodayWidgetNode: Identifiable {
    let id: String
    let title: String
    let date: Date
}

func fetchTodayNodes(now: Date = Date()) -> [TodayWidgetNode] {
    let calendar = Calendar.current
    return (WidgetSnapshot.load()?.items ?? [])
        .filter { calendar.isDateInToday($0.date) && $0.date >= now }
        .map { TodayWidgetNode(id: $0.id, title: $0.title, date: $0.date) }
        .sorted { $0.date < $1.date }
}

/// Past active occurrences are represented only by the lost-knot counter in
/// the header, never as rows in the upcoming list.
func fetchLostNodeCount(now: Date = Date()) -> Int {
    let calendar = Calendar.current
    return (WidgetSnapshot.load()?.items ?? [])
        .filter { calendar.isDate($0.date, inSameDayAs: now) && $0.date < now }
        .count
}

// MARK: - Empty-thread phrases
//
// A small, day-stable set of empty-state phrases. Choosing from the entry
// provider (rather than the view) prevents the wording from changing while
// WidgetKit redraws the same timeline entry.

func emptyThreadPhrase(now: Date = Date()) -> String {
    let phrases = [
        String(localized: "Today the thread is free"),
        String(localized: "Nothing is tied today yet"),
        String(localized: "No knots are tied today."),
        String(localized: "Today is still open."),
        String(localized: "There is room for a new knot."),
    ]

    // Deterministic per calendar day (no shared state with the app) so the
    // phrase doesn't flicker between every widget refresh.
    let dayKey = Calendar.current.dateComponents([.year, .month, .day], from: now)
    let seed = (dayKey.year ?? 0) * 10_000 + (dayKey.month ?? 0) * 100 + (dayKey.day ?? 0)
    return phrases[seed % phrases.count]
}

// MARK: - Timeline provider

// MARK: - Widget view

private struct TodayWidgetTitle: View {
    let lostCount: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(String(localized: "Today"))
                .font(.nodusCormorant(25))

            if lostCount > 0 {
                Text("·")
                    .font(.nodusCormorant(20, weight: .light))
                    .foregroundStyle(.white.opacity(0.48))
                Text(lostKnotsText(count: lostCount))
                    .font(.nodusCormorant(15, weight: .light))
                    .foregroundStyle(.white.opacity(0.64))
            }
        }
        .foregroundStyle(.white.opacity(0.94))
        .accessibilityLabel(lostCount > 0
            ? "\(String(localized: "Today")), \(lostKnotsText(count: lostCount))"
            : String(localized: "Today"))
    }
}

private func lostKnotsText(count: Int) -> String {
    let languageCode = Locale.current.language.languageCode?.identifier
    let usesRussianForms = languageCode == "ru"
    let remainder100 = count % 100
    let remainder10 = count % 10
    let singular = remainder10 == 1 && remainder100 != 11
    let paucal = (2...4).contains(remainder10) && !(12...14).contains(remainder100)

    if usesRussianForms && singular {
        return "\(count) \(String(localized: "Lost knots one"))"
    }
    if usesRussianForms && paucal {
        return "\(count) \(String(localized: "Lost knots few"))"
    }
    return "\(count) \(String(localized: "Lost knots many"))"
}

private struct TodayWidgetAddButton: View {
    private let createURL = URL(string: "nodus://create")!
    private let bronze = Color(red: 0.79, green: 0.64, blue: 0.42)
    private let warmGold = Color(red: 0.969, green: 0.851, blue: 0.647)
    private let midnight = Color(red: 0.043, green: 0.063, blue: 0.125)

    var body: some View {
        Link(destination: createURL) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(warmGold.opacity(0.9))
                .frame(width: 36, height: 36)
                .background {
                    Circle()
                        .fill(midnight.opacity(0.58))
                        .overlay {
                            Circle()
                                .fill(bronze.opacity(0.05))
                        }
                }
                .overlay {
                    Circle()
                        .stroke(warmGold.opacity(0.32), lineWidth: 2.5)
                        .blur(radius: 3)
                }
                .overlay {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [warmGold.opacity(0.52), bronze.opacity(0.20)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: bronze.opacity(0.16), radius: 10)
        }
        .accessibilityLabel(String(localized: "Tie a Knot"))
    }
}

// MARK: - Today's thread widget

struct NodusTodayEntry: TimelineEntry {
    let date: Date
    let nodes: [TodayWidgetNode]
    let lostCount: Int
    let emptyPhrase: String
}

struct NodusTodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> NodusTodayEntry {
        NodusTodayEntry(date: .now, nodes: [
            TodayWidgetNode(id: "1", title: String(localized: "Knot"), date: .now),
            TodayWidgetNode(id: "2", title: String(localized: "Knot"), date: .now.addingTimeInterval(3_600))
        ], lostCount: 0, emptyPhrase: emptyThreadPhrase())
    }

    func getSnapshot(in context: Context, completion: @escaping (NodusTodayEntry) -> Void) {
        Task { @MainActor in completion(makeEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NodusTodayEntry>) -> Void) {
        Task { @MainActor in
            let now = Date()
            let calendar = Calendar.current
            let transitionDates = fetchTodayNodes(now: now)
                .map(\.date)
                .filter { $0 > now && calendar.isDateInToday($0) }
                .map { $0.addingTimeInterval(1) }

            let entryDates = ([now] + transitionDates)
                .sorted()
                .reduce(into: [Date]()) { dates, date in
                    if dates.last != date { dates.append(date) }
                }
            let entries = entryDates.map { makeEntry(now: $0) }
            let nextMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                ?? now.addingTimeInterval(24 * 60 * 60)

            completion(Timeline(entries: entries, policy: .after(nextMidnight)))
        }
    }

    @MainActor
    private func makeEntry(now: Date = .now) -> NodusTodayEntry {
        NodusTodayEntry(
            date: now,
            nodes: fetchTodayNodes(now: now),
            lostCount: fetchLostNodeCount(now: now),
            emptyPhrase: emptyThreadPhrase(now: now)
        )
    }
}

struct NodusTodayWidgetView: View {
    let entry: NodusTodayEntry
    private let bronze = Color(red: 0.79, green: 0.64, blue: 0.42)

    private var visibleNodes: [TodayWidgetNode] {
        Array(entry.nodes.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entry.nodes.isEmpty {
                Spacer()
                Text(entry.emptyPhrase)
                    .font(.nodusCormorant(18, weight: .light, italic: true))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
            } else {
                VStack(spacing: 12) {
                    ForEach(visibleNodes) { node in
                        TodayThreadRow(node: node, bronze: bronze)
                    }
                }
            }
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom)
        .overlay(alignment: .topLeading) {
            TodayWidgetTitle(lostCount: entry.lostCount)
                .padding(.top, 12)
                .padding(.leading, 12)
        }
        .overlay(alignment: .topTrailing) {
            TodayWidgetAddButton()
                .padding(.top, 12)
                .padding(.trailing, 8)
        }
        .foregroundStyle(.white.opacity(0.92))
        .containerBackground(for: .widget) {
            WidgetTimeBackdrop(date: entry.date)
        }
    }
}

/// A static, WidgetKit-safe echo of the app's time-of-day backdrop. Widgets
/// redraw from their timeline rather than running the main app's continuous
/// drift animation, but use the same light curve and night-star transition.
private struct WidgetTimeBackdrop: View {
    let date: Date

    private let background = Color(red: 0.043, green: 0.063, blue: 0.125)
    private let bronze = Color(red: 0.79, green: 0.64, blue: 0.42)
    private let cool = Color(red: 0.58, green: 0.64, blue: 0.72)

    var body: some View {
        let light = WidgetAmbientLight(date: date)

        ZStack {
            background

            RadialGradient(
                colors: [bronze.opacity(light.warmIntensity), bronze.opacity(light.warmIntensity * 0.45), .clear],
                center: light.anchor,
                startRadius: 8,
                endRadius: light.primaryRadius
            )

            RadialGradient(
                colors: [cool.opacity(light.coolIntensity), cool.opacity(light.coolIntensity * 0.4), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 300
            )

            RadialGradient(
                colors: [bronze.opacity(light.accentIntensity), .clear],
                center: UnitPoint(x: 0.78, y: 0.62),
                startRadius: 20,
                endRadius: 240
            )

            RadialGradient(
                colors: [.clear, Color.black.opacity(light.vignette)],
                center: .center,
                startRadius: 90,
                endRadius: 300
            )

            Color.black.opacity(light.nightDarken)
            WidgetStarField(visibility: light.starVisibility)
        }
    }
}

private struct WidgetAmbientLight {
    let anchor: UnitPoint
    let warmIntensity: Double
    let coolIntensity: Double
    let accentIntensity: Double
    let primaryRadius: CGFloat
    let vignette: Double
    let nightDarken: Double
    let starVisibility: Double

    init(date: Date) {
        let calendar = Calendar.current
        let time = Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
        let morning = Self.bell(time, center: 8, width: 2.6)
        let day = Self.bell(time, center: 14, width: 4.0)
        let evening = Self.bell(time, center: 19.5, width: 2.2)
        let night = max(0, 1 - morning - day - evening)

        anchor = UnitPoint(x: 0.5, y: 0.12 * morning + 0.26 * day + 0.52 * evening + 0.38 * night)
        warmIntensity = 0.34 * morning + 0.16 * day + 0.40 * evening
        coolIntensity = 0.14 * morning + 0.30 * day + 0.10 * evening
        accentIntensity = 0.10 * morning + 0.07 * day + 0.16 * evening
        primaryRadius = 240 + 90 * day + 45 * morning
        vignette = 0.06 + 0.16 * evening + 0.30 * night
        nightDarken = 0.22 * night
        starVisibility = min(1, 0.4 * evening + night)
    }

    private static func bell(_ time: Double, center: Double, width: Double) -> Double {
        let delta = min(abs(time - center), 24 - abs(time - center))
        return exp(-(delta * delta) / (2 * width * width))
    }
}

private struct WidgetStarField: View {
    let visibility: Double

    private static let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (0.14, 0.09, 1.6, 0.55), (0.78, 0.06, 1.2, 0.40), (0.36, 0.14, 1.4, 0.48),
        (0.92, 0.20, 1.2, 0.38), (0.60, 0.10, 1.8, 0.60), (0.22, 0.24, 1.2, 0.36)
    ]

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(Self.stars.enumerated()), id: \.offset) { _, star in
                Circle()
                    .fill(.white.opacity(visibility * star.opacity))
                    .frame(width: star.size, height: star.size)
                    .position(x: geometry.size.width * star.x, y: geometry.size.height * star.y)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TodayThreadRow: View {
    let node: TodayWidgetNode
    let bronze: Color

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(node.date, style: .time)
                    .font(.nodusCormorant(15, weight: .light).monospacedDigit())
            }
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: 46, alignment: .leading)

            Circle()
                .fill(bronze)
                .frame(width: 7, height: 7)
                .overlay {
                    Circle()
                        .stroke(midnight.opacity(0.95), lineWidth: 3)
                        .padding(-3)
                }
                .frame(width: 10, height: 10)

            Text(node.title)
                .font(.nodusCormorant(18))
                .foregroundStyle(.white.opacity(0.91))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private let midnight = Color(red: 0.043, green: 0.063, blue: 0.125)
}

struct NodusThreeKnotsWidget: Widget {
    let kind = "NodusTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NodusTodayProvider()) { entry in
            NodusTodayWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Next 3 Knots Today"))
        .description(String(localized: "Shows the next 3 knots on today's thread."))
        .supportedFamilies([.systemMedium])
    }
}

@main
struct NodusWidgetBundle: WidgetBundle {
    init() {
        WidgetFontRegistrar.registerCustomFontsIfNeeded()
    }

    var body: some Widget {
        NodusThreeKnotsWidget()
        NodusVoiceControlWidget()
    }
}

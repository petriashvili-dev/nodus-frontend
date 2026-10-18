import Foundation
#if os(iOS)
import WidgetKit
#endif

/// The widget's read model: a small JSON file in the app group with the
/// active knots of today and tomorrow. The widget never opens the SwiftData
/// store (see `WidgetSnapshot` in NodusWidgetExtension, which must match).
nonisolated struct WidgetSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable {
        let id: String
        let title: String
        let date: Date
    }

    let items: [Item]
    let generatedAt: Date

    static let fileName = "widget-snapshot.json"
}

@MainActor
enum WidgetSnapshotWriter {
    private static var lastWritten: [WidgetSnapshot.Item]?

    /// Writes only when the visible content changed, then asks WidgetKit to
    /// reload — a per-minute clock tick must not churn the widget.
    static func write(sections: [TimelineSectionModel], now: Date = Date()) {
        let calendar = Calendar.current
        let items = sections
            .flatMap(\.items)
            .filter { item in
                guard let title = item.title, !title.isEmpty, item.status == .active, !item.isNow else { return false }
                return calendar.isDateInToday(item.scheduledAt) || calendar.isDateInTomorrow(item.scheduledAt)
            }
            .map { WidgetSnapshot.Item(id: $0.id, title: $0.title ?? "", date: $0.scheduledAt) }
        guard items != lastWritten else { return }
        lastWritten = items

        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NodusModelContainer.appGroupID)?
            .appending(path: WidgetSnapshot.fileName) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(WidgetSnapshot(items: items, generatedAt: now)) else { return }
        try? data.write(to: url, options: .atomic)
#if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
#endif
    }
}

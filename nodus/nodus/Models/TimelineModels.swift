import Foundation
import SwiftUI

enum TimelineSectionKind: Hashable {
    case yesterday
    case today
    case tomorrow
    case date(Date)
}

struct TimelineSectionModel: Identifiable {
    let id: String
    let kind: TimelineSectionKind
    let title: String
    let items: [TimelineItem]
}

struct TimelineItem: Identifiable, Hashable {
    let id: String
    let nodeId: UUID
    let occurrenceDate: Date?
    let title: String?
    let note: String?
    let kind: String
    let repeatSchedule: RepeatSchedule
    let originDate: Date?
    let scheduledAt: Date
    let status: NodeStatus
    let isNow: Bool
    let isLost: Bool
    let isQuiet: Bool
    let tintHex: UInt32

    var tint: Color { Color(hex: tintHex) }
    var isCompleted: Bool { status == .completed }
    var displayTime: String {
        scheduledAt.formatted(date: .omitted, time: .shortened)
    }

}

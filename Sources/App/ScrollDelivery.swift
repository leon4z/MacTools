import Foundation
import CoreGraphics

/// Quartz CGScrollPhase differs from NSEvent.Phase. Keep the protocol explicit.
struct ScrollDelivery {
    private(set) var active = false
    mutating func nextPhase() -> Int64 {
        defer { active = true }
        return Int64((active ? CGScrollPhase.changed : CGScrollPhase.began).rawValue)
    }
    mutating func finish(cancelled: Bool) -> Int64? {
        guard active else { return nil }
        active = false
        return Int64((cancelled ? CGScrollPhase.cancelled : CGScrollPhase.ended).rawValue)
    }
}

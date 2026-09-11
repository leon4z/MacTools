// MacTools adapter scaffolding for LinearMouse v0.11.4. No upstream app model dependencies.
import Foundation
protocol ImplicitInitable { init() }
enum Scheme { enum Scrolling {} }
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
extension Decimal { var asTruncatedDouble: Double { NSDecimalNumber(decimal: self).doubleValue } }

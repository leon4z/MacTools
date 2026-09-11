import Foundation

@main enum ScrollDeliveryTests {
    static func main() {
        var stream = ScrollDelivery()
        assert(stream.finish(cancelled: false) == nil)
        assert(stream.nextPhase() == 1)
        assert(stream.nextPhase() == 2)
        assert(stream.nextPhase() == 2)
        assert(stream.finish(cancelled: false) == 4)
        assert(stream.finish(cancelled: true) == nil)
        assert(stream.nextPhase() == 1)
        assert(stream.finish(cancelled: true) == 8)
        assert(!stream.active)
        print("ScrollDeliveryTests: 9 checks passed")
    }
}

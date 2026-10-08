import Foundation

private final class KeyboardState {
    var state: Bool?
    var writes: [Bool] = []
    var accepts = true
    var applies = true
    init(_ state: Bool?) { self.state = state }
    var keyboard: NativeCapsLock.Keyboard {
        .init(read: { self.state }, write: { target in
            self.writes.append(target)
            if self.accepts && self.applies { self.state = target }
            return self.accepts
        })
    }
}

@main enum NativeCapsLockTests {
    static func rejects(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("expected rejection") } catch {}
    }
    static func main() throws {
        // Observed failure: legacy lock=true while every keyboard/LED is off.
        // The toggle must follow device state and enable it on the first tap.
        let first = KeyboardState(false), second = KeyboardState(false)
        try NativeCapsLock.toggle(keyboards: [first.keyboard, second.keyboard])
        precondition(first.state == true && second.state == true)
        try NativeCapsLock.toggle(keyboards: [first.keyboard, second.keyboard])
        precondition(first.state == false && second.state == false)
        precondition(first.writes == [true, false] && second.writes == [true, false])

        first.state = true; second.state = false
        try NativeCapsLock.toggle(keyboards: [first.keyboard, second.keyboard])
        precondition(first.state == false && second.state == false, "mixed devices converge to off")
        second.state = nil; first.writes = []; second.writes = []
        rejects { try NativeCapsLock.toggle(keyboards: [first.keyboard, second.keyboard]) }
        precondition(first.writes.isEmpty && second.writes.isEmpty, "read failure must precede all writes")
        rejects { try NativeCapsLock.toggle(keyboards: []) }

        first.accepts = false
        rejects { try NativeCapsLock.toggle(keyboards: [first.keyboard]) }
        first.accepts = true; first.applies = false
        rejects { try NativeCapsLock.toggle(keyboards: [first.keyboard]) }
        precondition(first.state == false, "accepted but ineffective writes cannot report success")
        print("NativeCapsLockTests: device state, repeated taps, multiple keyboards and rejected/ineffective writes passed")
    }
}

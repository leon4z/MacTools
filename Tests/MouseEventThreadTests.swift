import Foundation

@main enum MouseEventThreadTests {
    static func main() {
        let thread = EventThread()
        for _ in 0..<5 {
            thread.start()
            precondition(thread.performAndWait { thread.isCurrent } == true)
            let fired = DispatchSemaphore(value: 0)
            let timer = thread.scheduleTimer(interval: 0.005, repeats: true) {
                precondition(thread.isCurrent)
                fired.signal()
            }
            precondition(timer != nil && fired.wait(timeout: .now() + 2) == .success)
            _ = thread.performAndWait { timer?.invalidate() }
            thread.stop()
            precondition(thread.runLoop == nil)
            precondition(!thread.perform { fatalError("stopped thread ran work") })
        }
        print("MouseEventThreadTests: 5 start/timer/stop cycles passed")
    }
}

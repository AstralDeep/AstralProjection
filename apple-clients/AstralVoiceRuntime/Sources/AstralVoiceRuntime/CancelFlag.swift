// A native atomic flag that a task-cancellation handler raises from any thread to make an in-flight prompt evaluation or token step stop.
// NativeModel hands one to every run; the flag outlives the run that uses it.
import CAstralLlama

final class CancelFlag: @unchecked Sendable {
    let handle: OpaquePointer

    init() {
        guard let handle = avr_cancel_new() else { fatalError("out of memory") }
        self.handle = handle
    }

    deinit { avr_cancel_free(handle) }

    func raise() { avr_cancel_raise(handle) }
}

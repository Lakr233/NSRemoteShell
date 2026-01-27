import Foundation

actor ForwardState {
    private var cancelled = false

    func cancel() {
        cancelled = true
    }

    func isCancelled() -> Bool {
        cancelled
    }
}

public actor PortForwardHandle {
    private let state: ForwardState

    init(state: ForwardState) {
        self.state = state
    }

    public func cancel() async {
        await state.cancel()
    }
}

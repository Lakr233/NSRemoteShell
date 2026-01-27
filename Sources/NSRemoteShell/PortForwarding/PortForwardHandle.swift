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
    public let boundPort: Int

    init(state: ForwardState, boundPort: Int) {
        self.state = state
        self.boundPort = boundPort
    }

    public func cancel() async {
        await state.cancel()
    }
}

import Synchronization

private final class SimulatedLoginItem: Sendable {
    struct State {
        var status: LoginItemStatus
        var registrations = 0
        var removals = 0
    }

    let state: Mutex<State>
    init(_ initial: LoginItemStatus) { state = Mutex(State(status: initial)) }
}

@main
struct LoginItemHarness {
    private enum SimulatedError: Error { case changedOrDenied }

    static func main() {
        run("disabled stays disabled", from: .notRegistered, request: false, after: .notRegistered, calls: (0, 0))
        run("enable reads the registered state", from: .notRegistered, request: true, after: .enabled, calls: (1, 0))
        run("pending approval differs from failure", from: .notRegistered, request: true, after: .requiresApproval,
            calls: (1, 0), throwsError: true)
        run("denied and unregistered", from: .notRegistered, request: true, after: .notRegistered,
            calls: (1, 0), throwsError: true, failed: true)
        run("do not reregister an enabled service", from: .enabled, request: true, after: .enabled, calls: (0, 0))
        run("pending registration can be withdrawn", from: .requiresApproval, request: false, after: .notRegistered, calls: (0, 1))
        run("read back a raced unregister", from: .enabled, request: false, after: .notRegistered, calls: (0, 1), throwsError: true)
        run("unavailable service performs no writes", from: .unavailable, request: true, after: .unavailable, calls: (0, 0))
        run("missing after register is not success", from: .notRegistered, request: true, after: .unavailable,
            calls: (1, 0), failed: true)
        print("9 synthetic login registration cases passed")
    }

    private static func run(_ label: String, from initial: LoginItemStatus, request: Bool,
                            after: LoginItemStatus, calls: (Int, Int),
                            throwsError: Bool = false, failed: Bool = false) {
        let fixture = SimulatedLoginItem(initial)
        let service = LoginItemRegistration(read: { fixture.state.withLock { $0.status } }, register: {
            fixture.state.withLock { $0.registrations += 1; $0.status = after }
            if throwsError { throw SimulatedError.changedOrDenied }
        }, unregister: {
            fixture.state.withLock { $0.removals += 1; $0.status = after }
            if throwsError { throw SimulatedError.changedOrDenied }
        })
        let result = service.setRequested(request)
        precondition(result == .init(status: after, failed: failed), label)
        fixture.state.withLock { state in
            precondition(state.registrations == calls.0 && state.removals == calls.1, label)
        }
    }
}

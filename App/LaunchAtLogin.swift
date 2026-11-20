import ServiceManagement
import SwiftUI
import Synchronization

enum LoginItemStatus: Equatable, Sendable {
    case notRegistered, enabled, requiresApproval, unavailable

    var isRequested: Bool { self == .enabled || self == .requiresApproval }
    var canChange: Bool { self != .unavailable }
}

struct LoginItemChange: Equatable, Sendable {
    let status: LoginItemStatus
    let failed: Bool
}

struct LoginItemRegistration: Sendable {
    let read: @Sendable () -> LoginItemStatus
    let register: @Sendable () throws -> Void
    let unregister: @Sendable () throws -> Void

    func setRequested(_ requested: Bool) -> LoginItemChange {
        let before = read()
        guard before.canChange, before.isRequested != requested else {
            return .init(status: before, failed: false)
        }
        do {
            if requested { try register() }
            else { try unregister() }
        } catch {
            // A denied or racing request may still have changed the service.
            // Read back; approval pending is different from a failed request.
        }
        let current = read()
        return .init(status: current, failed: !current.canChange || current.isRequested != requested)
    }

    static let native = Self(read: {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }, register: { try SMAppService.mainApp.register() },
    unregister: { try SMAppService.mainApp.unregister() })

    /// App smoke tests get an in-memory service and never write OS login items.
    static let synthetic: Self = {
        let fixture = LoginItemFixture()
        return .init(read: { fixture.status.withLock { $0 } },
                     register: { fixture.status.withLock { $0 = .requiresApproval } },
                     unregister: { fixture.status.withLock { $0 = .notRegistered } })
    }()
}

private final class LoginItemFixture: Sendable {
    let status = Mutex<LoginItemStatus>(.notRegistered)
}

struct LaunchAtLoginControls: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: LoginItemStatus?
    @State private var changing = false
    @State private var failed = false
    @State private var revision = 0
    private let registration = CommandLine.arguments.contains("--synthetic")
        ? LoginItemRegistration.synthetic : .native

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(get: { status?.isRequested == true }, set: setRequested))
                .disabled(changing || status?.canChange != true)
                .accessibilityIdentifier("launchAtLoginToggle")
            switch status {
            case .enabled:
                Text("Agent Dashboard will open when you sign in.").foregroundStyle(.secondary)
            case .requiresApproval:
                Text("To finish enabling launch at login, approve Agent Dashboard in System Settings → General → Login Items & Extensions.")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("loginItemApprovalRequired")
            case .unavailable:
                Text("macOS could not find a login service for this build.").foregroundStyle(.secondary)
            case .notRegistered, nil:
                EmptyView()
            }
            if changing { ProgressView().controlSize(.small) }
            if failed { Text("Could not change launch at login.").foregroundStyle(.red) }
        }
        .task(id: scenePhase) {
            guard scenePhase != .background, !changing else { return }
            let request = revision
            let service = registration
            let result = await Task.detached { service.read() }.value
            guard !Task.isCancelled, !changing, request == revision else { return }
            if status != result { failed = false }
            status = result
        }
    }

    private func setRequested(_ value: Bool) {
        guard !changing, status?.canChange == true else { return }
        revision &+= 1
        changing = true
        failed = false
        let service = registration
        Task {
            let result = await Task.detached { service.setRequested(value) }.value
            status = result.status
            failed = result.failed
            changing = false
        }
    }
}

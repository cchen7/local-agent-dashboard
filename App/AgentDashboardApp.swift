import AppKit
import SwiftUI

@main
struct AgentDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = DashboardModel()

    var body: some Scene {
        Window("Agent Dashboard", id: "dashboard") {
            DashboardWindowContent(model: model)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Sessions") { model.page = .sessions }.keyboardShortcut("1")
                Button("Projects") { model.page = .projects }.keyboardShortcut("2")
                Button("Token Usage") { model.page = .tokens }.keyboardShortcut("3")
                Divider()
                Button("Full Rescan") { model.rescanSources() }
                    .keyboardShortcut("r")
                    .disabled(!model.canRescanSources)
            }
        }

        MenuBarExtra("Agent Dashboard", systemImage: "gauge.with.needle") {
            MenuBarPanel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .background(WindowConfigurationView(identifier: "settingsWindow"))
                .task { await model.load() }
        }
    }
}

private struct DashboardWindowContent: View {
    let model: DashboardModel
    @State private var contentMinimum = CGSize(width: 960, height: 600)
    @State private var showsSetup = false

    var body: some View {
        MainWindow(model: model)
            .frame(minWidth: contentMinimum.width, minHeight: contentMinimum.height)
            .background(WindowConfigurationView(identifier: "dashboardWindow", size: SyntheticLaunchOptions.current?.windowSize,
                                                minimumOuterSize: CGSize(width: 960, height: 600),
                                                contentMinimum: contentMinimum,
                                                updateContentMinimum: { contentMinimum = $0 }))
            .task { await model.load() }
            .onChange(of: model.onboardingRequired, initial: true) { _, required in
                if required { showsSetup = true }
            }
            .sheet(isPresented: $showsSetup) {
                SourceOnboardingView(model: model)
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if let appearance = SyntheticLaunchOptions.current?.appearance {
            NSApp.appearance = NSAppearance(named: appearance)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Only synthetic validation may select one of the SPEC sizes or an app-local
/// appearance. Unknown options and all options outside --synthetic are ignored.
private struct SyntheticLaunchOptions {
    let windowSize: CGSize?
    let appearance: NSAppearance.Name?

    static var current: Self? { Self(arguments: CommandLine.arguments) }

    init?(arguments: [String]) {
        guard arguments.contains("--synthetic") else { return nil }
        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        switch value(after: "--window-size") {
        case "960x600": windowSize = CGSize(width: 960, height: 600)
        case "1120x720": windowSize = CGSize(width: 1120, height: 720)
        case "1440x900": windowSize = CGSize(width: 1440, height: 900)
        default: windowSize = nil
        }
        switch value(after: "--appearance") {
        case "dark": appearance = .darkAqua
        case "light": appearance = .aqua
        default: appearance = nil
        }
    }
}

/// SwiftUI frame minimums apply to content; SPEC minimums describe the outer window.
/// Native chrome measurements translate between them without a fixed titlebar height.
struct WindowConfigurationView: NSViewRepresentable {
    let identifier: String
    var size: CGSize? = nil
    var minimumOuterSize: CGSize? = nil
    var contentMinimum: CGSize? = nil
    var updateContentMinimum: ((CGSize) -> Void)? = nil
    var updateVisibility: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> WindowView { WindowView(configuration: self) }
    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.configuration = self
        nsView.scheduleConfiguration()
    }

    final class WindowView: NSView {
        var configuration: WindowConfigurationView
        private weak var configuredWindow: NSWindow?
        private var layoutObservation: NSKeyValueObservation?
        private var visibilityObservation: NSKeyValueObservation?
        private var measuredContentMinimum: CGSize?
        private var appliedSyntheticFrame = false

        init(configuration: WindowConfigurationView) {
            self.configuration = configuration
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                let update = configuration.updateVisibility
                DispatchQueue.main.async { [weak self] in
                    if self?.window == nil { update?(false) }
                }
            }
            guard let window, configuredWindow !== window else { return }
            configuredWindow = window
            appliedSyntheticFrame = false
            measuredContentMinimum = nil
            if window.accessibilityIdentifier() != configuration.identifier {
                window.setAccessibilityIdentifier(configuration.identifier)
            }
            layoutObservation = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.scheduleConfiguration() }
            }
            visibilityObservation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.scheduleConfiguration() }
            }
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            DispatchQueue.main.async { [weak self] in self?.configureWindow() }
        }

        private func configureWindow() {
            guard let window else { return }
            configuration.updateVisibility?(window.isVisible)
            if window.accessibilityIdentifier() != configuration.identifier {
                window.setAccessibilityIdentifier(configuration.identifier)
            }
            if let minimum = configuration.minimumOuterSize {
                // Measure settled native chrome once per shown window. Re-measuring
                // during the resulting SwiftUI update can feed transient toolbar
                // geometry back into the content minimum and prevent presentation.
                if measuredContentMinimum == nil {
                    let layout = window.contentLayoutRect
                    guard window.isVisible, layout.width > 0, layout.height > 0 else { return }
                    let chrome = CGSize(width: max(0, window.frame.width - layout.width),
                                        height: max(0, window.frame.height - layout.height))
                    measuredContentMinimum = CGSize(width: max(0, minimum.width - chrome.width),
                                                     height: max(0, minimum.height - chrome.height))
                }
                guard let content = measuredContentMinimum else { return }
                if configuration.contentMinimum != content {
                    configuration.updateContentMinimum?(content)
                    return // Let SwiftUI update its content constraint before sizing the window.
                }
                if window.minSize != minimum { window.minSize = minimum }
            }
            if let requestedSize = configuration.size, !appliedSyntheticFrame {
                window.contentView?.layoutSubtreeIfNeeded()
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
                let origin = CGPoint(x: visible.midX - requestedSize.width / 2,
                                     y: visible.midY - requestedSize.height / 2)
                window.setFrame(CGRect(origin: origin, size: requestedSize), display: true)
                appliedSyntheticFrame = true
            }
        }
    }
}

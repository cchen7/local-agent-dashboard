import AppKit
import SwiftUI
import ADCore
import ADIngest
import ADStore

/// Explicit, local actions for the selected session. The index controls which
/// buttons are available; a click verifies the current inputs again.
struct SessionActionFooter: View {
    let session: SessionKey
    let store: AgentStore
    let hostHome: String?
    @State private var availability: IndexedSessionActions?
    @State private var actionTask: Task<Void, Never>?
    @State private var feedback: Feedback?

    private enum Action { case copy, reveal }

    private enum Feedback {
        case copied, sent, copyUnavailable, recordUnavailable

        var message: LocalizedStringKey {
            switch self {
            case .copied: "Resume command copied"
            case .sent: "Finder request sent"
            case .copyUnavailable: "Could not copy the resume command."
            case .recordUnavailable: "The original record is no longer available."
            }
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let feedback {
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("session.actions.feedback")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { revealButton; copyButton }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .trailing, spacing: 4) { revealButton; copyButton }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .task(id: session) {
            do {
                for try await value in store.indexedSessionActionUpdates(session) {
                    availability = value
                }
            } catch {
                if !Task.isCancelled { availability = nil }
            }
        }
        .onDisappear {
            actionTask?.cancel()
            actionTask = nil
            availability = nil
            feedback = nil
        }
    }

    private var revealButton: some View {
        Button("Show in Finder") { start(.reveal) }
            .disabled(actionTask != nil || availability?.record == nil)
            .accessibilityIdentifier("session.actions.reveal")
    }

    private var copyButton: some View {
        Button("Copy Resume Command") { start(.copy) }
            .tint(.accentColor)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(actionTask != nil || availability.flatMap {
                SessionLocalActions.resumeCommand($0, hostHome: hostHome)
            } == nil)
            .accessibilityIdentifier("session.actions.copy")
    }

    private func start(_ action: Action) {
        guard actionTask == nil else { return }
        feedback = nil
        actionTask = Task {
            defer { if !Task.isCancelled { actionTask = nil } }
            do {
                let snapshot = try await Task.detached { [store, session] in
                    guard let current = try store.indexedSessionActions(session) else {
                        throw SessionLocalActionFailure.unavailable
                    }
                    return current
                }.value
                try Task.checkCancellation()

                switch action {
                case .copy:
                    guard let command = SessionLocalActions.resumeCommand(snapshot, hostHome: hostHome),
                          Self.copy(command) else { throw SessionLocalActionFailure.unavailable }
                    feedback = .copied
                case .reveal:
                    guard let record = snapshot.record else { throw SessionLocalActionFailure.unavailable }
                    try await SourceAccessProbe.withIndexingAccess(to: snapshot.source, expectedIdentity: record.rootIdentity) { [store, session] root in
                        try Task.checkCancellation()
                        guard try store.indexedSessionActions(session) == snapshot else {
                            throw SessionLocalActionFailure.unavailable
                        }
                        try await MainActor.run {
                            try Task.checkCancellation()
                            try SessionLocalActions.withVerifiedRecordURL(record, authorizedRoot: root) { url in
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }
                    if !Task.isCancelled { feedback = .sent }
                }
            } catch {
                if !Task.isCancelled { feedback = action == .copy ? .copyUnavailable : .recordUnavailable }
            }
        }
    }

    private static func copy(_ command: String) -> Bool {
        let synthetic = CommandLine.arguments.contains("--synthetic")
        let pasteboard = synthetic ? NSPasteboard.withUniqueName() : .general
        defer { if synthetic { pasteboard.releaseGlobally() } }
        pasteboard.clearContents()
        return pasteboard.setString(command, forType: .string)
    }
}

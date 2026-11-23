import ADCore
import ADInsights
import SwiftUI

struct SessionActivityBar: View {
    let activity: SessionActivityDisplay
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let now = Int64(tick.date.timeIntervalSince1970 * 1000)
            let age = SessionActivityDisplay.seconds(since: activity.lastEventAt, at: now)
            let elapsed = SessionActivityDisplay.seconds(since: activity.startedAt, at: now)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    actionLabel(activity).fixedSize()
                    commandLabel(activity).frame(idealWidth: 72, maxWidth: .infinity, alignment: .leading)
                    timing(age: age, elapsed: elapsed).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    actionLabel(activity)
                    commandLabel(activity)
                    timing(age: age, elapsed: elapsed)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(SessionStatus.running.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("session.activity")
        }
    }

    private func actionLabel(_ activity: SessionActivityDisplay) -> some View {
        Label {
            switch activity.action {
            case .pendingTool:
                if let name = activity.toolName { Text("Running · \(name)") }
                else { Text("Running · Tool call") }
            case .toolFinished: Text("Running · Tool finished")
            case .turnFinished: Text("Running · Turn finished")
            case .recentActivity: Text("Running · Recent activity")
            }
        } icon: {
            Image(systemName: "bolt.fill")
                .foregroundStyle(SessionStatus.running.color)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(colorScheme == .dark ? SessionStatus.running.color : .primary)
        .lineLimit(1)
        .accessibilityIdentifier("session.activity.action")
    }

    @ViewBuilder private func commandLabel(_ activity: SessionActivityDisplay) -> some View {
        if let command = activity.command {
            Text(verbatim: command)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: command))
                .accessibilityIdentifier("session.activity.command")
        }
    }

    private func timing(age: Int64?, elapsed: Int64?) -> some View {
        HStack(spacing: 5) {
            if let age {
                Text("Last event \(age.formatted())s ago")
                    .accessibilityIdentifier("session.activity.lastEvent")
            }
            if let elapsed {
                if age != nil { Text(verbatim: "·").accessibilityHidden(true) }
                let duration = Duration.seconds(elapsed)
                    .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
                Text(verbatim: duration)
                    .accessibilityLabel(Text("Elapsed \(duration)"))
                    .accessibilityIdentifier("session.activity.elapsed")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

import NotchAgentsCore
import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var store: AgentStore
    let onMarkCompletedSeen: (AgentKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notch Agents")
                    .font(.title3.weight(.semibold))

                Text("Codex stays on the left of the notch. Claude stays on the right. The overlay reads Codex and Claude local state directly, and `notchagentsctl` can still inject or override richer task metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = store.lastError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Status File")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(store.statusFileURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.06))
                    )
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.summaries) { summary in
                        AgentCard(
                            summary: summary,
                            onMarkCompletedSeen: onMarkCompletedSeen
                        )
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Quick Commands")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("notchagentsctl start --agent codex --id task-1 --title \"Build\"\nnotchagentsctl ask --agent claude --id review-1 --title \"PR review\" --question \"Approve it?\"\nnotchagentsctl finish --agent codex --id task-1")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            HStack {
                Button("Refresh") {
                    store.refresh()
                }

                Button("Sample") {
                    store.writeSampleData()
                }

                Button("Clear") {
                    store.clearSnapshot()
                }
            }
        }
        .padding(18)
        .frame(width: 360, height: 440)
    }
}

private struct AgentCard: View {
    let summary: AgentSummary
    let onMarkCompletedSeen: (AgentKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(summary.agent.displayName)
                    .font(.headline)

                Spacer()

                Text(summary.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.statusColor)
            }

            if summary.status == .success {
                Button("Mark Completed Seen") {
                    onMarkCompletedSeen(summary.agent)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if summary.tasks.isEmpty, summary.isInferredFromProcess {
                Text("Detected from a running process. Publish richer task states with `notchagentsctl`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.tasks.sorted { $0.updatedAt > $1.updatedAt }) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(task.title)
                                .font(.subheadline.weight(.medium))

                            Spacer()

                            Text(task.state.rawValue)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        if let detail = task.question ?? task.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(relativeTime(for: task.updatedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.05))
                    )
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.035))
        )
    }

    private func relativeTime(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

private extension AgentSummary {
    var statusText: String {
        switch status {
        case .running:
            return count > 1 ? "Running \(count)" : "Running"
        case .needsInput:
            return count > 1 ? "Needs input \(count)" : "Needs input"
        case .success:
            return count > 1 ? "Finished \(count)" : "Finished"
        case .failure:
            return count > 1 ? "Failed \(count)" : "Failed"
        case .idle:
            return "Idle"
        }
    }

    var statusColor: Color {
        switch status {
        case .running:
            return .blue
        case .needsInput:
            return .orange
        case .success:
            return .green
        case .failure:
            return .red
        case .idle:
            return .secondary
        }
    }
}

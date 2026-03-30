import Foundation

public enum AgentSummaryResolver {
    private static let needsInputWindow: TimeInterval = 7 * 24 * 60 * 60
    private static let completionWindow: TimeInterval = 45 * 60

    public static func resolve(
        snapshot: StatusSnapshot,
        processCounts: [AgentKind: Int],
        now: Date = .now
    ) -> [AgentSummary] {
        AgentKind.allCases.map { agent in
            let feed = snapshot.feed(for: agent) ?? AgentFeed(id: agent)
            let tasks = feed.tasks.sorted { $0.updatedAt > $1.updatedAt }
            let side = feed.side ?? agent.defaultSide

            let pending = recentTasks(
                tasks,
                matching: .needsInput,
                within: needsInputWindow,
                now: now
            )
            if let primary = pending.first {
                return AgentSummary(
                    agent: agent,
                    side: side,
                    status: .needsInput,
                    count: pending.count,
                    primaryTask: primary,
                    tasks: tasks,
                    isInferredFromProcess: false,
                    updatedAt: primary.updatedAt
                )
            }

            let running = recentTasks(
                tasks,
                matching: .running,
                within: runningWindow(for: agent),
                now: now
            )
            if let primary = running.first {
                let runningCount = max(
                    running.count,
                    inferredRunningCount(
                        for: agent,
                        explicitCount: running.count,
                        processCount: processCounts[agent] ?? 0
                    )
                )

                return AgentSummary(
                    agent: agent,
                    side: side,
                    status: .running,
                    count: runningCount,
                    primaryTask: primary,
                    tasks: tasks,
                    isInferredFromProcess: false,
                    updatedAt: primary.updatedAt
                )
            }

            let failures = recentTasks(
                tasks,
                matching: .failed,
                within: completionWindow,
                now: now
            )
            if let primary = failures.first {
                return AgentSummary(
                    agent: agent,
                    side: side,
                    status: .failure,
                    count: failures.count,
                    primaryTask: primary,
                    tasks: tasks,
                    isInferredFromProcess: false,
                    updatedAt: primary.updatedAt
                )
            }

            let completed = recentTasks(
                tasks,
                matching: .completed,
                within: completionWindow,
                now: now
            )
            if let primary = completed.first {
                return AgentSummary(
                    agent: agent,
                    side: side,
                    status: .success,
                    count: completed.count,
                    primaryTask: primary,
                    tasks: tasks,
                    isInferredFromProcess: false,
                    updatedAt: primary.updatedAt
                )
            }

            let processCount = processCounts[agent] ?? 0
            if processCount > 0, shouldUseProcessFallback(for: agent, tasks: tasks, now: now) {
                return AgentSummary(
                    agent: agent,
                    side: side,
                    status: .running,
                    count: processCount,
                    primaryTask: nil,
                    tasks: tasks,
                    isInferredFromProcess: true,
                    updatedAt: nil
                )
            }

            return AgentSummary(
                agent: agent,
                side: side,
                status: .idle,
                count: 0,
                primaryTask: nil,
                tasks: tasks,
                isInferredFromProcess: false,
                updatedAt: tasks.first?.updatedAt
            )
        }
    }

    private static func shouldUseProcessFallback(
        for agent: AgentKind,
        tasks: [AgentTask],
        now: Date
    ) -> Bool {
        switch agent {
        case .codex:
            return true
        case .claude:
            return tasks.contains { now.timeIntervalSince($0.updatedAt) <= runningWindow(for: agent) }
        }
    }

    private static func runningWindow(for agent: AgentKind) -> TimeInterval {
        switch agent {
        case .codex:
            return 60 * 60
        case .claude:
            return 4 * 60 * 60
        }
    }

    private static func inferredRunningCount(
        for agent: AgentKind,
        explicitCount: Int,
        processCount: Int
    ) -> Int {
        switch agent {
        case .codex:
            return explicitCount
        case .claude:
            return processCount
        }
    }

    private static func recentTasks(
        _ tasks: [AgentTask],
        matching state: AgentTaskState,
        within window: TimeInterval,
        now: Date
    ) -> [AgentTask] {
        tasks.filter {
            $0.state == state && now.timeIntervalSince($0.updatedAt) <= window
        }
    }
}

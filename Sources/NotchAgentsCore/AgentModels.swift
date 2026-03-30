import Foundation

public enum AgentSide: String, Codable, CaseIterable, Sendable {
    case leading
    case trailing
}

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    public var defaultSide: AgentSide {
        switch self {
        case .codex:
            return .leading
        case .claude:
            return .trailing
        }
    }

    public var appBundlePath: String {
        switch self {
        case .codex:
            return "/Applications/Codex.app"
        case .claude:
            return "/Applications/Claude.app"
        }
    }
}

public enum AgentTaskState: String, Codable, Sendable {
    case running
    case needsInput
    case completed
    case failed
}

public struct AgentTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var state: AgentTaskState
    public var detail: String?
    public var question: String?
    public var actionURL: URL?
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        state: AgentTaskState,
        detail: String? = nil,
        question: String? = nil,
        actionURL: URL? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.question = question
        self.actionURL = actionURL
        self.updatedAt = updatedAt
    }
}

public struct AgentFeed: Codable, Equatable, Identifiable, Sendable {
    public var id: AgentKind
    public var side: AgentSide?
    public var tasks: [AgentTask]

    public init(id: AgentKind, side: AgentSide? = nil, tasks: [AgentTask] = []) {
        self.id = id
        self.side = side
        self.tasks = tasks
    }
}

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var updatedAt: Date
    public var agents: [AgentFeed]

    public init(version: Int = 1, updatedAt: Date = .now, agents: [AgentFeed] = []) {
        self.version = version
        self.updatedAt = updatedAt
        self.agents = agents
    }
}

public extension StatusSnapshot {
    static var empty: StatusSnapshot {
        StatusSnapshot()
    }

    static var sample: StatusSnapshot {
        StatusSnapshot(
            agents: [
                AgentFeed(
                    id: .codex,
                    tasks: [
                        AgentTask(
                            id: "landing-page",
                            title: "Implement notch overlay app",
                            state: .running,
                            detail: "Compiling the new overlay and CLI bridge."
                        ),
                        AgentTask(
                            id: "review",
                            title: "Review layout pass",
                            state: .completed,
                            detail: "Primary overlay pass finished."
                        )
                    ]
                ),
                AgentFeed(
                    id: .claude,
                    tasks: [
                        AgentTask(
                            id: "approval",
                            title: "Need copy approval",
                            state: .needsInput,
                            question: "Ship the current README copy?",
                            actionURL: URL(string: "https://example.com/thread/approval")
                        )
                    ]
                )
            ]
        )
    }

    mutating func upsertTask(
        for agent: AgentKind,
        side: AgentSide? = nil,
        task: AgentTask
    ) {
        let index = feedIndex(for: agent)

        if let side {
            agents[index].side = side
        }

        if let taskIndex = agents[index].tasks.firstIndex(where: { $0.id == task.id }) {
            agents[index].tasks[taskIndex] = task
        } else {
            agents[index].tasks.append(task)
        }
    }

    mutating func removeTask(for agent: AgentKind, taskID: String) {
        let index = feedIndex(for: agent)
        agents[index].tasks.removeAll { $0.id == taskID }
    }

    mutating func removeAllTasks() {
        agents = AgentKind.allCases.map { AgentFeed(id: $0) }
        updatedAt = .now
    }

    mutating func setSide(_ side: AgentSide?, for agent: AgentKind) {
        let index = feedIndex(for: agent)
        agents[index].side = side
    }

    func feed(for agent: AgentKind) -> AgentFeed? {
        agents.first(where: { $0.id == agent })
    }

    func merged(with other: StatusSnapshot) -> StatusSnapshot {
        var mergedFeeds: [AgentKind: AgentFeed] = [:]

        for feed in agents {
            mergedFeeds[feed.id] = feed
        }

        for feed in other.agents {
            var target = mergedFeeds[feed.id] ?? AgentFeed(id: feed.id)

            if let side = feed.side {
                target.side = side
            }

            var tasksByID = Dictionary(uniqueKeysWithValues: target.tasks.map { ($0.id, $0) })

            for task in feed.tasks {
                tasksByID[task.id] = task
            }

            target.tasks = tasksByID.values.sorted { $0.updatedAt > $1.updatedAt }
            mergedFeeds[feed.id] = target
        }

        return StatusSnapshot(
            version: max(version, other.version),
            updatedAt: max(updatedAt, other.updatedAt),
            agents: AgentKind.allCases.compactMap { mergedFeeds[$0] }
        )
    }

    private mutating func feedIndex(for agent: AgentKind) -> Int {
        if let index = agents.firstIndex(where: { $0.id == agent }) {
            return index
        }

        agents.append(AgentFeed(id: agent))
        return agents.endIndex - 1
    }
}

public enum AgentSummaryStatus: String, Equatable, Sendable {
    case idle
    case running
    case needsInput
    case success
    case failure
}

public struct AgentSummary: Identifiable, Equatable, Sendable {
    public var id: AgentKind { agent }

    public let agent: AgentKind
    public let side: AgentSide
    public let status: AgentSummaryStatus
    public let count: Int
    public let primaryTask: AgentTask?
    public let tasks: [AgentTask]
    public let isInferredFromProcess: Bool
    public let updatedAt: Date?

    public init(
        agent: AgentKind,
        side: AgentSide,
        status: AgentSummaryStatus,
        count: Int,
        primaryTask: AgentTask?,
        tasks: [AgentTask],
        isInferredFromProcess: Bool,
        updatedAt: Date?
    ) {
        self.agent = agent
        self.side = side
        self.status = status
        self.count = count
        self.primaryTask = primaryTask
        self.tasks = tasks
        self.isInferredFromProcess = isInferredFromProcess
        self.updatedAt = updatedAt
    }
}

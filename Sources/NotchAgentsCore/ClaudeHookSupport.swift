import Foundation

public struct ClaudeHookInstallResult: Sendable {
    public let settingsURL: URL
    public let didChange: Bool
    public let command: String
}

public enum ClaudeHookSupport {
    public static let defaultSettingsURL = URL(
        fileURLWithPath: NSString(string: "~/.claude/settings.json").expandingTildeInPath
    )
    public static let defaultCommand = "\(NSString(string: "~/.local/bin/notchagentsctl").expandingTildeInPath) claude-hook"

    private static let hookSpecs: [HookSpec] = [
        HookSpec(event: "SessionStart"),
        HookSpec(event: "UserPromptSubmit"),
        HookSpec(event: "Stop"),
        HookSpec(event: "StopFailure"),
        HookSpec(event: "Notification", matcher: "permission_prompt|idle_prompt|elicitation_dialog"),
        HookSpec(event: "Elicitation"),
        HookSpec(event: "ElicitationResult"),
        HookSpec(event: "SessionEnd")
    ]

    public static func install(
        command: String = defaultCommand,
        settingsURL: URL = defaultSettingsURL
    ) throws -> ClaudeHookInstallResult {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var rootObject = try readJSONObject(at: settingsURL) ?? [:]
        var hooksObject = rootObject["hooks"] as? [String: Any] ?? [:]
        var didChange = false

        for spec in hookSpecs {
            var groups = hookGroups(from: hooksObject[spec.event])
            guard !groupsContainCommand(groups, matcher: spec.matcher, command: command) else {
                continue
            }

            var group: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": command
                    ]
                ]
            ]

            if let matcher = spec.matcher {
                group["matcher"] = matcher
            }

            groups.append(group)
            hooksObject[spec.event] = groups
            didChange = true
        }

        if didChange || rootObject["hooks"] == nil {
            rootObject["hooks"] = hooksObject
            try writeJSONObject(rootObject, to: settingsURL)
        }

        return ClaudeHookInstallResult(
            settingsURL: settingsURL,
            didChange: didChange,
            command: command
        )
    }

    @discardableResult
    public static func applyHookPayload(
        _ data: Data,
        now: Date = .now,
        snapshotURL: URL = StatusFileLocation.snapshotURL
    ) throws -> Bool {
        guard
            !data.isEmpty,
            let rawObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }

        let payload = ClaudeHookPayload(json: rawObject)
        guard let taskID = payload.taskID else {
            return false
        }

        switch payload.action(now: now) {
        case let .upsert(task):
            try StatusSnapshotStore.mutate(at: snapshotURL) { snapshot in
                snapshot.upsertTask(for: .claude, side: .trailing, task: task)
            }
            return true
        case .remove:
            try StatusSnapshotStore.mutate(at: snapshotURL) { snapshot in
                snapshot.removeTask(for: .claude, taskID: taskID)
            }
            return true
        case .none:
            return false
        }
    }

    private static func readJSONObject(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return nil
        }

        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeJSONObject(
        _ object: [String: Any],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private static func hookGroups(from rawValue: Any?) -> [[String: Any]] {
        guard let rawGroups = rawValue as? [Any] else {
            return []
        }

        return rawGroups.compactMap { $0 as? [String: Any] }
    }

    private static func groupsContainCommand(
        _ groups: [[String: Any]],
        matcher: String?,
        command: String
    ) -> Bool {
        groups.contains { group in
            let groupMatcher = normalizedMatcher(group["matcher"] as? String)
            guard groupMatcher == matcher else {
                return false
            }

            let hooks = (group["hooks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            return hooks.contains { hook in
                hook["type"] as? String == "command"
                    && hook["command"] as? String == command
            }
        }
    }

    private static func normalizedMatcher(_ matcher: String?) -> String? {
        guard let matcher, !matcher.isEmpty, matcher != "*" else {
            return nil
        }

        return matcher
    }
}

private struct HookSpec {
    let event: String
    let matcher: String?

    init(event: String, matcher: String? = nil) {
        self.event = event
        self.matcher = matcher
    }
}

private struct ClaudeHookPayload {
    let sessionID: String?
    let transcriptPath: String?
    let cwd: String?
    let eventName: String?
    let title: String?
    let message: String?
    let notificationType: String?

    init(json: [String: Any]) {
        sessionID = Self.string(in: json, keys: ["session_id", "sessionId"])
        transcriptPath = Self.string(in: json, keys: ["transcript_path", "transcriptPath"])
        cwd = Self.string(in: json, keys: ["cwd"])
        eventName = Self.string(in: json, keys: ["hook_event_name", "hookEventName"])
        title = Self.string(in: json, keys: ["title"])
        message = Self.string(in: json, keys: ["message"])
        notificationType = Self.string(in: json, keys: ["notification_type", "notificationType"])
    }

    var taskID: String? {
        if let sessionID, !sessionID.isEmpty {
            return "claude-session-\(sessionID)"
        }

        if let transcriptPath, !transcriptPath.isEmpty {
            return "claude-session-\(Self.stableID(for: transcriptPath))"
        }

        if let cwd, !cwd.isEmpty {
            return "claude-session-\(Self.stableID(for: cwd))"
        }

        return nil
    }

    func action(now: Date) -> ClaudeHookAction {
        guard let taskID else {
            return .none
        }

        switch eventName {
        case "SessionStart", "UserPromptSubmit", "ElicitationResult":
            return .upsert(task(id: taskID, state: .running, detail: "Active Claude session", now: now))
        case "Elicitation":
            return .upsert(
                task(
                    id: taskID,
                    state: .needsInput,
                    detail: message?.normalizedLine(limit: 72) ?? "Claude requested input",
                    question: message?.normalizedLine(limit: 120),
                    now: now
                )
            )
        case "Notification":
            guard shouldSurfaceNotification else {
                return .none
            }

            let detail = title?.normalizedLine(limit: 72)
                ?? message?.normalizedLine(limit: 72)
                ?? "Claude needs your attention"
            return .upsert(
                task(
                    id: taskID,
                    state: .needsInput,
                    detail: detail,
                    question: message?.normalizedLine(limit: 120),
                    now: now
                )
            )
        case "Stop":
            if needsInputTerms(message) || needsInputTerms(title) {
                return .upsert(
                    task(
                        id: taskID,
                        state: .needsInput,
                        detail: title?.normalizedLine(limit: 72)
                            ?? message?.normalizedLine(limit: 72)
                            ?? "Claude needs input",
                        question: message?.normalizedLine(limit: 120),
                        now: now
                    )
                )
            }

            return .upsert(
                task(
                    id: taskID,
                    state: .completed,
                    detail: message?.normalizedLine(limit: 72) ?? "Claude finished responding",
                    now: now
                )
            )
        case "StopFailure":
            return .upsert(
                task(
                    id: taskID,
                    state: .failed,
                    detail: message?.normalizedLine(limit: 72) ?? "Claude turn failed",
                    now: now
                )
            )
        case "SessionEnd":
            return .remove
        default:
            return .none
        }
    }

    private var shouldSurfaceNotification: Bool {
        guard let notificationType else {
            return needsInputTerms(message) || needsInputTerms(title)
        }

        return [
            "permission_prompt",
            "idle_prompt",
            "elicitation_dialog"
        ].contains(notificationType)
    }

    private func task(
        id: String,
        state: AgentTaskState,
        detail: String? = nil,
        question: String? = nil,
        now: Date
    ) -> AgentTask {
        AgentTask(
            id: id,
            title: titleText,
            state: state,
            detail: detail,
            question: question,
            updatedAt: now
        )
    }

    private var titleText: String {
        guard let cwd, !cwd.isEmpty else {
            return title?.normalizedLine(limit: 60)
                ?? message?.normalizedLine(limit: 60)
                ?? "Claude session"
        }

        let base = URL(fileURLWithPath: cwd).lastPathComponent
        guard !base.isEmpty else {
            return "Claude session"
        }

        return base.normalizedLine(limit: 60)
    }

    private func needsInputTerms(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        let haystack = value.lowercased()
        return [
            "question",
            "permission",
            "approve",
            "approval",
            "confirm",
            "choose",
            "need input",
            "needs input",
            "answer"
        ].contains(where: { haystack.contains($0) })
    }

    private static func string(
        in json: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private static func stableID(for value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325

        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }

        return String(hash, radix: 16)
    }
}

private enum ClaudeHookAction {
    case upsert(AgentTask)
    case remove
    case none
}

private extension String {
    func normalizedLine(limit: Int) -> String {
        let flattened = replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard flattened.count > limit else {
            return flattened
        }

        return "\(flattened.prefix(limit - 1))…"
    }
}

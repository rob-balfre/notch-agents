import Foundation
import SQLite3
import Darwin

public struct LiveScanResult: Sendable {
    public let snapshot: StatusSnapshot
    public let latestCompletedMarkers: [AgentKind: Double]

    public init(
        snapshot: StatusSnapshot,
        latestCompletedMarkers: [AgentKind: Double]
    ) {
        self.snapshot = snapshot
        self.latestCompletedMarkers = latestCompletedMarkers
    }
}

public enum LiveStatusScanner {
    public static func scan(
        completedMarkers: [AgentKind: Double] = [:],
        now: Date = .now
    ) throws -> LiveScanResult {
        let codex = try CodexLiveScanner().scan(
            completedMarker: completedMarkers[.codex] ?? 0,
            now: now
        )
        let claude = try ClaudeLiveScanner().scan(
            completedMarker: completedMarkers[.claude] ?? 0,
            now: now
        )

        return LiveScanResult(
            snapshot: StatusSnapshot(
                updatedAt: now,
                agents: [codex.feed, claude.feed]
            ),
            latestCompletedMarkers: [
                .codex: codex.latestCompletedMarker,
                .claude: claude.latestCompletedMarker
            ]
        )
    }
}

private struct FeedScanResult {
    let feed: AgentFeed
    let latestCompletedMarker: Double
}

private final class FileValueCache<Value>: @unchecked Sendable {
    private struct Entry {
        let modifiedAtToken: TimeInterval
        let value: Value
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func value(
        for file: URL,
        modifiedAt: Date?,
        loader: () -> Value
    ) -> Value {
        guard let modifiedAt else {
            return loader()
        }

        let key = file.path
        let token = modifiedAt.timeIntervalSinceReferenceDate

        lock.lock()
        if let entry = entries[key], entry.modifiedAtToken == token {
            let value = entry.value
            lock.unlock()
            return value
        }
        lock.unlock()

        let value = loader()

        lock.lock()
        if entries.count > 512 {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = Entry(modifiedAtToken: token, value: value)
        lock.unlock()

        return value
    }
}

private final class TimedValueCache<Value>: @unchecked Sendable {
    private struct Entry {
        let updatedAt: Date
        let value: Value
    }

    private let lock = NSLock()
    private var entry: Entry?

    func value(
        now: Date,
        ttl: TimeInterval,
        loader: () -> Value
    ) -> Value {
        lock.lock()
        if let entry, now.timeIntervalSince(entry.updatedAt) < ttl {
            let value = entry.value
            lock.unlock()
            return value
        }
        lock.unlock()

        let value = loader()

        lock.lock()
        entry = Entry(updatedAt: now, value: value)
        lock.unlock()

        return value
    }
}

private struct CodexLiveScanner {
    private static let rolloutTailBytes: UInt64 = 64 * 1024
    private static let rolloutEventCache = FileValueCache<CodexRolloutTaskEvent?>()

    private let sqlitePath = NSString(string: "~/.codex/state_5.sqlite").expandingTildeInPath
    private let globalStatePath = NSString(string: "~/.codex/.codex-global-state.json").expandingTildeInPath
    private let rootRunningWindow: TimeInterval = 30 * 60
    private let rootCompletionWindow: TimeInterval = 45 * 60

    func scan(completedMarker: Double, now: Date) throws -> FeedScanResult {
        guard FileManager.default.fileExists(atPath: sqlitePath) else {
            return FeedScanResult(feed: AgentFeed(id: .codex), latestCompletedMarker: completedMarker)
        }

        let records = try readThreadRecords()
        let rootActivity = try readRootThreadActivity(
            completedMarker: completedMarker,
            now: now
        )
        let followUps = readFollowUps(now: now)

        let runningTasks = records
            .filter { $0.spawnStatus == "open" }
            .map { record in
                AgentTask(
                    id: "codex-running-\(record.id)",
                    title: record.primaryTitle,
                    state: .running,
                    detail: record.subtitle(prefix: "Background agent"),
                    updatedAt: record.updatedAt
                )
            }

        let inputTasks = records
            .filter(\.hasUserEvent)
            .map { record in
                AgentTask(
                    id: "codex-input-\(record.id)",
                    title: record.primaryTitle,
                    state: .needsInput,
                    detail: record.subtitle(prefix: "Needs your answer"),
                    updatedAt: record.updatedAt
                )
            } + followUps

        let completedTasks = records
            .filter { $0.spawnStatus == "closed" && $0.updatedToken > completedMarker }
            .map { record in
                AgentTask(
                    id: "codex-completed-\(record.id)",
                    title: record.primaryTitle,
                    state: .completed,
                    detail: record.subtitle(prefix: "Finished"),
                    updatedAt: record.updatedAt
                )
            }

        let latestClosedMarker = records
            .filter { $0.spawnStatus == "closed" }
            .map(\.updatedToken)
            .max() ?? completedMarker
        let latestMarker = max(latestClosedMarker, rootActivity.latestCompletedMarker)

        let tasks = (rootActivity.tasks + inputTasks + runningTasks + completedTasks)
            .sorted { lhs, rhs in
                taskPriority(lhs.state) < taskPriority(rhs.state)
                    || (taskPriority(lhs.state) == taskPriority(rhs.state) && lhs.updatedAt > rhs.updatedAt)
            }

        return FeedScanResult(
            feed: AgentFeed(id: .codex, tasks: tasks),
            latestCompletedMarker: latestMarker
        )
    }

    private func readThreadRecords() throws -> [CodexThreadRecord] {
        let database = try SQLiteReader(path: sqlitePath)
        defer { database.close() }

        let sql = """
        SELECT
            t.id,
            t.title,
            CAST(t.updated_at AS REAL),
            t.has_user_event,
            COALESCE(e.status, ''),
            COALESCE(t.agent_nickname, ''),
            COALESCE(t.agent_role, '')
        FROM threads t
        LEFT JOIN thread_spawn_edges e
            ON e.child_thread_id = t.id
        WHERE t.archived = 0
            AND (e.status IS NOT NULL OR t.has_user_event = 1)
        ORDER BY t.updated_at DESC
        LIMIT 200;
        """

        return try database.query(sql) { statement in
            CodexThreadRecord(
                id: statement.string(at: 0),
                title: statement.string(at: 1),
                updatedToken: statement.double(at: 2),
                hasUserEvent: statement.int(at: 3) != 0,
                spawnStatus: statement.string(at: 4),
                nickname: statement.string(at: 5),
                role: statement.string(at: 6)
            )
        }
    }

    private func readFollowUps(now: Date) -> [AgentTask] {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: globalStatePath)),
            let state = try? JSONDecoder().decode(CodexGlobalState.self, from: data)
        else {
            return []
        }

        return state.queuedFollowUps.map { entry in
            AgentTask(
                id: "codex-follow-up-\(entry.key)",
                title: entry.value.bestTitle(fallback: "Pending follow-up"),
                state: .needsInput,
                detail: "Queued follow-up",
                updatedAt: now
            )
        }
    }

    private func readRootThreadActivity(
        completedMarker: Double,
        now: Date
    ) throws -> CodexRootActivityScan {
        let cutoff = now.addingTimeInterval(-max(rootRunningWindow, rootCompletionWindow))
            .timeIntervalSince1970
        let records = try readRootThreadRecords(since: cutoff)
        var tasks: [AgentTask] = []
        var latestCompletedMarker = completedMarker

        for record in records {
            guard let event = latestTaskEvent(at: record.rolloutPath) else {
                continue
            }

            switch event.kind {
            case .started:
                guard now.timeIntervalSince(event.timestamp) <= rootRunningWindow else {
                    continue
                }

                tasks.append(
                    AgentTask(
                        id: "codex-root-running-\(record.id)",
                        title: record.primaryTitle,
                        state: .running,
                        detail: "Active Codex thread",
                        updatedAt: event.timestamp
                    )
                )
            case .completed:
                let marker = event.timestamp.timeIntervalSince1970
                latestCompletedMarker = max(latestCompletedMarker, marker)

                guard marker > completedMarker, now.timeIntervalSince(event.timestamp) <= rootCompletionWindow else {
                    continue
                }

                tasks.append(
                    AgentTask(
                        id: "codex-root-completed-\(record.id)",
                        title: record.primaryTitle,
                        state: .completed,
                        detail: "Finished Codex thread",
                        updatedAt: event.timestamp
                    )
                )
            }
        }

        return CodexRootActivityScan(
            tasks: tasks,
            latestCompletedMarker: latestCompletedMarker
        )
    }

    private func readRootThreadRecords(since updatedToken: Double) throws -> [CodexRootThreadRecord] {
        let database = try SQLiteReader(path: sqlitePath)
        defer { database.close() }

        let sql = """
        SELECT
            t.id,
            t.title,
            CAST(t.updated_at AS REAL),
            t.rollout_path,
            COALESCE(t.agent_nickname, ''),
            COALESCE(t.agent_role, '')
        FROM threads t
        LEFT JOIN thread_spawn_edges e
            ON e.child_thread_id = t.id
        WHERE t.archived = 0
            AND e.child_thread_id IS NULL
            AND t.updated_at >= ?
        ORDER BY t.updated_at DESC
        LIMIT 20;
        """

        return try database.query(
            sql,
            bindings: [updatedToken]
        ) { statement in
            CodexRootThreadRecord(
                id: statement.string(at: 0),
                title: statement.string(at: 1),
                updatedToken: statement.double(at: 2),
                rolloutPath: statement.string(at: 3),
                nickname: statement.string(at: 4),
                role: statement.string(at: 5)
            )
        }
    }

    private func latestTaskEvent(at rolloutPath: String) -> CodexRolloutTaskEvent? {
        let file = URL(fileURLWithPath: rolloutPath)
        let modifiedAt = modificationDate(for: file)

        return Self.rolloutEventCache.value(for: file, modifiedAt: modifiedAt) {
            guard
                let data = tailData(for: file),
                let content = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            for line in content.split(whereSeparator: \.isNewline).reversed().prefix(400) {
                guard
                    let data = String(line).data(using: .utf8),
                    let event = try? decoder.decode(CodexRolloutEventEnvelope.self, from: data),
                    event.type == "event_msg"
                else {
                    continue
                }

                switch event.payload.type {
                case "task_started":
                    return CodexRolloutTaskEvent(kind: .started, timestamp: event.timestamp)
                case "task_complete":
                    return CodexRolloutTaskEvent(kind: .completed, timestamp: event.timestamp)
                default:
                    continue
                }
            }

            return nil
        }
    }

    private func tailData(for file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else {
            return nil
        }

        let startOffset = fileSize > Self.rolloutTailBytes
            ? fileSize - Self.rolloutTailBytes
            : 0

        do {
            try handle.seek(toOffset: startOffset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    private func modificationDate(for file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private struct ClaudeLiveScanner {
    private static let logTailBytes: UInt64 = 64 * 1024
    private static let taskFileCache = FileValueCache<ClaudeTaskFile?>()
    private static let sessionFileCache = FileValueCache<ClaudeSessionFile?>()
    private static let sessionActivityCache = FileValueCache<ClaudeSessionActivity?>()
    private static let taskDirectoryCache = FileValueCache<[URL]>()
    private static let taskFileListCache = FileValueCache<[URL]>()
    private static let sessionDirectoryCache = FileValueCache<[URL]>()
    private static let taskScanCache = TimedValueCache<ClaudeTaskDirectoryScan>()

    private let tasksRoot = URL(fileURLWithPath: NSString(string: "~/.claude/tasks").expandingTildeInPath)
    private let sessionsRoot = URL(fileURLWithPath: NSString(string: "~/.claude/sessions").expandingTildeInPath)
    private let projectsRoot = URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath)
    private let sessionActivityWindow: TimeInterval = 20 * 60
    private let taskScanRefreshWindow: TimeInterval = 60

    func scan(completedMarker: Double, now: Date) throws -> FeedScanResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var tasks: [AgentTask] = []
        var latestMarker = completedMarker

        let taskScan = scanTaskFiles(now: now, decoder: decoder)
        latestMarker = max(latestMarker, taskScan.latestCompletedMarker)

        for task in taskScan.tasks {
            if task.state == .completed, task.updatedAt.timeIntervalSince1970 <= completedMarker {
                continue
            }

            tasks.append(task)
        }

        let sessionResults = sessionTasks(
            completedMarker: completedMarker,
            now: now,
            decoder: decoder
        )
        tasks.append(contentsOf: sessionResults.tasks)
        latestMarker = max(latestMarker, sessionResults.latestCompletedMarker)

        tasks.sort { lhs, rhs in
            taskPriority(lhs.state) < taskPriority(rhs.state)
                || (taskPriority(lhs.state) == taskPriority(rhs.state) && lhs.updatedAt > rhs.updatedAt)
        }

        return FeedScanResult(
            feed: AgentFeed(id: .claude, tasks: tasks),
            latestCompletedMarker: latestMarker
        )
    }

    private func scanTaskFiles(
        now: Date,
        decoder: JSONDecoder
    ) -> ClaudeTaskDirectoryScan {
        Self.taskScanCache.value(now: now, ttl: taskScanRefreshWindow) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: tasksRoot.path) else {
                return ClaudeTaskDirectoryScan(tasks: [], latestCompletedMarker: 0)
            }

            let cutoff = now.addingTimeInterval(-172_800)
            let candidateDirectories = cachedDirectoryContents(
                at: tasksRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                cache: Self.taskDirectoryCache
            )
            .filter { directory in
                guard
                    let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                    values.isDirectory == true
                else {
                    return false
                }

                let modifiedAt = values.contentModificationDate ?? .distantPast
                let isLocked = fileManager.fileExists(atPath: directory.appendingPathComponent(".lock").path)
                return isLocked || modifiedAt >= cutoff
            }

            var tasks: [AgentTask] = []
            var latestCompletedMarker = 0.0

            for directory in candidateDirectories {
                let files = cachedDirectoryContents(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    filter: { $0.pathExtension == "json" },
                    cache: Self.taskFileListCache
                )

                for file in files {
                    guard
                        let taskFile = cachedDecode(
                            ClaudeTaskFile.self,
                            from: file,
                            decoder: decoder,
                            cache: Self.taskFileCache
                        )
                    else {
                        continue
                    }

                    let modifiedAt = modificationDate(for: file) ?? .distantPast
                    let marker = modifiedAt.timeIntervalSince1970

                    if taskFile.status == "completed" {
                        latestCompletedMarker = max(latestCompletedMarker, marker)
                    }

                    guard let state = classify(taskFile) else {
                        continue
                    }

                    tasks.append(
                        AgentTask(
                            id: "claude-\(directory.lastPathComponent)-\(taskFile.id)",
                            title: taskFile.subject.normalizedLine(limit: 60),
                            state: state,
                            detail: taskFile.subtitleText,
                            updatedAt: modifiedAt
                        )
                    )
                }
            }

            return ClaudeTaskDirectoryScan(
                tasks: tasks,
                latestCompletedMarker: latestCompletedMarker
            )
        }
    }

    private func sessionTasks(
        completedMarker: Double,
        now: Date,
        decoder: JSONDecoder
    ) -> ClaudeSessionTaskScan {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            return ClaudeSessionTaskScan(tasks: [], latestCompletedMarker: completedMarker)
        }

        let files = cachedDirectoryContents(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            filter: { $0.pathExtension == "json" },
            cache: Self.sessionDirectoryCache
        )

        var tasks: [AgentTask] = []
        var latestCompletedMarker = completedMarker

        for file in files {
            guard
                file.pathExtension == "json",
                let session = cachedDecode(
                    ClaudeSessionFile.self,
                    from: file,
                    decoder: decoder,
                    cache: Self.sessionFileCache
                ),
                session.kind == "interactive",
                isProcessAlive(pid: session.pid)
            else {
                continue
            }

            let sessionModifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date(timeIntervalSince1970: session.startedAt / 1000)
            let projectLogURL = projectLogURL(
                sessionId: session.sessionId,
                cwd: session.cwd
            )
            let projectModifiedAt = projectLogURL
                .flatMap(modificationDate(for:))
                ?? .distantPast

            let activity = projectLogURL.flatMap {
                latestSessionActivity(in: $0, decoder: decoder)
            }
            let fallbackUpdatedAt = max(sessionModifiedAt, projectModifiedAt)
            let updatedAt = activity?.updatedAt ?? fallbackUpdatedAt

            guard now.timeIntervalSince(updatedAt) <= sessionActivityWindow else {
                continue
            }

            let titleBase = URL(fileURLWithPath: session.cwd).lastPathComponent
            let title = titleBase.isEmpty ? "Claude session" : titleBase.normalizedLine(limit: 60)

            let state = activity?.state ?? .running
            if state == .completed {
                let marker = updatedAt.timeIntervalSince1970
                latestCompletedMarker = max(latestCompletedMarker, marker)

                if marker <= completedMarker {
                    continue
                }
            }

            tasks.append(
                AgentTask(
                    id: "claude-session-\(session.sessionId)",
                    title: title,
                    state: state,
                    detail: activity?.detail ?? "Active Claude session",
                    updatedAt: updatedAt
                )
            )
        }

        return ClaudeSessionTaskScan(
            tasks: tasks,
            latestCompletedMarker: latestCompletedMarker
        )
    }

    private func projectLogURL(
        sessionId: String,
        cwd: String
    ) -> URL? {
        let exactDirectory = projectsRoot.appendingPathComponent(
            cwd.replacingOccurrences(of: "/", with: "-"),
            isDirectory: true
        )
        let exactFile = exactDirectory.appendingPathComponent("\(sessionId).jsonl")

        if FileManager.default.fileExists(atPath: exactFile.path) {
            return exactFile
        }

        guard
            let enumerator = FileManager.default.enumerator(
                at: projectsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        for case let file as URL in enumerator {
            guard file.lastPathComponent == "\(sessionId).jsonl" else {
                continue
            }

            return file
        }

        return nil
    }

    private func latestSessionActivity(
        in file: URL,
        decoder: JSONDecoder
    ) -> ClaudeSessionActivity? {
        let modifiedAt = modificationDate(for: file)

        return Self.sessionActivityCache.value(for: file, modifiedAt: modifiedAt) {
            guard
                let data = tailData(for: file),
                let content = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            for line in content.split(whereSeparator: \.isNewline).reversed().prefix(200) {
                guard
                    let data = String(line).data(using: .utf8),
                    let event = try? decoder.decode(ClaudeSessionEventEnvelope.self, from: data),
                    let activity = classifySessionEvent(event)
                else {
                    continue
                }

                return activity
            }

            return nil
        }
    }

    private func tailData(for file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else {
            return nil
        }

        let startOffset = fileSize > Self.logTailBytes
            ? fileSize - Self.logTailBytes
            : 0

        do {
            try handle.seek(toOffset: startOffset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    private func classifySessionEvent(
        _ event: ClaudeSessionEventEnvelope
    ) -> ClaudeSessionActivity? {
        switch event.type {
        case "assistant":
            let stopReason = event.message?.stopReason
            let contentTypes = event.message?.content?.map(\.type) ?? []

            if stopReason == "end_turn" {
                return ClaudeSessionActivity(
                    state: .completed,
                    detail: "Claude session finished",
                    updatedAt: event.timestamp
                )
            }

            if stopReason == "tool_use" || contentTypes.contains("tool_use") {
                return ClaudeSessionActivity(
                    state: .running,
                    detail: "Active Claude session",
                    updatedAt: event.timestamp
                )
            }

            return ClaudeSessionActivity(
                state: .running,
                detail: "Active Claude session",
                updatedAt: event.timestamp
            )
        case "user":
            return ClaudeSessionActivity(
                state: .running,
                detail: "Active Claude session",
                updatedAt: event.timestamp
            )
        case "system":
            guard event.subtype == "stop_hook_summary" || event.subtype == "turn_duration" else {
                return nil
            }

            return ClaudeSessionActivity(
                state: .completed,
                detail: "Claude session finished",
                updatedAt: event.timestamp
            )
        default:
            return nil
        }
    }

    private func modificationDate(for file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func cachedDirectoryContents(
        at directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles],
        filter: ((URL) -> Bool)? = nil,
        cache: FileValueCache<[URL]>
    ) -> [URL] {
        let modifiedAt = modificationDate(for: directory)

        return cache.value(for: directory, modifiedAt: modifiedAt) {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: options
            )) ?? []

            if let filter {
                return urls.filter(filter)
            }

            return urls
        }
    }

    private func cachedDecode<T: Decodable>(
        _ type: T.Type,
        from file: URL,
        decoder: JSONDecoder,
        cache: FileValueCache<T?>
    ) -> T? {
        let modifiedAt = modificationDate(for: file)

        return cache.value(for: file, modifiedAt: modifiedAt) {
            guard let data = try? Data(contentsOf: file) else {
                return nil
            }

            return try? decoder.decode(type, from: data)
        }
    }

    private func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }

        return kill(pid, 0) == 0
    }

    private func classify(_ taskFile: ClaudeTaskFile) -> AgentTaskState? {
        switch taskFile.status {
        case "in_progress":
            return .running
        case "completed":
            return .completed
        case "blocked":
            return .needsInput
        case "pending":
            let haystack = [
                taskFile.subject,
                taskFile.activeForm,
                taskFile.description
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

            let needsInputTerms = [
                "ask clarifying",
                "clarifying question",
                "question",
                "needs input",
                "approval",
                "answer",
                "confirm",
                "choose"
            ]

            return needsInputTerms.contains(where: { haystack.contains($0) })
                ? .needsInput
                : nil
        default:
            return nil
        }
    }
}

private struct ClaudeSessionTaskScan {
    let tasks: [AgentTask]
    let latestCompletedMarker: Double
}

private struct ClaudeTaskDirectoryScan {
    let tasks: [AgentTask]
    let latestCompletedMarker: Double
}

private struct ClaudeSessionFile: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let startedAt: Double
    let kind: String
}

private struct ClaudeSessionActivity {
    let state: AgentTaskState
    let detail: String
    let updatedAt: Date
}

private struct ClaudeSessionEventEnvelope: Decodable {
    let type: String
    let subtype: String?
    let timestamp: Date
    let message: ClaudeSessionEventMessage?
}

private struct ClaudeSessionEventMessage: Decodable {
    let stopReason: String?
    let content: [ClaudeSessionEventContent]?

    private enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
        case content
    }
}

private struct ClaudeSessionEventContent: Decodable {
    let type: String
}

private struct ClaudeTaskFile: Decodable {
    let id: String
    let subject: String
    let description: String?
    let activeForm: String?
    let status: String

    var subtitleText: String {
        if let activeForm, !activeForm.isEmpty {
            return activeForm.normalizedLine(limit: 72)
        }

        if let description, !description.isEmpty {
            return description.normalizedLine(limit: 72)
        }

        return status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct CodexThreadRecord {
    let id: String
    let title: String
    let updatedToken: Double
    let hasUserEvent: Bool
    let spawnStatus: String
    let nickname: String
    let role: String

    var updatedAt: Date {
        Date(timeIntervalSince1970: updatedToken)
    }

    var primaryTitle: String {
        if !nickname.isEmpty {
            return nickname
        }

        return title.normalizedLine(limit: 60)
    }

    func subtitle(prefix: String) -> String {
        let roleLabel = role.isEmpty ? "task" : role
        return "\(prefix) • \(roleLabel)"
    }
}

private struct CodexRootActivityScan {
    let tasks: [AgentTask]
    let latestCompletedMarker: Double
}

private struct CodexRootThreadRecord {
    let id: String
    let title: String
    let updatedToken: Double
    let rolloutPath: String
    let nickname: String
    let role: String

    var updatedAt: Date {
        Date(timeIntervalSince1970: updatedToken)
    }

    var primaryTitle: String {
        if !nickname.isEmpty {
            return nickname
        }

        return title.normalizedLine(limit: 60)
    }

    func subtitle(prefix: String) -> String {
        let roleLabel = role.isEmpty ? "thread" : role
        return "\(prefix) • \(roleLabel)"
    }
}

private enum CodexRolloutTaskEventKind {
    case started
    case completed
}

private struct CodexRolloutTaskEvent {
    let kind: CodexRolloutTaskEventKind
    let timestamp: Date
}

private struct CodexRolloutEventEnvelope: Decodable {
    let timestamp: Date
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
    }
}

private struct CodexGlobalState: Decodable {
    let queuedFollowUps: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case queuedFollowUps = "queued-follow-ups"
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func bestTitle(fallback: String) -> String {
        switch self {
        case let .string(value):
            return value.normalizedLine(limit: 60)
        case let .object(value):
            for key in ["title", "prompt", "summary", "message", "threadTitle"] {
                if case let .string(candidate)? = value[key], !candidate.isEmpty {
                    return candidate.normalizedLine(limit: 60)
                }
            }

            return fallback
        case let .array(items):
            return items.first?.bestTitle(fallback: fallback) ?? fallback
        default:
            return fallback
        }
    }
}

private func taskPriority(_ state: AgentTaskState) -> Int {
    switch state {
    case .needsInput:
        return 0
    case .running:
        return 1
    case .completed:
        return 2
    case .failed:
        return 3
    }
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

private final class SQLiteReader {
    private var database: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &database, flags, nil)

        guard status == SQLITE_OK, database != nil else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) }
                ?? "Could not open SQLite database."
            close()
            throw ReaderError.openFailed(message)
        }
    }

    func close() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
    }

    func query<T>(
        _ sql: String,
        bindings: [Double] = [],
        rowTransform: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        guard let database else {
            throw ReaderError.openFailed("Database handle was not available.")
        }

        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)

        guard prepareStatus == SQLITE_OK, let statement else {
            throw ReaderError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }

        defer {
            sqlite3_finalize(statement)
        }

        for (index, value) in bindings.enumerated() {
            let status = sqlite3_bind_double(statement, Int32(index + 1), value)
            guard status == SQLITE_OK else {
                throw ReaderError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
        }

        var rows: [T] = []

        while true {
            let stepStatus = sqlite3_step(statement)

            if stepStatus == SQLITE_ROW {
                rows.append(try rowTransform(SQLiteStatement(handle: statement)))
                continue
            }

            if stepStatus == SQLITE_DONE {
                break
            }

            throw ReaderError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }

        return rows
    }

    enum ReaderError: LocalizedError {
        case openFailed(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case let .openFailed(message), let .queryFailed(message):
                return message
            }
        }
    }
}

private struct SQLiteStatement {
    let handle: OpaquePointer

    func string(at column: Int32) -> String {
        guard let value = sqlite3_column_text(handle, column) else {
            return ""
        }

        return String(cString: value)
    }

    func double(at column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func int(at column: Int32) -> Int32 {
        sqlite3_column_int(handle, column)
    }
}

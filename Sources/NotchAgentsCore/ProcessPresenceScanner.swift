import Foundation

public enum ProcessPresenceScanner {
    private static let cacheTTL: TimeInterval = 60
    private static let cache = SnapshotCache()

    public static func scan(now: Date = .now) -> [AgentKind: Int] {
        if let cached = cache.value(now: now, ttl: cacheTTL) {
            return cached
        }

        guard let output = Shell.run(
            launchPath: "/bin/ps",
            arguments: ["-axo", "pid=,command="]
        ) else {
            return [:]
        }

        var identitiesByAgent: [AgentKind: Set<String>] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let parts = line.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )

            guard
                parts.count == 2,
                let pid = Int32(parts[0]),
                let agent = resolveAgent(command: String(parts[1]))
            else {
                continue
            }

            let command = String(parts[1])
            let normalized = command.lowercased()

            switch agent {
            case .codex:
                if isCodexRootProcess(normalized) {
                    identitiesByAgent[agent, default: []].insert(
                        codexIdentity(for: command, pid: pid)
                    )
                }
            case .claude:
                if isClaudeRootProcess(normalized) {
                    identitiesByAgent[agent, default: []].insert(
                        claudeIdentity(for: command, pid: pid)
                    )
                }
            }
        }

        let snapshot = identitiesByAgent.mapValues(\.count)
        cache.store(snapshot, at: now)
        return snapshot
    }

    private static func resolveAgent(command: String) -> AgentKind? {
        let normalized = command.lowercased()
        let firstToken = normalized
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? normalized
        let executable = URL(fileURLWithPath: firstToken).lastPathComponent

        switch executable {
        case "codex":
            return .codex
        case "claude", "claude-code":
            return .claude
        default:
            if normalized.contains("/codex.app/contents/macos/codex") {
                return .codex
            }

            if normalized.contains("/claude.app/contents/macos/claude") {
                return .claude
            }

            return nil
        }
    }

    private static func isCodexRootProcess(_ command: String) -> Bool {
        command.split(whereSeparator: \.isWhitespace).first.map(String.init) == "codex"
    }

    private static func isClaudeRootProcess(_ command: String) -> Bool {
        if command.contains("/applications/claude.app/contents/macos/claude") {
            return true
        }

        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return executable == "claude" || executable == "claude-code"
    }

    private static func codexIdentity(for command: String, pid: Int32) -> String {
        let normalized = command.lowercased()
        if normalized.contains("/applications/codex.app/contents/macos/codex")
            || normalized.contains("/contents/resources/codex app-server") {
            return "codex.app"
        }

        return "pid:\(pid)"
    }

    private static func claudeIdentity(for command: String, pid: Int32) -> String {
        let normalized = command.lowercased()
        if normalized.contains("/applications/claude.app/contents/macos/claude") {
            return "claude.app"
        }

        return "pid:\(pid)"
    }
}

private final class SnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: [AgentKind: Int] = [:]
    private var updatedAt: Date?

    func value(
        now: Date,
        ttl: TimeInterval
    ) -> [AgentKind: Int]? {
        lock.lock()
        defer { lock.unlock() }

        guard let updatedAt, now.timeIntervalSince(updatedAt) < ttl else {
            return nil
        }

        return snapshot
    }

    func store(
        _ snapshot: [AgentKind: Int],
        at date: Date
    ) {
        lock.lock()
        self.snapshot = snapshot
        updatedAt = date
        lock.unlock()
    }
}

private enum Shell {
    static func run(launchPath: String, arguments: [String]) -> String? {
        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

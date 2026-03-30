import Foundation
import NotchAgentsCore

struct CLIError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

do {
    try runCLI(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(
        Data("error: \(error.localizedDescription)\n".utf8)
    )
    exit(1)
}

private func runCLI(arguments: [String]) throws {
    guard let command = arguments.first else {
        throw CLIError(message: usage())
    }

    switch command {
    case "sample":
        try StatusSnapshotStore.save(.sample)
        print("Wrote sample data to \(StatusFileLocation.snapshotURL.path)")
    case "clear":
        try StatusSnapshotStore.save(.empty)
        print("Cleared \(StatusFileLocation.snapshotURL.path)")
    case "show":
        try printSnapshotAndSummaries(
            snapshot: try StatusSnapshotStore.loadIfPresent() ?? .empty,
            heading: nil
        )
    case "live":
        let live = try LiveStatusScanner.scan()
        try printSnapshotAndSummaries(
            snapshot: live.snapshot,
            heading: "Live state"
        )
    case "merged":
        let manual = try StatusSnapshotStore.loadIfPresent() ?? .empty
        let live = try LiveStatusScanner.scan()
        try printSnapshotAndSummaries(
            snapshot: live.snapshot.merged(with: manual),
            heading: "Merged state"
        )
    case "install-claude-hooks":
        let options = try parseOptions(Array(arguments.dropFirst()))
        let command = options["command"] ?? ClaudeHookSupport.defaultCommand
        let result = try ClaudeHookSupport.install(command: command)
        let verb = result.didChange ? "Installed" : "Verified"
        print("\(verb) Claude hooks in \(result.settingsURL.path)")
    case "claude-hook":
        let data = FileHandle.standardInput.readDataToEndOfFile()
        _ = try ClaudeHookSupport.applyHookPayload(data)
    case "start", "ask", "finish", "fail", "remove":
        try mutateSnapshot(command: command, rawOptions: Array(arguments.dropFirst()))
        print("Updated \(StatusFileLocation.snapshotURL.path)")
    default:
        throw CLIError(message: usage())
    }
}

private func mutateSnapshot(command: String, rawOptions: [String]) throws {
    let options = try parseOptions(rawOptions)
    let agent = try parseAgent(options["agent"])
    let taskID = try requiredOption("id", from: options)

    try StatusSnapshotStore.mutate { snapshot in
        let side = options["side"].flatMap(parseSide)

        switch command {
        case "remove":
            snapshot.removeTask(for: agent, taskID: taskID)
        case "start", "ask", "finish", "fail":
            let title = options["title"] ?? taskID
            let state = try! parseState(for: command)
            let task = AgentTask(
                id: taskID,
                title: title,
                state: state,
                detail: options["detail"],
                question: options["question"],
                actionURL: options["url"].flatMap(URL.init(string:)),
                updatedAt: .now
            )
            snapshot.upsertTask(for: agent, side: side, task: task)
        default:
            break
        }
    }
}

private func parseOptions(_ rawOptions: [String]) throws -> [String: String] {
    guard rawOptions.count.isMultiple(of: 2) else {
        throw CLIError(message: usage())
    }

    var options: [String: String] = [:]
    var index = 0

    while index < rawOptions.count {
        let key = rawOptions[index]
        let value = rawOptions[index + 1]

        guard key.hasPrefix("--") else {
            throw CLIError(message: usage())
        }

        options[String(key.dropFirst(2))] = value
        index += 2
    }

    return options
}

private func requiredOption(
    _ name: String,
    from options: [String: String]
) throws -> String {
    guard let value = options[name], !value.isEmpty else {
        throw CLIError(message: "Missing --\(name)\n\n\(usage())")
    }

    return value
}

private func parseAgent(_ value: String?) throws -> AgentKind {
    guard let value, let agent = AgentKind(rawValue: value.lowercased()) else {
        throw CLIError(message: "Use --agent codex or --agent claude\n\n\(usage())")
    }

    return agent
}

private func parseSide(_ value: String) -> AgentSide? {
    AgentSide(rawValue: value.lowercased())
}

private func parseState(for command: String) throws -> AgentTaskState {
    switch command {
    case "start":
        return .running
    case "ask":
        return .needsInput
    case "finish":
        return .completed
    case "fail":
        return .failed
    default:
        throw CLIError(message: usage())
    }
}

private func usage() -> String {
    """
    Usage:
      notchagentsctl sample
      notchagentsctl clear
      notchagentsctl show
      notchagentsctl live
      notchagentsctl merged
      notchagentsctl install-claude-hooks [--command "/Users/you/.local/bin/notchagentsctl claude-hook"]
      notchagentsctl claude-hook
      notchagentsctl start --agent codex --id task-1 [--title "Build"] [--detail "..."] [--url "https://..."] [--side leading]
      notchagentsctl ask --agent claude --id task-2 [--title "Review"] --question "Need an answer" [--url "https://..."]
      notchagentsctl finish --agent codex --id task-1 [--title "Build"]
      notchagentsctl fail --agent claude --id task-2 [--title "Review"] [--detail "What failed"]
      notchagentsctl remove --agent codex --id task-1
    """
}

private func printSnapshotAndSummaries(
    snapshot: StatusSnapshot,
    heading: String?
) throws {
    if let heading {
        print("\(heading):")
    }

    print(try StatusSnapshotStore.prettyPrinted(snapshot))
    let summaries = AgentSummaryResolver.resolve(
        snapshot: snapshot,
        processCounts: ProcessPresenceScanner.scan()
    )
    print("")
    for summary in summaries {
        let countText = summary.count > 1 ? " x\(summary.count)" : ""
        let sourceText = summary.isInferredFromProcess ? " (process)" : ""
        print("\(summary.agent.displayName): \(summary.status.rawValue)\(countText)\(sourceText)")
    }
}

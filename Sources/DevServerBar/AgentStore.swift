import Combine
import Foundation
import NotchAgentsCore

@MainActor
final class AgentStore: ObservableObject {
    private static let runningRefreshInterval: TimeInterval = 60
    private static let attentionRefreshInterval: TimeInterval = 5 * 60
    private static let idleRefreshInterval: TimeInterval = 15 * 60
    private static let errorRefreshInterval: TimeInterval = 60
    private static let eventRefreshDebounce: TimeInterval = 0.8

    @Published private(set) var snapshot: StatusSnapshot = .empty
    @Published private(set) var summaries: [AgentSummary] = []
    @Published private(set) var lastError: String?

    let statusFileURL = StatusFileLocation.snapshotURL

    private let completionMarkerStore = CompletionMarkerStore()
    private var latestCompletedMarkers: [AgentKind: Double] = [:]
    private var timer: Timer?
    private var eventMonitor: PathEventMonitor?
    private var pendingEventRefresh: DispatchWorkItem?
    private var isRefreshing = false
    private var refreshQueuedWhileBusy = false

    init() {
        _ = try? StatusSnapshotStore.ensureStatusFile(at: statusFileURL)
        eventMonitor = PathEventMonitor(paths: refreshWatchPaths()) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleEventDrivenRefresh()
            }
        }
        eventMonitor?.start()
        refresh()
    }

    func refresh() {
        guard !isRefreshing else {
            refreshQueuedWhileBusy = true
            return
        }

        isRefreshing = true
        timer?.invalidate()
        timer = nil

        let initialMarkers = completionMarkerStore.currentMarkers()
        let completionMarkerStore = completionMarkerStore

        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.isRefreshing = false
                    if self?.refreshQueuedWhileBusy == true {
                        self?.refreshQueuedWhileBusy = false
                        self?.scheduleEventDrivenRefresh(after: 0.15)
                    }
                }
            }

            let processCounts = ProcessPresenceScanner.scan()
            var errors: [String] = []

            let manualSnapshot: StatusSnapshot
            do {
                manualSnapshot = try StatusSnapshotStore.loadIfPresent() ?? .empty
            } catch {
                manualSnapshot = .empty
                errors.append("Status file: \(error.localizedDescription)")
            }

            do {
                var liveScan = try LiveStatusScanner.scan(
                    completedMarkers: initialMarkers
                )

                let didBootstrap = completionMarkerStore.bootstrapIfNeeded(
                    from: liveScan.latestCompletedMarkers
                )

                if didBootstrap {
                    liveScan = try LiveStatusScanner.scan(
                        completedMarkers: completionMarkerStore.currentMarkers()
                    )
                }

                let mergedSnapshot = liveScan.snapshot.merged(with: manualSnapshot)
                let summaries = AgentSummaryResolver.resolve(
                    snapshot: mergedSnapshot,
                    processCounts: processCounts
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.snapshot.agents != mergedSnapshot.agents {
                        self.snapshot = mergedSnapshot
                    }
                    if self.summaries != summaries {
                        self.summaries = summaries
                    }
                    self.latestCompletedMarkers = liveScan.latestCompletedMarkers
                    let lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
                    if self.lastError != lastError {
                        self.lastError = lastError
                    }
                    self.scheduleRefresh(after: self.refreshInterval(for: summaries))
                }
            } catch {
                errors.append("Live scan: \(error.localizedDescription)")

                let summaries = AgentSummaryResolver.resolve(
                    snapshot: manualSnapshot,
                    processCounts: processCounts
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.snapshot.agents != manualSnapshot.agents {
                        self.snapshot = manualSnapshot
                    }
                    if self.summaries != summaries {
                        self.summaries = summaries
                    }
                    let lastError = errors.joined(separator: "\n")
                    if self.lastError != lastError {
                        self.lastError = lastError
                    }
                    self.scheduleRefresh(after: Self.errorRefreshInterval)
                }
            }
        }
    }

    func writeSampleData() {
        save(.sample)
    }

    func clearSnapshot() {
        save(.empty)
    }

    func ensureStatusFile() throws -> URL {
        try StatusSnapshotStore.ensureStatusFile(at: statusFileURL)
    }

    func markCompletedSeen(for agent: AgentKind) {
        guard let marker = latestCompletedMarkers[agent] else { return }
        completionMarkerStore.set(marker, for: agent)
        refresh()
    }

    private func save(_ snapshot: StatusSnapshot) {
        do {
            try StatusSnapshotStore.save(snapshot, at: statusFileURL)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func scheduleEventDrivenRefresh(
        after delay: TimeInterval
    ) {
        pendingEventRefresh?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        pendingEventRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleEventDrivenRefresh() {
        scheduleEventDrivenRefresh(after: Self.eventRefreshDebounce)
    }

    private func scheduleRefresh(after interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func refreshInterval(for summaries: [AgentSummary]) -> TimeInterval {
        if summaries.contains(where: { $0.status == .running }) {
            return Self.runningRefreshInterval
        }

        if summaries.contains(where: {
            $0.status == .needsInput || $0.status == .success || $0.status == .failure
        }) {
            return Self.attentionRefreshInterval
        }

        return Self.idleRefreshInterval
    }

    private func refreshWatchPaths() -> [String] {
        [
            StatusFileLocation.directoryURL.path,
            NSString(string: "~/.codex").expandingTildeInPath,
            NSString(string: "~/.claude").expandingTildeInPath
        ]
    }
}

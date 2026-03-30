import Foundation
import NotchAgentsCore

final class CompletionMarkerStore: @unchecked Sendable {
    private let defaults = UserDefaults.standard

    func currentMarkers() -> [AgentKind: Double] {
        Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { agent in
            let marker = defaults.object(forKey: key(for: agent)) as? Double ?? 0
            return (agent, marker)
        })
    }

    func set(_ marker: Double, for agent: AgentKind) {
        defaults.set(marker, forKey: key(for: agent))
    }

    func bootstrapIfNeeded(from markers: [AgentKind: Double]) -> Bool {
        var mutated = false

        for agent in AgentKind.allCases {
            let storageKey = key(for: agent)

            guard defaults.object(forKey: storageKey) == nil else {
                continue
            }

            defaults.set(markers[agent] ?? 0, forKey: storageKey)
            mutated = true
        }

        return mutated
    }

    private func key(for agent: AgentKind) -> String {
        "NotchAgents.completed-marker.\(agent.rawValue)"
    }
}

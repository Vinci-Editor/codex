//
//  CodexModelCatalog+ServiceTiers.swift
//  CodexKit
//
//  Created by Ethan Lipnik.
//

import Foundation

extension CodexModelCatalog {
    static func reasoningEfforts(_ value: Any?) -> [CodexReasoningEffortOption] {
        guard let values = value as? [[String: Any]] else {
            return []
        }
        return values.compactMap { item in
            let effort = string(item["reasoningEffort"]) ?? string(item["effort"])
            guard let normalized = normalizedReasoningEffort(effort) else {
                return nil
            }
            return CodexReasoningEffortOption(
                reasoningEffort: normalized,
                description: string(item["description"]) ?? ""
            )
        }
    }

    static func serviceTiers(_ value: Any?, additionalSpeedTiers: [String]) -> [CodexServiceTierOption] {
        var tiers: [CodexServiceTierOption] = []
        if let values = value as? [[String: Any]] {
            tiers = values.compactMap { item in
                guard let id = normalizedServiceTier(string(item["id"])) else {
                    return nil
                }
                return CodexServiceTierOption(
                    id: id,
                    name: string(item["name"]) ?? defaultServiceTierName(id),
                    description: string(item["description"]) ?? ""
                )
            }
        }

        var seen = Set(tiers.map(\.id))
        for speedTier in additionalSpeedTiers {
            guard let id = normalizedServiceTier(speedTier),
                  seen.insert(id).inserted else {
                continue
            }
            tiers.append(CodexServiceTierOption(
                id: id,
                name: defaultServiceTierName(id),
                description: ""
            ))
        }
        return tiers
    }
}

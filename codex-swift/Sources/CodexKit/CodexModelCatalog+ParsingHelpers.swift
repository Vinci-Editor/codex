//
//  CodexModelCatalog+ParsingHelpers.swift
//  CodexKit
//
//  Created by Ethan Lipnik.
//

import Foundation

extension CodexModelCatalog {
    static func normalizedServiceTier(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let normalized = value.lowercased()
        switch normalized {
        case "fast":
            return "priority"
        default:
            return normalized
        }
    }

    static func normalizedReasoningSummary(_ value: String?) -> CodexReasoningSummary? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return CodexReasoningSummary(rawValue: value.lowercased())
    }

    static func normalizedVerbosity(_ value: String?) -> CodexVerbosity? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return CodexVerbosity(rawValue: value.lowercased())
    }

    static func defaultServiceTierName(_ id: String) -> String {
        switch id {
        case "priority":
            return "Priority"
        case "flex":
            return "Flex"
        case "default":
            return "Standard"
        default:
            return id
                .split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    static func sortByPriority(_ lhs: DecodedModel, _ rhs: DecodedModel) -> Bool {
        switch (lhs.priority, rhs.priority) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs < rhs
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.option.displayName.localizedStandardCompare(rhs.option.displayName) == .orderedAscending
        }
    }

    static func normalizedReasoningEffort(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    static func stringArray(_ value: Any?, fallback: [String]) -> [String] {
        guard let values = value as? [Any] else {
            return fallback
        }
        let strings = values.compactMap(string)
        return strings.isEmpty ? fallback : strings
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String where !value.isEmpty:
            return value
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as String:
            return value == "true"
        case let value as Int:
            return value != 0
        default:
            return false
        }
    }

    static func optionalBool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as String:
            switch value.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        case let value as NSNumber:
            return value.boolValue
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    struct DecodedModel {
        let option: CodexModelOption
        let priority: Int?
    }
}

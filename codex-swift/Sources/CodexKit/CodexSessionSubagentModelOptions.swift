//
//  Created by Ethan Lipnik
//

import Foundation
import CoreGraphics
import CodexMobileCoreBridge
import ImageIO
import UniformTypeIdentifiers

extension CodexSession {
    static func subagentModelOverrideDescription(options: CodexTurnOptions?) -> String {
        let models = Array(subagentVisibleModelOptions(options: options).prefix(maxSubagentModelOverrideDescriptions))
        guard !models.isEmpty else {
            return "No picker-visible model overrides are currently loaded."
        }

        let lines = models.map { model in
            let efforts = model.supportedReasoningEfforts
                .map { effort in
                    if effort.reasoningEffort == model.defaultReasoningEffort {
                        return "\(effort.reasoningEffort) (default)"
                    }
                    return effort.reasoningEffort
                }
                .joined(separator: ", ")
            let effortsSuffix = efforts.isEmpty ? "" : " Reasoning efforts: \(efforts)."
            let serviceTiers = model.serviceTiers
                .filter { $0.id != "default" }
                .map(\.id)
                .joined(separator: ", ")
            let serviceTierSuffix = serviceTiers.isEmpty ? "" : " Service tiers: \(serviceTiers)."
            let description = model.description.isEmpty ? model.displayName : model.description
            return "- `\(model.model)`: \(description)\(effortsSuffix)\(serviceTierSuffix)"
        }
        return "Available model overrides (optional; inherited parent model is preferred):\n\(lines.joined(separator: "\n"))"
    }

    static func subagentInheritedModelGuidance(options: CodexTurnOptions?) -> String {
        var parts: [String] = []
        if let model = options?.model, !model.isEmpty {
            parts.append("Omit `model` to inherit `\(model)`.")
        }
        if let effort = options?.reasoningEffort, !effort.isEmpty {
            parts.append("Omit `reasoning_effort` to inherit `\(effort)`.")
        }
        if let serviceTier = options?.serviceTier, !serviceTier.isEmpty {
            parts.append("Omit `service_tier` to inherit `\(serviceTier)`.")
        }
        return parts.joined(separator: " ")
    }

    static func subagentRoleDescription(roles: [CodexSubagentRole]) -> String {
        guard !roles.isEmpty else {
            return ""
        }
        let lines = roles.map { role in
            var details = role.description.isEmpty ? "no description" : role.description
            if role.model != nil || role.reasoningEffort != nil || role.serviceTier != nil {
                var locked: [String] = []
                if let model = role.model {
                    locked.append("model=\(model)")
                }
                if let reasoningEffort = role.reasoningEffort {
                    locked.append("reasoning_effort=\(reasoningEffort)")
                }
                if let serviceTier = role.serviceTier {
                    locked.append("service_tier=\(serviceTier)")
                }
                details += " Locked settings: \(locked.joined(separator: ", "))."
            }
            return "- `\(role.name)`: \(details)"
        }
        return "Available agent types:\n\(lines.joined(separator: "\n"))"
    }

    static func subagentVisibleModelOptions(options: CodexTurnOptions?) -> [CodexModelOption] {
        let models = options?.availableModelOptions ?? []
        var seen: Set<String> = []
        return models.compactMap { model in
            guard !model.isHidden, seen.insert(model.model).inserted else {
                return nil
            }
            return model
        }
    }

    static func subagentModelOverrideValues(options: CodexTurnOptions?) -> [String] {
        Array(subagentVisibleModelOptions(options: options)
            .map(\.model)
            .prefix(maxSubagentModelOverrideDescriptions))
    }

    static func subagentReasoningEffortValues(options: CodexTurnOptions?) -> [String] {
        let values = subagentVisibleModelOptions(options: options)
            .flatMap { $0.supportedReasoningEfforts.map(\.reasoningEffort) }
            + [options?.reasoningEffort].compactMap { $0 }
        return orderedUnique(values)
    }

    static func subagentServiceTierValues(options: CodexTurnOptions?) -> [String] {
        let values = subagentVisibleModelOptions(options: options)
            .flatMap { $0.serviceTiers.map(\.id) }
            .filter { $0 != "default" }
            + [options?.serviceTier].compactMap { $0 }
        return orderedUnique(values)
    }

    static func subagentTurnOptionsValidationError(
        arguments: [String: Any],
        parentOptions: CodexTurnOptions?,
        role: CodexSubagentRole? = nil
    ) -> String? {
        let requestedModel = trimmedNonEmpty(arguments["model"] as? String)
        let requestedReasoningEffort = trimmedNonEmpty(arguments["reasoning_effort"] as? String)
        let requestedServiceTier = trimmedNonEmpty(arguments["service_tier"] as? String)
        if let role {
            if role.model != nil, requestedModel != nil {
                return "agent_type `\(role.name)` sets its own model; omit model for spawn_agent."
            }
            if role.reasoningEffort != nil, requestedReasoningEffort != nil {
                return "agent_type `\(role.name)` sets its own reasoning effort; omit reasoning_effort for spawn_agent."
            }
            if role.serviceTier != nil, requestedServiceTier != nil {
                return "agent_type `\(role.name)` sets its own service tier; omit service_tier for spawn_agent."
            }
        }
        guard requestedModel != nil || requestedReasoningEffort != nil || requestedServiceTier != nil else {
            return nil
        }

        let models = subagentVisibleModelOptions(options: parentOptions)
        let selectedModel: CodexModelOption?
        if let requestedModel {
            guard models.isEmpty == false else {
                return nil
            }
            guard let model = models.first(where: { $0.model == requestedModel }) else {
                return "Unknown model `\(requestedModel)` for spawn_agent. Available models: \(availableValuesDescription(models.map(\.model)))."
            }
            selectedModel = model
        } else if let parentModel = trimmedNonEmpty(parentOptions?.model) {
            selectedModel = models.first(where: { $0.model == parentModel })
        } else {
            selectedModel = nil
        }

        if let requestedReasoningEffort {
            if let selectedModel {
                let supported = selectedModel.supportedReasoningEfforts.map(\.reasoningEffort)
                if !supported.isEmpty, !supported.contains(requestedReasoningEffort) {
                    return "Reasoning effort `\(requestedReasoningEffort)` is not supported for model `\(selectedModel.model)`. Supported reasoning efforts: \(availableValuesDescription(supported))."
                }
            } else {
                let supported = subagentReasoningEffortValues(options: parentOptions)
                if !supported.isEmpty, !supported.contains(requestedReasoningEffort) {
                    return "Reasoning effort `\(requestedReasoningEffort)` is not available for spawn_agent. Available reasoning efforts: \(availableValuesDescription(supported))."
                }
            }
        }

        if let requestedServiceTier {
            if let selectedModel {
                let supported = selectedModel.serviceTiers
                    .map(\.id)
                    .filter { $0 != "default" }
                if !supported.contains(requestedServiceTier) {
                    return "Service tier `\(requestedServiceTier)` is not supported for model `\(selectedModel.model)`. Supported service tiers: \(availableValuesDescription(supported))."
                }
            } else {
                let supported = subagentServiceTierValues(options: parentOptions)
                if !supported.isEmpty, !supported.contains(requestedServiceTier) {
                    return "Service tier `\(requestedServiceTier)` is not available for spawn_agent. Available service tiers: \(availableValuesDescription(supported))."
                }
            }
        }

        return nil
    }

    static func subagentSpawnArgumentsValidationError(
        arguments: [String: Any],
        parentOptions: CodexTurnOptions?,
        role: CodexSubagentRole? = nil
    ) -> String? {
        if arguments["fork_context"] != nil {
            return "fork_context is not supported; use fork_turns instead."
        }
        if let forkTurnsError = subagentForkTurnsValidationError(arguments: arguments) {
            return forkTurnsError
        }
        if subagentUsesFullHistoryFork(arguments: arguments) {
            let requestedRole = trimmedNonEmpty(arguments["agent_type"] as? String)
            let requestedModel = trimmedNonEmpty(arguments["model"] as? String)
            let requestedReasoningEffort = trimmedNonEmpty(arguments["reasoning_effort"] as? String)
            if requestedRole != nil || requestedModel != nil || requestedReasoningEffort != nil {
                return "Full-history forked agents inherit the parent agent type, model, and reasoning effort; omit agent_type, model, and reasoning_effort, or spawn with fork_turns set to none or a positive integer string."
            }
        }
        return subagentTurnOptionsValidationError(arguments: arguments, parentOptions: parentOptions, role: role)
    }

    static func subagentForkTurnsValidationError(arguments: [String: Any]) -> String? {
        guard let rawForkTurns = arguments["fork_turns"] else {
            return nil
        }
        guard let forkTurns = rawForkTurns as? String else {
            return "fork_turns must be `none`, `all`, or a positive integer string."
        }
        let normalized = forkTurns.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized != "none", normalized != "all" else {
            return nil
        }
        guard let value = Int(normalized), value > 0 else {
            return "fork_turns must be `none`, `all`, or a positive integer string."
        }
        return nil
    }

    static func subagentUsesFullHistoryFork(arguments: [String: Any]) -> Bool {
        guard let forkTurns = arguments["fork_turns"] as? String else {
            return true
        }
        let normalized = forkTurns.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "all"
    }

    static func availableValuesDescription(_ values: [String]) -> String {
        let uniqueValues = orderedUnique(values)
        guard !uniqueValues.isEmpty else {
            return "none"
        }
        return uniqueValues.joined(separator: ", ")
    }

    static func schemaStringProperty(description: String, enumValues: [String]) -> [String: Any] {
        var property: [String: Any] = [
            "type": "string",
            "description": description,
        ]
        if !enumValues.isEmpty {
            property["enum"] = enumValues
        }
        return property
    }

    static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            guard !value.isEmpty else {
                return false
            }
            return seen.insert(value).inserted
        }
    }

    static func errorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 16_384 {
                break
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

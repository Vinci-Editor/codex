//
//  Created by Ethan Lipnik
//

import Foundation
#if os(macOS)
import Darwin
#endif
#if canImport(CodexMobileCore)
import CodexMobileCore
#endif
#if canImport(JustBash) && canImport(JustBashFS)
import JustBash
import JustBashCommands
import JustBashFS
#endif
#if canImport(JustBashJavaScript)
import JustBashJavaScript
#endif

extension CodexMobileCoreBridge {
    static func functionTool(
        name: String,
        description: String,
        required: [String],
        properties: [String: Any],
        outputSchema: [String: Any]? = nil
    ) -> [String: Any] {
        var tool: [String: Any] = [
            "type": "function",
            "name": name,
            "description": description,
            "strict": false,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ],
        ]
        if let outputSchema {
            tool["output_schema"] = outputSchema
        }
        return tool
    }

    static func requiredString(_ value: Any?, field: String) throws -> String {
        guard let value = value as? String, !value.isEmpty else {
            throw CodexMobileCoreBridgeError.missingField(field)
        }
        return value
    }

    static func intValue(_ value: Any?) -> Int? {
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

    #if canImport(CodexMobileCore)
    typealias RustJSONFunction = (UnsafePointer<CChar>?) -> CodexMobileBuffer

    static func rustObject(_ buffer: CodexMobileBuffer) throws -> [String: Any] {
        try decodeObject(rustBufferData(buffer))
    }

    static func rustData(input: [String: Any], _ function: RustJSONFunction) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: input, options: [])
        let text = String(decoding: data, as: UTF8.self)
        return try rustData(input: text, function)
    }

    static func rustData(input: String, _ function: RustJSONFunction) throws -> Data {
        let data = input.withCString { pointer in
            rustBufferData(function(pointer))
        }
        try throwIfRustError(data)
        return data
    }

    static func rustBufferData(_ buffer: CodexMobileBuffer) -> Data {
        defer { codex_mobile_buffer_free(buffer) }
        guard let pointer = buffer.ptr, buffer.len > 0 else {
            return Data()
        }
        return Data(bytes: pointer, count: Int(buffer.len))
    }

    static func throwIfRustError(_ data: Data) throws {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["ok"] as? Bool == false
        else {
            return
        }
        throw CodexMobileCoreBridgeError.rustError(object["error"] as? String ?? "unknown Rust error")
    }
    #endif

    static func decodeObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let object = object as? [String: Any] else {
            throw CodexMobileCoreBridgeError.invalidJSON
        }
        return object
    }
}

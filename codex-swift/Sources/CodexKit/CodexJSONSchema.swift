import Foundation

public struct CodexJSONSchema: Sendable {
    public let dictionary: [String: any Sendable]

    public init(_ dictionary: [String: any Sendable]) {
        self.dictionary = dictionary
    }

    public static func string(description: String? = nil) -> CodexJSONSchema {
        primitive("string", description: description)
    }

    public static func number(description: String? = nil) -> CodexJSONSchema {
        primitive("number", description: description)
    }

    public static func integer(description: String? = nil) -> CodexJSONSchema {
        primitive("integer", description: description)
    }

    public static func boolean(description: String? = nil) -> CodexJSONSchema {
        primitive("boolean", description: description)
    }

    public static func stringEnum(_ values: [String], description: String? = nil) -> CodexJSONSchema {
        var schema = primitive("string", description: description).dictionary
        schema["enum"] = values
        return CodexJSONSchema(schema)
    }

    public static func array(items: CodexJSONSchema, description: String? = nil) -> CodexJSONSchema {
        var schema: [String: any Sendable] = [
            "type": "array",
            "items": items.dictionary,
        ]
        if let description {
            schema["description"] = description
        }
        return CodexJSONSchema(schema)
    }

    public static func object(
        properties: [String: CodexJSONSchema],
        required: [String] = [],
        additionalProperties: Bool = false,
        description: String? = nil
    ) -> CodexJSONSchema {
        var encodedProperties: [String: any Sendable] = [:]
        for (name, schema) in properties {
            encodedProperties[name] = schema.dictionary
        }

        var schema: [String: any Sendable] = [
            "type": "object",
            "properties": encodedProperties,
            "required": required,
            "additionalProperties": additionalProperties,
        ]
        if let description {
            schema["description"] = description
        }
        return CodexJSONSchema(schema)
    }

    public static func raw(_ dictionary: [String: any Sendable]) -> CodexJSONSchema {
        CodexJSONSchema(dictionary)
    }

    public var inputSchema: [String: any Sendable] {
        dictionary
    }

    private static func primitive(_ type: String, description: String?) -> CodexJSONSchema {
        var schema: [String: any Sendable] = ["type": type]
        if let description {
            schema["description"] = description
        }
        return CodexJSONSchema(schema)
    }
}

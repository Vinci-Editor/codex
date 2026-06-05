import Foundation
import Testing
@testable import CodexKit
@testable import CodexMobileCoreBridge


@Test
func providerDefaultsExposeOpenAIAndLocalProviders() {
    let providers = CodexProvider.defaults()

    #expect(providers.map(\.id) == ["openai", "lmstudio", "ollama"])
    #expect(providers[0].baseURL.absoluteString == "https://chatgpt.com/backend-api/codex")
    #expect(providers[1].baseURL.absoluteString == "http://127.0.0.1:1234/v1")
}


@Test
func modelCatalogDecodesCodexBackendModels() throws {
    let data = Data("""
    {
      "models": [
        {
          "slug": "hidden",
          "display_name": "Hidden",
          "description": "Hidden model",
          "default_reasoning_level": "medium",
          "supported_reasoning_levels": [],
          "visibility": "hide",
          "supported_in_api": true,
          "priority": 0,
          "input_modalities": ["text"]
        },
        {
          "slug": "gpt-5.4",
          "display_name": "GPT-5.4",
          "description": "Latest",
          "default_reasoning_level": "medium",
          "supported_reasoning_levels": [
            {"effort": "low", "description": "Low"},
            {"effort": "xhigh", "description": "Extra high"}
          ],
          "visibility": "list",
          "supported_in_api": true,
          "use_responses_lite": true,
          "supports_reasoning_summaries": true,
          "default_reasoning_summary": "detailed",
          "support_verbosity": true,
          "default_verbosity": "low",
          "service_tiers": [
            {"id": "priority", "name": "Priority", "description": "Faster"}
          ],
          "default_service_tier": "priority",
          "priority": 2,
          "input_modalities": ["text", "image"]
        }
      ]
    }
    """.utf8)

    let models = try CodexModelCatalog.decodeModelsResponse(data, provider: .openAI)

    #expect(models.map(\.id) == ["gpt-5.4"])
    #expect(models[0].isDefault)
    #expect(models[0].defaultReasoningEffort == "medium")
    #expect(models[0].supportedReasoningEfforts.map(\.reasoningEffort) == ["low", "xhigh"])
    #expect(models[0].usesResponsesLite)
    #expect(models[0].inputModalities == ["text", "image"])
    #expect(models[0].supportsReasoningSummaries == true)
    #expect(models[0].defaultReasoningSummary == .detailed)
    #expect(models[0].supportsVerbosity == true)
    #expect(models[0].defaultVerbosity == .low)
    #expect(models[0].serviceTiers.map(\.id) == ["priority"])
    #expect(models[0].defaultServiceTier == "priority")
}


@Test
func modelCatalogDecodesAppServerResponsesLiteModels() throws {
    let data = Data("""
    {
      "data": [
        {
          "id": "gpt-5.4",
          "displayName": "GPT-5.4",
          "supportedReasoningEfforts": [
            {"reasoningEffort": "medium", "description": "Medium"}
          ],
          "usesResponsesLite": true,
          "serviceTiers": [
            {"id": "flex", "name": "Flex", "description": "Flexible throughput"}
          ],
          "defaultServiceTier": "flex",
          "supportsReasoningSummaries": true,
          "defaultReasoningSummary": "concise",
          "supportsVerbosity": true,
          "defaultVerbosity": "high",
          "inputModalities": ["text", "image"]
        }
      ]
    }
    """.utf8)

    let models = try CodexModelCatalog.decodeModelsResponse(data, provider: .openAI)

    #expect(models.map(\.id) == ["gpt-5.4"])
    #expect(models[0].usesResponsesLite)
    #expect(models[0].inputModalities == ["text", "image"])
    #expect(models[0].supportsReasoningSummaries == true)
    #expect(models[0].defaultReasoningSummary == .concise)
    #expect(models[0].supportsVerbosity == true)
    #expect(models[0].defaultVerbosity == .high)
    #expect(models[0].serviceTiers.map(\.id) == ["flex"])
    #expect(models[0].defaultServiceTier == "flex")
}


@Test
func modelCatalogDecodesDeprecatedAdditionalSpeedTiers() throws {
    let data = Data("""
    {
      "models": [
        {
          "slug": "gpt-5.4",
          "display_name": "GPT-5.4",
          "default_reasoning_level": "medium",
          "supported_reasoning_levels": [],
          "visibility": "list",
          "supported_in_api": true,
          "additional_speed_tiers": ["fast"],
          "default_service_tier": "fast",
          "priority": 1,
          "input_modalities": ["text"]
        }
      ]
    }
    """.utf8)

    let models = try CodexModelCatalog.decodeModelsResponse(data, provider: .openAI)

    #expect(models[0].serviceTiers.map(\.id) == ["priority"])
    #expect(models[0].serviceTiers[0].name == "Priority")
    #expect(models[0].defaultServiceTier == "priority")
}


@Test
func modelOptionDecodesOlderPersistedValuesWithoutResponsesLiteFlag() throws {
    let data = Data("""
    {
      "id": "gpt-5.4",
      "model": "gpt-5.4",
      "displayName": "GPT-5.4",
      "inputModalities": ["text"]
    }
    """.utf8)

    let option = try JSONDecoder().decode(CodexModelOption.self, from: data)

    #expect(option.usesResponsesLite == false)
    #expect(option.inputModalities == ["text"])
    #expect(option.supportsReasoningSummaries == nil)
    #expect(option.defaultReasoningSummary == nil)
    #expect(option.supportsVerbosity == nil)
    #expect(option.defaultVerbosity == nil)
    #expect(option.serviceTiers.isEmpty)
    #expect(option.defaultServiceTier == nil)
}


@Test
func modelCatalogDecodesOpenAICompatibleModels() throws {
    let data = Data("""
    {
      "data": [
        {"id": "qwen/qwen3-coder", "object": "model"},
        {"id": "openai/gpt-oss-20b", "object": "model"}
      ]
    }
    """.utf8)

    let models = try CodexModelCatalog.decodeModelsResponse(data, provider: .lmStudio())

    #expect(models.map(\.id) == ["qwen/qwen3-coder", "openai/gpt-oss-20b"])
    #expect(models[0].isDefault)
    #expect(models[0].supportedReasoningEfforts.isEmpty)
}


@Test
func modelCatalogFallbacksTrackBundledCodexDefaults() {
    let openAI = CodexModelCatalog.fallbackModels(for: .openAI)
    let openAIAPI = CodexModelCatalog.fallbackModels(for: .custom(
        id: "openai-api",
        name: "OpenAI API",
        baseURL: URL(string: "https://api.openai.com/v1")!,
        authMode: .apiKey
    ))
    let local = CodexModelCatalog.fallbackModels(for: .ollama())

    #expect(openAI.first?.id == "gpt-5.5")
    #expect(openAIAPI.first?.id == "gpt-5.5")
    #expect(openAI.map(\.id).contains("gpt-5.3-codex"))
    #expect(openAI.first?.supportedReasoningEfforts.map(\.reasoningEffort) == ["low", "medium", "high", "xhigh"])
    #expect(openAI.first?.supportsReasoningSummaries == true)
    #expect(openAI.first?.defaultReasoningSummary == CodexReasoningSummary.none)
    #expect(openAI.first?.supportsVerbosity == true)
    #expect(openAI.first?.defaultVerbosity == .low)
    #expect(local.first?.id == "local-model")
    #expect(local.first?.supportedReasoningEfforts.isEmpty == true)
}


@Test
func authTokensResolveChatGPTAccountIDFromIDToken() throws {
    let idToken = try jwt(payload: [
        "https://api.openai.com/auth": [
            "chatgpt_account_id": "account-123",
            "chatgpt_plan_type": "plus",
            "chatgpt_user_id": "user-123",
            "chatgpt_account_is_fedramp": false,
        ],
        "email": "dev@example.com",
    ])
    let tokens = CodexAuthTokens(idToken: idToken, accessToken: "access", refreshToken: "refresh")

    #expect(tokens.resolvedChatGPTAccountID == "account-123")
    #expect(tokens.resolvedAccountMetadata.planType == "plus")
    #expect(tokens.resolvedAccountMetadata.userID == "user-123")
    #expect(tokens.resolvedAccountMetadata.email == "dev@example.com")
}

# CodexKit

`CodexKit` is a Swift package for embedding the Codex agent harness in an
iOS 26 or macOS 26 app. It gives an app a Swift-native session API while keeping
Codex request JSON, event normalization, auth helpers, provider defaults, and
the iOS-safe tool engine in Rust.

The current package is an integration foundation, not a complete Codex iPhone
product. Apps still own their UI, app lifecycle, network policy, workspace
selection, and any custom tools they want to expose.

## Package Layout

- `Package.swift`: SwiftPM product `CodexKit`.
- `Sources/CodexKit`: public Swift API for sessions, providers, auth, workspaces,
  and tools.
- `Sources/CodexMobileCoreBridge`: Swift wrapper over the Rust C ABI. It also has
  source fallbacks so package tests can run before the binary artifact is built.
- `Artifacts/CodexMobileCore.xcframework`: generated Rust static library package.
  This artifact is ignored by git and rebuilt locally.
- `scripts/build-mobile-xcframework.sh`: builds Rust slices for iOS device,
  iOS simulator, and macOS, then packages the XCFramework.
- `Examples/CodexMobileDemo`: narrow iPhone demo app that signs in, selects a
  provider/model/workspace, streams chat, displays tool results, and registers
  one custom Swift tool.

## Build The Rust Artifact

Build the XCFramework before embedding `CodexKit` in an app target:

```sh
cd codex-swift
./scripts/build-mobile-xcframework.sh
```

The Swift package automatically consumes
`Artifacts/CodexMobileCore.xcframework` when it exists. Without it, SwiftPM can
still compile the package against limited source fallbacks, but the app will not
have the Rust-backed iOS shell emulator.

## Add CodexKit To An App

For development inside this repo, add the package by local path:

```swift
.package(path: "../../codex-swift")
```

Then link the `CodexKit` product from the app target.

App code imports only `CodexKit`:

```swift
import CodexKit
```

The app does not call the Rust C ABI directly. `CodexMobileCoreBridge` is an
implementation detail used by `CodexKit`.

## Create A Provider

`CodexProvider` describes the Responses-compatible backend and whether ChatGPT
auth is required.

```swift
let chatGPT = CodexProvider.openAI
let lmStudio = CodexProvider.lmStudio(
    baseURL: URL(string: "http://127.0.0.1:1234/v1")!
)
let custom = CodexProvider.custom(
    id: "my-server",
    name: "My Server",
    baseURL: URL(string: "https://example.com/v1")!,
    headers: ["x-client": "MyApp"]
)
```

`CodexProvider.openAI` targets the ChatGPT Codex backend and requires ChatGPT
sign-in. OpenAI-compatible local providers such as LM Studio should expose a
Responses-compatible `/responses` route under their base URL.

For a provider that uses a bearer API key instead of ChatGPT auth, opt into API
key mode and pass a `CodexAPIKeyStore` to the session configuration:

```swift
let provider = CodexProvider.custom(
    id: "responses-proxy",
    name: "Responses Proxy",
    baseURL: URL(string: "https://example.com/v1")!,
    authMode: .apiKey
)

let apiKeyStore = CodexKeychainAPIKeyStore(service: "MyApp Codex API Key")
try apiKeyStore.saveAPIKey("sk-...")
```

`CodexKit` injects `Authorization: Bearer ...` from the key store and never
writes API keys into process environment.

For a physical iPhone talking to a Mac-hosted LM Studio server, use the Mac's LAN
URL instead of `127.0.0.1`, and configure local-network permission plus any
development ATS exceptions in the app target.

## List Provider Models

Use `CodexModelCatalog` when the app needs a provider-aware model picker instead
of a hard-coded model list:

```swift
let catalog = CodexModelCatalog(
    provider: provider,
    authStore: authStore,
    apiKeyStore: apiKeyStore
)

let models = try await catalog.listModels()
let defaultModel = models.first(where: \.isDefault)?.model
```

For `CodexProvider.openAI`, the catalog calls the ChatGPT Codex `/models`
endpoint and applies the same ChatGPT auth headers as `CodexSession`. For API-key
providers it sends the configured bearer key. Local OpenAI-compatible providers
use their `/models` route without auth unless the provider says otherwise.

`CodexModelOption` carries the model id, display name, description, default
reasoning effort, supported reasoning efforts, input modalities, and hidden or
default flags. Send a per-turn `reasoningEffort` only when the selected model's
`supportedReasoningEfforts` includes that value; local providers commonly return
no reasoning metadata.

If a provider is offline or does not expose a compatible model endpoint, apps can
fall back to `CodexModelCatalog.fallbackModels(for:)` and still let the user type
a custom model id.

## Sign In With ChatGPT

ChatGPT login can use device code auth or browser PKCE auth. Both flows return
`CodexAuthTokens`, including account metadata derived through the Rust mobile
core token-claim parser.

Device code auth is useful when you want to own every screen:

```swift
let authStore = CodexKeychainAuthStore(
    service: "MyApp Codex",
    account: "default"
)

let authenticator = CodexDeviceCodeAuthenticator()
let code = try await authenticator.requestDeviceCode()

// Show these in your UI.
print(code.verificationURL.absoluteString)
print(code.userCode)

let tokens = try await authenticator.pollForTokens(deviceCode: code)
try authStore.saveTokens(tokens)
```

Browser PKCE auth uses `ASWebAuthenticationSession` and a loopback callback:

```swift
let browserAuth = CodexBrowserAuthenticator()
let tokens = try await browserAuth.authenticate()
try authStore.saveTokens(tokens)
```

`CodexSession` loads tokens from the configured `CodexAuthStore` whenever the
selected provider requires ChatGPT auth. If the access token is expired or close
to expiring, it refreshes tokens through `CodexDeviceCodeAuthenticator`, saves
the refreshed bundle, then sends both the bearer token and the resolved
`ChatGPT-Account-ID` header when available.

Use `tokens.resolvedAccountMetadata` when your app needs the account id, user id,
email, plan type, or FedRAMP account flag for account pickers or diagnostics.

Apps can implement their own `CodexAuthStore` if they need a different secure
storage policy.

## Device-Key Payloads

Upstream Codex exposes controller-local device-key protocol shapes for remote
control enrollment and connection proofs. `CodexKit` keeps key storage and
signing in Swift so apps can use Security framework, Keychain, Secure Enclave,
or their own platform policy, but it asks Rust mobile-core for the canonical
bytes to sign:

```swift
let payload = CodexDeviceKeySignPayload.remoteControlClientConnection(.init(
    nonce: challenge.nonce,
    sessionID: challenge.sessionID,
    targetOrigin: "https://chatgpt.com",
    targetPath: "/api/codex/remote/control/client",
    accountUserID: account.userID,
    clientID: clientID,
    tokenExpiresAt: challenge.tokenExpiresAt,
    tokenSHA256Base64URL: challenge.tokenSHA256Base64URL
))

let bytesToSign = try payload.signingPayloadBytes()
```

The resulting `Data` is the exact UTF-8 JSON payload covered by the device-key
signature. Do not reserialize the payload before signing.

## Configure A Workspace

The workspace is the root folder that tools can inspect or edit. For an app-owned
folder, create a workspace inside the app container:

```swift
let workspace = try CodexWorkspace.appContainer(named: "CodexWorkspace")
```

For a folder selected from Files or an open panel, wrap the selected URL:

```swift
let workspace = try CodexWorkspace.securityScopedFolder(url: selectedURL)
```

Persist recent workspaces with `CodexWorkspaceStore`:

```swift
let workspaceStore = CodexWorkspaceStore()
let record = try workspaceStore.save(workspace, displayName: "Project")
let restored = try workspaceStore.resolve(record)
```

The store records bookmark data, root path, read-only mode, display name, and
last-used time. Apps still decide how to present or prune recents.

When tools run, `CodexKit` calls `withSecurityScope` around workspace access:

```swift
try workspace.withSecurityScope { rootURL in
    // Read or write inside rootURL.
}
```

On iOS, shell execution prefers the pinned `JustBash` package through a
Codex-owned disk filesystem adapter rooted at the active workspace. That keeps
CodexKit responsible for workspace mapping, output limits, timeout reporting,
and jail enforcement while gaining a much broader in-process bash surface. The
Rust mobile core remains the fallback shell emulator when `JustBash` is not
available.

## Load Project Instructions

Use `CodexProjectInstructions` to mirror Codex's AGENTS.md project-doc behavior.
The loader scans from the workspace root to the current directory, prefers
`AGENTS.override.md` over `AGENTS.md` in each directory, and caps loaded bytes:

```swift
let instructions = try CodexProjectInstructions.load(
    from: workspace.rootURL,
    currentDirectoryURL: currentFileURL.deletingLastPathComponent()
)
```

Pass the result as contextual user instructions so project docs are model-visible
for the request without becoming part of persisted conversation history:

```swift
let configuration = CodexSessionConfiguration(
    provider: provider,
    workspace: workspace,
    contextualUserInstructions: instructions?.text
)
```

## Start A Session

`CodexSession` is the main harness object. It keeps conversation history,
streams Responses events, executes tool calls, appends tool outputs, and
continues the tool loop until the model finishes.

```swift
let session = CodexSession(configuration: CodexSessionConfiguration(
    provider: .openAI,
    authStore: authStore,
    workspace: workspace,
    baseInstructionsOverride: """
    You are Codex, a pragmatic coding agent running inside MyApp.
    Inspect files with tools before answering workspace questions.
    """,
    additionalDeveloperInstructions: "Keep answers concise.",
    contextualUserInstructions: instructions?.text,
    tools: [BuildNumberTool()],
    webSearch: CodexWebSearchOptions(mode: .cached, searchContextSize: .medium),
    compactionOptions: .automatic(triggerApproxTokens: 200_000)
))
```

Use a new session when provider, model, auth context, workspace, or registered
tools change. Call `clearHistory()` if the user wants a fresh conversation with
the same configuration.

The default model is `gpt-5.5`. Override it in `CodexSessionConfiguration` for a
long-lived session default or per turn with `CodexTurnOptions`.

Enable background child agents with `subagentOptions`:

```swift
let configuration = CodexSessionConfiguration(
    provider: provider,
    model: model,
    workspace: workspace,
    subagentOptions: .enabled
)
```

When enabled, `CodexKit` exposes `spawn_agent`, `send_message`,
`followup_task`, `wait_agent`, `list_agents`, and `close_agent`. Spawned agents
inherit the same configuration, workspace, registered tools, approval handler,
and auth context. `fork_turns` can be `none`, `all`, or a positive integer
string to control how much parent history is copied into the child session.

## Thread Goals

CodexKit includes Codex-compatible goal tools for host apps that want long-running
objective tracking across turns. The app owns the current goal state by
implementing `CodexGoalStore`, then registers the tool set on the session:

```swift
let goalStore: any CodexGoalStore = MyGoalStore(threadID: conversationID)

let configuration = CodexSessionConfiguration(
    provider: provider,
    model: model,
    workspace: workspace
)
.withAdditionalTools(CodexGoalTool.all(store: goalStore))
```

This exposes `get_goal`, `create_goal`, and `update_goal`. `create_goal` requires
an explicit user request to start a concrete goal and can carry an optional
positive token budget. `update_goal` only accepts `complete` or `blocked`; hosts
should keep turn usage accounting in their store and only mark budget or usage
limits from app-owned policy.

## Approve Mutating Tools

`CodexKit` asks the host app for approval before running built-in tools that can
change the workspace or execute commands: `apply_patch`, `write_file`,
`shell_command`, and `exec_command`. If no approval handler is configured, those
tools return a failed tool result instead of running.

```swift
let session = CodexSession(configuration: CodexSessionConfiguration(
    provider: provider,
    model: model,
    authStore: authStore,
    workspace: workspace,
    toolApprovalHandler: { request in
        let message = [
            request.justification ?? request.reason,
            request.workdir.map { "Working directory: \($0)" },
            request.suggestedPrefixRule.isEmpty ? nil : "Session prefix: \(request.suggestedPrefixRule.joined(separator: " "))",
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
        let approved = await showApprovalPrompt(
            title: request.summary,
            message: message
        )
        return approved ? .approve : .deny("Denied by user.")
    }
))
```

For shell tools, approval requests also expose `command`, `workdir`,
`sandboxPermissions`, `justification`, and any model-suggested `prefix_rule` as
`suggestedPrefixRule`.
Hosts that offer an "approve for session" action can return
`.approveForSession(prefixRule:)`; `CodexSession` then skips later shell approval
prompts only when the parsed command starts with that exact prefix.

Custom Swift tools can opt into the same flow by overriding
`approvalRequirement(for:)`:

```swift
func approvalRequirement(for call: CodexToolCall) -> CodexToolApprovalRequirement {
    .required(reason: "Publish changes to the project repository.")
}
```

A denial is sent back to the model as a normal unsuccessful tool result, so the
turn can continue with an explanation or a safer alternative.

## Persist A Session

Apps that own their own chat history can snapshot the session's canonical
Responses history and restore it later:

```swift
let snapshot = try await session.snapshot()
let restored = CodexSession(configuration: configuration, snapshot: snapshot)
```

`CodexSessionSnapshot` is `Codable`, so apps can store it alongside their own
conversation metadata and rendered transcript. A restored session continues
with the same prior user, assistant, tool-call, and tool-output items. Apps
still own resumability policy for in-flight turns; do not assume an interrupted
stream can be reconnected after app relaunch.

Long-running conversations can compact their canonical Responses history before
the next turn:

```swift
let result = try await session.compactHistory(options: CodexTurnOptions(
    model: "gpt-5.5",
    reasoningEffort: "low"
))
let snapshot = try await session.snapshot()
```

Compaction sends the existing history plus Codex's checkpoint prompt through the
selected model with tools disabled, then replaces session history with bounded
recent user prompts and the generated handoff summary. Persist the new snapshot
after a successful compaction. `CodexCompactionResult` reports the summary and
the before/after history item counts for host UI.

Apps can also opt into pre-turn automatic compaction with
`CodexCompactionOptions.automatic(triggerApproxTokens:)`. When the approximate
serialized history token count crosses the threshold, `CodexSession` compacts
history before appending the next user message, then emits
`.contextCompacted(CodexCompactionResult)` on that turn's stream. Hosts should
persist the session snapshot after this event the same way they do after tool
results or manual compaction.

## Stream A Turn

`submit(userText:)` returns an `AsyncThrowingStream<CodexStreamEvent, Error>`.
Use `submit(userText:options:)` for per-turn model or reasoning overrides, and
`submit(inputs:options:)` for multipart input:

```swift
let options = CodexTurnOptions(
    model: "gpt-5.5",
    reasoningEffort: "low",
    serviceTier: "flex",
    toolChoice: "auto",
    parallelToolCalls: true,
    inputModalities: ["text", "image"],
    webSearch: CodexWebSearchOptions(mode: .disabled)
)

let stream = await session.submit(
    inputs: [
        .text("Explain this screenshot."),
        .imageData(pngData, mimeType: "image/png"),
    ],
    options: options
)
```

Update your UI as events arrive:

```swift
for try await event in stream {
    switch event {
    case .outputTextDelta(_, let delta):
        assistantMessage += delta

    case .reasoningSummaryDelta(_, let delta):
        reasoningSummary += delta

    case .toolCallInputDelta(_, _, let delta):
        updateToolArgumentsPreview(delta)

    case .toolCall(let call):
        showToolStarted(name: call.name, arguments: call.arguments)

    case .toolResult(let call, let output, let success):
        showToolFinished(name: call.name, output: output, success: success)

    case .webSearch(let call):
        showWebSearch(status: call.status, detail: call.detail)

    case .contextCompacted(let result):
        showCompaction(summary: result.summary)

    case .planUpdated(let plan):
        showPlan(plan)

    case .completed(_, let tokenUsage):
        if let tokenUsage {
            showTokenUsage(
                input: tokenUsage.inputTokens,
                cachedInput: tokenUsage.cachedInputTokens,
                output: tokenUsage.outputTokens,
                reasoningOutput: tokenUsage.reasoningOutputTokens,
                total: tokenUsage.totalTokens
            )
        }
        finishAssistantMessage()

    case .error(let message):
        showError(message)

    default:
        break
    }
}
```

Cancellation is normal Swift task cancellation. Cancel the task that is consuming
the stream when the user stops a turn or leaves the screen.

## Built-In Tools

`CodexKit` exposes a Codex-compatible default tool surface:

- Hosted `web_search`: pass `CodexWebSearchOptions` in
  `CodexSessionConfiguration` to add the Responses hosted web-search tool for
  OpenAI-backed turns. Use `.cached` for cached search or `.live` to allow live
  external web access. `CodexTurnOptions.webSearch` can override the session
  default for one turn, including `.disabled` for review-only workflows.
- `list_dir`: lists entries inside the selected workspace.
- `read_file`: reads UTF-8 text files inside the selected workspace without
  going through shell.
- `search_files`: searches UTF-8 text files inside the selected workspace
  without going through shell.
- `apply_patch`: applies Codex patches inside the selected workspace. macOS uses
  a native Swift applier with workspace jail checks; iOS uses Rust mobile-core
  when the artifact is available.
- `write_file`: writes a complete UTF-8 text file inside the selected workspace.
  Prefer `apply_patch` for focused edits.
- `view_image`: reads a workspace image file, optionally resizes it for high
  detail, and returns an `input_image` tool-output content item so the next model
  request can visually inspect the image. Pass selected model input modalities in
  `CodexTurnOptions.inputModalities`; `CodexKit` hides `view_image` when the
  current model is known to be text-only.
- `update_plan`: lets the model publish the current turn checklist. `CodexKit`
  validates the submitted steps, emits `.planUpdated`, and returns a tool result
  without changing the workspace.
- `shell_command`: runs a shell-like command. On macOS this runs `/bin/zsh -lc`
  inside the selected workspace. On iOS this uses the deterministic Rust shell
  emulator, not arbitrary process execution.
- `exec_command`: accepts Codex unified exec-style arguments. On macOS it uses
  the same native shell runner; on iOS it uses the deterministic emulator.

Session instructions steer the model toward `list_dir`, `read_file`,
`search_files`, `apply_patch`, and `write_file` first. Shell tools remain
available for commands that genuinely require a shell, such as builds, tests,
package managers, or explicit user-requested commands.

The iOS shell emulator is intended for coding workflows, not POSIX shell parity.
It supports common read and edit commands such as `pwd`, `ls`, `find`, `cat`,
`head`, `tail`, `wc`, `grep`, `rg`, `sort`, `uniq`, common `sed` forms,
`printf`, `mkdir`, `touch`, `cp`, `mv`, and `rm`, with workspace jail checks. It
also answers command lookup probes such as `command -v`, `command -V`, `which`,
and `type` for the supported emulator commands.

Unsupported iOS shell features fail with normal command-style stderr and exit
status. Examples include arbitrary binaries, interpreters, package managers,
network commands, background jobs, command substitution, subshells, PTYs, and
long-running interactive sessions. Command input is capped at 32 KiB, and long
outputs are truncated on UTF-8 character boundaries.

## Add A Custom Swift Tool

Implement `CodexTool` for in-process app tools. The input schema is passed to the
model as a JSON schema object.

```swift
struct BuildNumberTool: CodexTool {
    let name = "build_number"
    let description = "Returns the current app build number."
    let inputSchema: [String: any Sendable] = [
        "type": "object",
        "properties": [:],
        "additionalProperties": false,
    ]

    func execute(
        call: CodexToolCall,
        context: CodexToolContext
    ) async throws -> CodexToolResult {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return CodexToolResult(output: build)
    }
}
```

For a typed schema builder, use `CodexJSONSchema` and hand its `inputSchema`
dictionary to `CodexTool`:

```swift
let inputSchema = CodexJSONSchema.object(
    properties: [
        "path": .string(description: "Workspace-relative path"),
        "recursive": .boolean(),
    ],
    required: ["path"]
).inputSchema
```

Register custom tools in `CodexSessionConfiguration.tools`. Tool implementations
receive a `CodexToolContext` containing the active workspace, if one was
configured.

`CodexToolCall.kind` preserves whether the backend sent a function tool call or
custom tool call. `CodexKit` uses that kind when appending tool output so the
next Responses request uses the correct `function_call_output` or
`custom_tool_call_output` item shape.

Return `CodexToolResult(output: ..., success: false)` when a tool fails in a way
the model can recover from. Throw an error for unexpected app/runtime failures.

## Error Handling

`CodexSessionError` covers the expected session-level failures:

- `missingAuthentication`: the selected provider requires ChatGPT auth and no
  tokens are available.
- `httpStatus(Int, String)`: the backend returned a non-2xx response; the string
  contains the first part of the response body.
- `unknownTool(String)`: the model requested a tool that is not registered.
- `workspacePathError(String)`: a requested path is missing, invalid, or outside
  the workspace.
- `compactionUnavailable(String)`: history compaction could not start or the
  compaction stream ended without a usable summary.
- `toolLoopLimitExceeded`: the model kept requesting tools beyond the session
  loop limit.

Apps should display these separately from ordinary assistant text.

## Demo App

The demo app is intentionally small and useful as integration sample code:

```sh
cd codex-swift/Examples/CodexMobileDemo
xcodebuild \
  -project CodexMobileDemo.xcodeproj \
  -scheme CodexMobileDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' \
  build
```

It demonstrates:

- device-code sign-in
- provider and model selection
- app-container workspace setup
- folder picking
- streaming chat UI
- built-in tool transcript
- custom Swift tool registration

## Current Limits

- The Swift package expects iOS 26 and macOS 26.
- `CodexKit` does not include a full app product, background agent, or TUI.
- The iOS shell backend is an emulator. It does not run arbitrary binaries.
- The macOS shell backend runs `/bin/zsh -lc` with the working directory kept
  inside the selected workspace.
- MCP subprocess servers, App Server, and desktop sandboxing are out of scope for
  this mobile package.

## Credits

`CodexKit` was informed by [Litter](https://github.com/dnakov/litter), especially
its native iOS Codex work by dnakov. This fork adapts several of Litter's public
Codex iOS portability patches while keeping the reusable behavior in Rust layers
that Swift can embed.

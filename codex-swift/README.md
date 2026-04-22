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

The Rust mobile core remains responsible for path normalization, symlink checks,
and workspace jail enforcement for Rust-backed shell operations.

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
    tools: [BuildNumberTool()]
))
```

Use a new session when provider, model, auth context, workspace, or registered
tools change. Call `clearHistory()` if the user wants a fresh conversation with
the same configuration.

The default model is `gpt-5.4`. Override it in `CodexSessionConfiguration` for a
long-lived session default or per turn with `CodexTurnOptions`.

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

## Stream A Turn

`submit(userText:)` returns an `AsyncThrowingStream<CodexStreamEvent, Error>`.
Use `submit(userText:options:)` for per-turn model or reasoning overrides, and
`submit(inputs:options:)` for multipart input:

```swift
let options = CodexTurnOptions(
    model: "gpt-5.4",
    reasoningEffort: "low",
    serviceTier: "flex",
    toolChoice: "auto",
    parallelToolCalls: true
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
    case .outputTextDelta(let delta):
        assistantMessage += delta

    case .reasoningSummaryDelta(let delta):
        reasoningSummary += delta

    case .toolCallInputDelta(_, _, let delta):
        updateToolArgumentsPreview(delta)

    case .toolCall(let call):
        showToolStarted(name: call.name, arguments: call.arguments)

    case .toolResult(let call, let output, let success):
        showToolFinished(name: call.name, output: output, success: success)

    case .completed:
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

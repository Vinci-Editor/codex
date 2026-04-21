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

`CodexProvider.openAI` targets the ChatGPT Codex backend and requires device-code
sign-in. OpenAI-compatible local providers such as LM Studio should expose a
Responses-compatible `/responses` route under their base URL.

For a physical iPhone talking to a Mac-hosted LM Studio server, use the Mac's LAN
URL instead of `127.0.0.1`, and configure local-network permission plus any
development ATS exceptions in the app target.

## Sign In With ChatGPT

ChatGPT login currently uses device code auth. The app should request a code,
show the verification URL and user code, poll for tokens, then store them in
Keychain.

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

`CodexSession` loads tokens from the configured `CodexAuthStore` whenever the
selected provider requires ChatGPT auth. It sends both the bearer token and the
resolved `ChatGPT-Account-ID` header when available.

Apps can implement their own `CodexAuthStore` if they need a different secure
storage policy.

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
    model: "gpt-5.4",
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

## Stream A Turn

`submit(userText:)` returns an `AsyncThrowingStream<CodexStreamEvent, Error>`.
Update your UI as events arrive:

```swift
for try await event in await session.submit(userText: prompt) {
    switch event {
    case .outputTextDelta(let delta):
        assistantMessage += delta

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
- `shell_command`: runs a shell-like command. On iOS this uses the deterministic
  Rust shell emulator, not arbitrary process execution.
- `exec_command`: accepts Codex unified exec-style arguments and uses the same
  iOS emulator.
- `apply_patch`: applies Codex patches in-process through Rust, with the same
  workspace jail checks as the iOS shell emulator.

The iOS shell emulator is intended for coding workflows, not POSIX shell parity.
It supports common read and edit commands such as `pwd`, `ls`, `find`, `cat`,
`head`, `tail`, `wc`, `grep`, `rg`, `sort`, `uniq`, common `sed` forms,
`printf`, `mkdir`, `touch`, `cp`, `mv`, and `rm`, with workspace jail checks.

Unsupported iOS shell features fail with normal command-style stderr and exit
status. Examples include arbitrary binaries, interpreters, package managers,
network commands, background jobs, command substitution, subshells, PTYs, and
long-running interactive sessions.

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

Register custom tools in `CodexSessionConfiguration.tools`. Tool implementations
receive a `CodexToolContext` containing the active workspace, if one was
configured.

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
- The macOS real-shell backend is not wired in this package yet.
- MCP subprocess servers, App Server, and desktop sandboxing are out of scope for
  this mobile package.

## Credits

`CodexKit` was informed by [Litter](https://github.com/dnakov/litter), especially
its native iOS Codex work by dnakov. This fork adapts several of Litter's public
Codex iOS portability patches while keeping the reusable behavior in Rust layers
that Swift can embed.

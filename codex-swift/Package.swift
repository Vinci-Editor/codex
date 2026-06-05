// swift-tools-version: 6.2

import Foundation
import PackageDescription

let artifactPath = "Artifacts/CodexMobileCore.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasMobileCoreArtifact = FileManager.default.fileExists(
    atPath: packageDirectory.appending(path: artifactPath).path
)

let mobileCoreBridgeDependencies: [Target.Dependency] = (hasMobileCoreArtifact ? [.target(name: "CodexMobileCore")] : [])
    + [.product(name: "JustBash", package: "just-bash-swift")]

var targets: [Target] = [
    .target(
        name: "CodexMobileCoreBridge",
        dependencies: mobileCoreBridgeDependencies,
        path: "Sources/CodexMobileCoreBridge",
        linkerSettings: [
            .linkedFramework("SystemConfiguration", .when(platforms: [.iOS, .macOS])),
            .linkedLibrary("z", .when(platforms: [.iOS, .macOS])),
        ]
    ),
    .target(
        name: "CodexKit",
        dependencies: ["CodexMobileCoreBridge"],
        path: "Sources/CodexKit"
    ),
    .testTarget(
        name: "CodexKitTests",
        dependencies: ["CodexKit"],
        path: "Tests/CodexKitTests"
    ),
]

if hasMobileCoreArtifact {
    targets.append(.binaryTarget(name: "CodexMobileCore", path: artifactPath))
}

let package = Package(
    name: "codex-swift",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "CodexKit", targets: ["CodexKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mweinbach/just-bash-swift.git", revision: "a750ab6df2582a1fd4044b8877a76b61800d9544"),
    ],
    targets: targets
)

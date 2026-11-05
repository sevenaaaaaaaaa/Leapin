// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchFlow",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TouchFlowCore", targets: ["TouchFlowCore"]),
        .library(name: "TouchFlowPolicy", targets: ["TouchFlowPolicy"]),
        .library(name: "TouchFlowNet", targets: ["TouchFlowNet"]),
        .library(name: "TouchFlowIntegrations", targets: ["TouchFlowIntegrations"]),
        .library(name: "TouchFlowRuntime", targets: ["TouchFlowRuntime"]),
        .library(name: "TouchFlowControl", targets: ["TouchFlowControl"]),
        .executable(name: "tfctl", targets: ["tfctl"]),
        .executable(name: "TouchFlowApp", targets: ["TouchFlowApp"]),
    ],
    targets: [
        // libproc shim: which process owns a given TCP connection. Only macOS links it,
        // so it is kept out of the Swift targets that also build for other platforms.
        .target(name: "CTouchFlowProc"),
        .target(name: "TouchFlowCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "TouchFlowPolicy", dependencies: ["TouchFlowCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "TouchFlowNet", dependencies: ["TouchFlowCore", "CTouchFlowProc"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "TouchFlowIntegrations", dependencies: ["TouchFlowCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "TouchFlowControl", dependencies: ["TouchFlowCore", "TouchFlowNet"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "TouchFlowRuntime", dependencies: ["TouchFlowCore", "TouchFlowPolicy", "TouchFlowNet", "TouchFlowIntegrations", "TouchFlowControl"], resources: [.copy("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "tfctl", dependencies: ["TouchFlowRuntime", "TouchFlowControl"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "TouchFlowApp", dependencies: ["TouchFlowRuntime", "TouchFlowPolicy", "TouchFlowNet", "TouchFlowIntegrations"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TouchFlowCoreTests", dependencies: ["TouchFlowCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TouchFlowPolicyTests", dependencies: ["TouchFlowPolicy"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TouchFlowNetTests", dependencies: ["TouchFlowNet"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TouchFlowIntegrationsTests", dependencies: ["TouchFlowIntegrations"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TouchFlowControlTests", dependencies: ["TouchFlowControl", "TouchFlowCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

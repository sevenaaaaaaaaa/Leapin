// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Leapin",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LeapinCore", targets: ["LeapinCore"]),
        .library(name: "LeapinPolicy", targets: ["LeapinPolicy"]),
        .library(name: "LeapinNet", targets: ["LeapinNet"]),
        .library(name: "LeapinIntegrations", targets: ["LeapinIntegrations"]),
        .library(name: "LeapinRuntime", targets: ["LeapinRuntime"]),
        .library(name: "LeapinControl", targets: ["LeapinControl"]),
        .library(name: "LeapinSync", targets: ["LeapinSync"]),
        .executable(name: "leapin", targets: ["leapin"]),
        .executable(name: "LeapinApp", targets: ["LeapinApp"]),
    ],
    targets: [
        // libproc shim: which process owns a given TCP connection. Only macOS links it,
        // so it is kept out of the Swift targets that also build for other platforms.
        .target(name: "CLeapinProc"),
        .target(name: "LeapinCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "LeapinPolicy", dependencies: ["LeapinCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "LeapinNet", dependencies: ["LeapinCore", "CLeapinProc"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "LeapinIntegrations", dependencies: ["LeapinCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "LeapinControl", dependencies: ["LeapinCore", "LeapinNet"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "LeapinSync", dependencies: ["LeapinCore", "LeapinPolicy", "LeapinNet"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "LeapinRuntime", dependencies: ["LeapinCore", "LeapinPolicy", "LeapinNet", "LeapinIntegrations", "LeapinControl", "LeapinSync"], resources: [.copy("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "leapin", dependencies: ["LeapinRuntime", "LeapinControl"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "LeapinApp", dependencies: ["LeapinRuntime", "LeapinPolicy", "LeapinNet", "LeapinIntegrations"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LeapinCoreTests", dependencies: ["LeapinCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LeapinPolicyTests", dependencies: ["LeapinPolicy"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LeapinNetTests", dependencies: ["LeapinNet"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LeapinIntegrationsTests", dependencies: ["LeapinIntegrations"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LeapinControlTests", dependencies: ["LeapinControl", "LeapinCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LeapinSyncTests", dependencies: ["LeapinSync", "LeapinCore", "LeapinPolicy", "LeapinNet"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LeapinRuntimeTests", dependencies: ["LeapinRuntime", "LeapinCore", "LeapinSync"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
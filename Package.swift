// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeCompanion",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCompanion",
            path: "Sources/ClaudeCompanion",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeCompanionTests",
            dependencies: ["ClaudeCompanion"],
            path: "Tests/ClaudeCompanionTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

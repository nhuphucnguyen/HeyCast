// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HeyCast",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HeyCast",
            path: "Sources/HeyCast",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftCast",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SwiftCast",
            path: "Sources/SwiftCast",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

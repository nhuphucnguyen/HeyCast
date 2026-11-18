// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HeyCast",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1")
    ],
    targets: [
        // Notes storage, shared by the app and the planned MCP server.
        .target(
            name: "NotesCore",
            path: "Sources/NotesCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "HeyCast",
            dependencies: [
                "NotesCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
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

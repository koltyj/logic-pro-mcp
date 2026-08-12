// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LogicProMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LogicProMCP", targets: ["LogicProMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .executableTarget(
            name: "LogicProMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/LogicProMCP",
            linkerSettings: [
                .linkedFramework("CoreMIDI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "LogicProMCPTests",
            dependencies: ["LogicProMCP"],
            path: "Tests/LogicProMCPTests"
        ),
    ]
)

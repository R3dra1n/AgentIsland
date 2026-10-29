// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentIsland", targets: ["AgentIsland"]),
        .executable(name: "AgentIslandHook", targets: ["AgentIslandHook"])
    ],
    targets: [
        .executableTarget(
            name: "AgentIsland",
            path: "Sources/AgentIsland",
            resources: [.process("../../Resources")]
        ),
        .executableTarget(name: "AgentIslandHook", path: "Sources/AgentIslandHook"),
        .testTarget(name: "AgentIslandTests", dependencies: ["AgentIsland"], path: "Tests/AgentIslandTests")
    ]
)

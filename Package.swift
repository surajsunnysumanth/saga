// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Saga",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SagaCore", targets: ["SagaCore"]),
        .executable(name: "saga", targets: ["saga"]),
        .executable(name: "SagaApp", targets: ["SagaApp"]),
        .executable(name: "saga-mcp", targets: ["saga-mcp"]),
    ],
    targets: [
        .target(name: "SagaCore"),
        .executableTarget(name: "saga", dependencies: ["SagaCore"]),
        .executableTarget(name: "SagaApp", dependencies: ["SagaCore"]),
        .executableTarget(name: "saga-mcp", dependencies: ["SagaCore"]),
        .testTarget(name: "SagaCoreTests", dependencies: ["SagaCore"]),
    ]
)

// swift-tools-version: 6.2
import PackageDescription

// Swift Testing macros ship with the Command Line Tools but are not on the default plugin path.
let testingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

let package = Package(
    name: "Bee",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "BeeCore",
            path: "Sources/BeeCore",
            // libbsm reads the audit token of the process at the other end of the agents' socket.
            linkerSettings: [.linkedLibrary("bsm")]
        ),
        .executableTarget(
            name: "Bee",
            dependencies: ["BeeCore"],
            path: "Sources/Bee",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // The relay an agent's program starts: MCP on its standard streams, Bee's private socket behind.
        .executableTarget(
            name: "bee-mcp",
            dependencies: ["BeeCore"],
            path: "Sources/BeeMCP"
        ),
        .testTarget(
            name: "BeeCoreTests",
            dependencies: ["BeeCore"],
            path: "Tests/BeeCoreTests",
            swiftSettings: [.unsafeFlags(["-plugin-path", testingPluginPath])]
        ),
    ]
)

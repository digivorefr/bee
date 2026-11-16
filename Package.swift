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
            path: "Sources/BeeCore"
        ),
        .executableTarget(
            name: "Bee",
            dependencies: ["BeeCore"],
            path: "Sources/Bee",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "BeeCoreTests",
            dependencies: ["BeeCore"],
            path: "Tests/BeeCoreTests",
            swiftSettings: [.unsafeFlags(["-plugin-path", testingPluginPath])]
        ),
    ]
)

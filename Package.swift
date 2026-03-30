// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchAgents",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "NotchAgents",
            targets: ["NotchAgents"]
        ),
        .executable(
            name: "notchagentsctl",
            targets: ["notchagentsctl"]
        )
    ],
    targets: [
        .target(
            name: "NotchAgentsCore",
            path: "Sources/NotchAgentsCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "NotchAgents",
            dependencies: ["NotchAgentsCore"],
            path: "Sources/DevServerBar"
        ),
        .executableTarget(
            name: "notchagentsctl",
            dependencies: ["NotchAgentsCore"],
            path: "Sources/notchagentsctl"
        )
    ]
)

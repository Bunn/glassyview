// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "GlassyHost",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GlassyHost", targets: ["GlassyHost"])
    ],
    targets: [
        .executableTarget(
            name: "GlassyHost",
            path: "Sources/GlassyHost"
        ),
        .testTarget(
            name: "GlassyHostTests",
            dependencies: ["GlassyHost"],
            path: "Tests/GlassyHostTests"
        )
    ]
)

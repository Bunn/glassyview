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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "GlassyHost",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/GlassyHost",
            linkerSettings: [
                // The app-bundling script embeds Sparkle in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "GlassyHostTests",
            dependencies: ["GlassyHost"],
            path: "Tests/GlassyHostTests"
        )
    ]
)

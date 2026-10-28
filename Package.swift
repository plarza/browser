// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CoreKit", targets: ["CoreKit"]),
        .executable(name: "Core", targets: ["Core"]),
    ],
    targets: [
        // Every privacy rule lives here (or in the patched engine). Its API
        // has nothing that weakens one.
        .target(
            name: "CoreKit",
            path: "CoreKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The thin shell: a window, the tabs down the left, one field.
        .executableTarget(
            name: "Core",
            dependencies: ["CoreKit"],
            path: ".",
            exclude: ["CoreKit", "engine", "release", "build", "README.md", "SPEC.md", "VERSION", "build.sh", "Tests/engine.py"],
            sources: ["App", "Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

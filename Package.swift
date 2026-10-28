// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Azote",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AzoteKit", targets: ["AzoteKit"]),
        .executable(name: "Azote", targets: ["Azote"]),
    ],
    targets: [
        // Every privacy rule lives here (or in the patched engine). Its API
        // has nothing that weakens one.
        .target(
            name: "AzoteKit",
            path: "AzoteKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The thin shell: a window, the tabs down the left, one field.
        .executableTarget(
            name: "Azote",
            dependencies: ["AzoteKit"],
            path: ".",
            exclude: ["AzoteKit", "engine", "release", "build", "README.md", "SPEC.md", "VERSION", "build.sh", "Tests/engine.py"],
            sources: ["App", "Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

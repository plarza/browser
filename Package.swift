// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BrowserKit", targets: ["BrowserKit"]),
        .executable(name: "Browser", targets: ["Browser"]),
    ],
    targets: [
        // Every privacy rule lives here (or in the system WebKit configuration). Its API
        // has nothing that weakens one.
        .target(
            name: "BrowserKit",
            path: "BrowserKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The thin shell: a window, the tabs down the left, one field.
        .executableTarget(
            name: "Browser",
            dependencies: ["BrowserKit"],
            path: ".",
            exclude: ["BrowserKit", "iOS", "release", "build", "README.md", "SPEC.md", "LICENSE", "VERSION", "build.sh"],
            sources: ["App", "Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

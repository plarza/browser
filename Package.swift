// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "BrowserKit", targets: ["BrowserKit"]),
        .executable(name: "Browser", targets: ["Browser"]),
    ],
    targets: [
        // Every privacy rule lives here (or in the system WebKit configuration). Its API
        // has nothing that weakens one. The Mac and the iPhone app both stand on it.
        .target(name: "BrowserKit", path: "BrowserKit"),
        // The Mac's thin shell: a window, the tabs down the left, one field. Debug
        // builds carry the end-to-end self-test in Tests/.
        .executableTarget(
            name: "Browser",
            dependencies: ["BrowserKit"],
            path: ".",
            exclude: ["BrowserKit", "iOS", "release", "build", "README.md", "SPEC.md", "LICENSE", "VERSION", "build.sh"],
            sources: ["App", "Tests"]
        ),
    ]
)

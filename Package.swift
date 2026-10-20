// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dial",
    platforms: [.macOS("15.4")],
    targets: [
        .executableTarget(name: "Dial", path: "Sources/Dial")
    ]
)

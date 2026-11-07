// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iDeck",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "iDeck", path: "Sources/iDeck", exclude: ["Web"])
    ]
)

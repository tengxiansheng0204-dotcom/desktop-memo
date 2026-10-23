// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DesktopMemo",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DesktopMemo", targets: ["DesktopMemo"])],
    targets: [
        .executableTarget(name: "DesktopMemo"),
        .testTarget(name: "DesktopMemoTests", dependencies: ["DesktopMemo"])
    ]
)

// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FstnView",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FstnView", path: "Sources/FstnView")
    ]
)

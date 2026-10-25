// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CropAdvisor",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "CropAdvisor", path: "Sources/CropAdvisor")
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceOver",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VoiceOver", targets: ["VoiceOver"])],
    targets: [
        .executableTarget(name: "VoiceOver", linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("AppKit")]),
        .testTarget(name: "VoiceOverTests", dependencies: ["VoiceOver"])
    ],
    swiftLanguageModes: [.v5]
)

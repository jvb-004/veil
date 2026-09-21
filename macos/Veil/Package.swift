// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Veil",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Veil",
            path: "Sources/Veil",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)

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
                // A SwiftPM executable has no bundle, so the usage strings that
                // TCC shows the user have to be welded into the binary.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)

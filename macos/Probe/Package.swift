// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Probe",
            path: "Sources/Probe",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        )
    ]
)

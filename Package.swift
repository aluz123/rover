// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "Rover",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RoverCore", path: "Sources/RoverCore",
                swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
        .executableTarget(name: "Rover", dependencies: ["RoverCore"], path: "Sources/Rover"),
    ]
)

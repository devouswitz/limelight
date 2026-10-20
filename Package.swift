// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Limelight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Limelight", targets: ["Limelight"]),
        .executable(name: "limelight-cli", targets: ["limelight-cli"]),
    ],
    targets: [
        .target(name: "LimelightCore"),
        .executableTarget(
            name: "Limelight",
            dependencies: ["LimelightCore"],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]
        ),
        .executableTarget(name: "limelight-cli", dependencies: ["LimelightCore"]),
        .testTarget(name: "LimelightCoreTests", dependencies: ["LimelightCore"]),
    ]
)

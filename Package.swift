// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "sds-clean",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SDSCleanCore", targets: ["SDSCleanCore"]),
        .executable(name: "sds-clean", targets: ["sds-clean"]),
    ],
    targets: [
        .target(name: "SDSCleanCore"),
        .executableTarget(name: "sds-clean", dependencies: ["SDSCleanCore"]),
        .testTarget(name: "SDSCleanCoreTests", dependencies: ["SDSCleanCore"]),
    ]
)

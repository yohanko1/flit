// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Flit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Flit",
            path: "Sources/Flit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "FlitTests",
            dependencies: ["Flit"],
            path: "Tests/FlitTests"
        ),
    ]
)

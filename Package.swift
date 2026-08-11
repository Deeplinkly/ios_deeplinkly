// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Deeplinkly",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "Deeplinkly", targets: ["Deeplinkly"])
    ],
    targets: [
        .target(
            name: "Deeplinkly",
            path: "Sources/Deeplinkly",
            exclude: ["Resources/IDFA"],
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "DeeplinklyTests",
            dependencies: ["Deeplinkly"],
            path: "Tests/DeeplinklyTests"
        )
    ]
)

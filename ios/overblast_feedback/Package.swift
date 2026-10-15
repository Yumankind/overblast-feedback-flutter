// swift-tools-version: 5.9
// Swift Package Manager manifest for the iOS half of the plugin. The CocoaPods podspec beside it
// (../overblast_feedback.podspec) builds the same sources, for apps that have not moved to SwiftPM.

import PackageDescription

let package = Package(
    name: "overblast_feedback",
    platforms: [
        // Xcode 27 builds nothing below iOS 15.0. App Attest and MetricKit (iOS 14) are always there.
        .iOS("15.0")
    ],
    products: [
        .library(name: "overblast-feedback", targets: ["overblast_feedback"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "overblast_feedback",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            linkerSettings: [
                .linkedFramework("DeviceCheck"),
                .linkedFramework("Security"),
            ]
        )
    ]
)

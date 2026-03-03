// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path
let appInfoPlistPath = URL(fileURLWithPath: packageRoot)
    .appendingPathComponent("Sources/SpeechflowApp/Resources/Info.plist")
    .path

let package = Package(
    name: "Speechflow",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SpeechflowCore",
            targets: ["SpeechflowCore"]
        ),
        .executable(
            name: "SpeechflowApp",
            targets: ["SpeechflowApp"]
        )
    ],
    targets: [
        .target(
            name: "SpeechflowCore",
            path: "Sources/SpeechflowCore"
        ),
        .executableTarget(
            name: "SpeechflowApp",
            dependencies: ["SpeechflowCore"],
            path: "Sources/SpeechflowApp",
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", appInfoPlistPath
                    ],
                    .when(platforms: [.macOS])
                )
            ]
        )
    ]
)

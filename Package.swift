// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Absolute path to the package root, so the Info.plist linker flag below keeps
// working no matter which directory `swift build` is invoked from.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "ApplePhotoLibraryCompressor",
    // macOS 14, deliberately NOT the SDK's macOS 26. The APIs marked
    // API_AVAILABLE(macos(26.0)) — PHAsset.contentType, PHAsset.addedDate,
    // PHAssetResourceCreationOptions.contentType — do not exist at runtime on
    // macOS 15.x. Pinning the target here turns "crashes on the user's machine"
    // into "fails to compile on ours".
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "aplc", targets: ["aplc"]),
        .library(name: "APLCCore", targets: ["APLCCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Everything that does real work lives here so it can be unit tested.
        // Swift 5 language mode: PhotoKit's completion-handler APIs predate
        // strict concurrency and fighting them adds no safety to a tool whose
        // real risk is data loss, not data races.
        .target(name: "APLCCore", swiftSettings: [.swiftLanguageMode(.v5)]),

        .executableTarget(
            name: "aplc",
            dependencies: [
                "APLCCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // A bare SwiftPM executable has no bundle, so TCC finds no
                // NSPhotoLibraryUsageDescription and the process is killed on
                // first PhotoKit access. Embedding the plist in __TEXT fixes it.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(packageRoot)/Resources/Info.plist",
                ])
            ]
        ),

        .testTarget(name: "APLCCoreTests", dependencies: ["APLCCore"]),
    ]
)

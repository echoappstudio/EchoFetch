// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EchoFetch",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EchoFetchCore", targets: ["EchoFetchCore"]),
        .executable(name: "EchoFetchApp", targets: ["EchoFetchApp"])
    ],
    dependencies: [
        // Automatic updates. Pinned exactly; the packaged app embeds this framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "EchoFetchCore"),
        .executableTarget(
            name: "EchoFetchApp",
            dependencies: [
                "EchoFetchCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                // SwiftUI's VideoPlayer (Choose Part) needs AVKit loaded, but no code here calls
                // AVKit directly, so the linker drops the automatic link and the window crashes
                // (0.4.0). Name it so it always loads; package-app.sh checks it is there.
                .linkedFramework("AVKit"),
                // The packaged app keeps Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(name: "EchoFetchTests", dependencies: ["EchoFetchCore"])
    ]
)

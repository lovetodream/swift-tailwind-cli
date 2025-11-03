// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-tailwind-cli",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "TailwindCLI",
            targets: ["TailwindCLI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.88.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.1"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.2.1", traits: ["SubprocessSpan"]),
    ],
    targets: [
        .target(
            name: "TailwindCLI",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .testTarget(
            name: "TailwindCLITests",
            dependencies: [.product(name: "_NIOFileSystem", package: "swift-nio"), "TailwindCLI"]
        ),
    ]
)

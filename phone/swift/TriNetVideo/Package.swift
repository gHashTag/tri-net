// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TriNetVideo",
    platforms: [.iOS(.v15)],
    products: [
        .executable(name: "TriNetVideo", targets: ["TriNetVideo"])
    ],
    targets: [
        .executableTarget(
            name: "TriNetVideo",
            path: "Sources/TriNetVideo"
        )
    ]
)

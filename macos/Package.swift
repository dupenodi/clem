// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Clem",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "Clem",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Clem"
        )
    ]
)

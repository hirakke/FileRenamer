// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileRenamer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FileRenamer", targets: ["FileRenamer"]),
        .library(name: "RenameKit", targets: ["RenameKit"])
    ],
    targets: [
        // Pure logic. No AppKit / SwiftUI. Fully unit testable.
        .target(
            name: "RenameKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // SwiftUI layer. Owns no rename logic.
        .executableTarget(
            name: "FileRenamer",
            dependencies: ["RenameKit"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // A lightweight executable harness is retained so the safety suite can also
        // run on minimal Swift installations: `swift run RenameKitTests`.
        // Run with `swift run RenameKitTests`.
        .executableTarget(
            name: "RenameKitTests",
            dependencies: ["RenameKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

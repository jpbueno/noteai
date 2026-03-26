// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoteAI",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "NoteAI",
            dependencies: [
                "WhisperKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "NoteAI"
        ),
        .testTarget(
            name: "NoteAITests",
            dependencies: ["NoteAI"],
            path: "NoteAITests"
        ),
    ]
)

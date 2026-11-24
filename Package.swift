// swift-tools-version: 6.0
import PackageDescription

// Kirie builds with SwiftPM alone (Command Line Tools are enough; Xcode is optional).
// Module boundaries follow Docs/Architecture/ADR-0001-foundations.md.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Kirie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KirieApp", targets: ["KirieApp"]),
        .executable(name: "kirie", targets: ["kirie"]),
        .library(name: "ProjectDomain", targets: ["ProjectDomain"]),
    ],
    targets: [
        // Pure value-type domain: time maths, project schema, commands, undo, validation.
        .target(name: "ProjectDomain"),
        // .kirie package I/O, atomic saves, autosave, snapshots, recovery, recents index.
        .target(name: "Persistence", dependencies: ["ProjectDomain"]),
        // Probing, thumbnails, waveforms, beat detection.
        .target(name: "MediaServices", dependencies: ["ProjectDomain"], swiftSettings: v5),
        // Composition building, GPU compositor, playback items, export, verification.
        .target(name: "RenderEngine", dependencies: ["ProjectDomain", "MediaServices"], swiftSettings: v5),
        // Panel detection, framing, contact sheets, QA hashing, carousel export.
        .target(name: "ComicStudio", dependencies: ["ProjectDomain", "MediaServices", "RenderEngine"], swiftSettings: v5),
        // Application services shared by the app, the CLI and (later) MCP.
        .target(
            name: "KirieServices",
            dependencies: ["ProjectDomain", "Persistence", "MediaServices", "RenderEngine", "ComicStudio"],
            swiftSettings: v5
        ),
        .executableTarget(name: "kirie", dependencies: ["KirieServices"], swiftSettings: v5),
        .executableTarget(name: "KirieApp", dependencies: ["KirieServices"], swiftSettings: v5),

        .testTarget(name: "ProjectDomainTests", dependencies: ["ProjectDomain"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "ProjectDomain"]),
        .testTarget(name: "MediaServicesTests", dependencies: ["MediaServices", "KirieServices"], swiftSettings: v5),
        .testTarget(name: "RenderEngineTests", dependencies: ["RenderEngine", "KirieServices"], swiftSettings: v5),
        .testTarget(name: "ComicStudioTests", dependencies: ["ComicStudio", "KirieServices"], swiftSettings: v5),
        .testTarget(name: "KirieServicesTests", dependencies: ["KirieServices", "ComicStudio"], swiftSettings: v5),
    ]
)

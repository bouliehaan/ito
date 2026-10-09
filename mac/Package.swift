// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ito",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ito", targets: ["ito"]),
    ],
    targets: [
        // Everything that is not UI: Noise, pairing, the wire, the store, the link
        // client, call audio. Testable on its own.
        .target(
            name: "ItoKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ito",
            dependencies: ["ItoKit"]
        ),
        .testTarget(
            name: "ItoKitTests",
            dependencies: ["ItoKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

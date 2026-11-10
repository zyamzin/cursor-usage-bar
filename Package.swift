// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CursorUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CursorUsageBar",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StudyTimer",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "StudyTimer", targets: ["StudyTimer"])],
    targets: [
        .target(name: "StudyTimerCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "StudyTimer", dependencies: ["StudyTimerCore"]),
        .testTarget(name: "StudyTimerCoreTests", dependencies: ["StudyTimerCore"]),
        .testTarget(name: "StudyTimerAppTests", dependencies: ["StudyTimer", "StudyTimerCore"])
    ]
)

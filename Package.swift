// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeatherWallpaper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WeatherCore", targets: ["WeatherCore"]),
        .executable(name: "WeatherWallpaper", targets: ["WeatherWallpaper"])
    ],
    targets: [
        .target(name: "WeatherCore"),
        .executableTarget(
            name: "WeatherWallpaper",
            dependencies: ["WeatherCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "WeatherCoreTests", dependencies: ["WeatherCore"]),
        .testTarget(name: "WeatherWallpaperTests", dependencies: ["WeatherWallpaper"], resources: [.copy("Fixtures")])
    ]
)

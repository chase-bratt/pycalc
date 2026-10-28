// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PyCalc",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PyCalc", targets: ["PyCalc"]),
    ],
    targets: [
        .target(
            name: "PyCalcCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "PyCalc",
            dependencies: ["PyCalcCore"]
        ),
        .testTarget(
            name: "PyCalcCoreTests",
            dependencies: ["PyCalcCore"]
        ),
    ]
)

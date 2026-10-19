// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModelMatrix",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ModelMatrixCore", targets: ["ModelMatrixCore"]),
        .executable(name: "ModelMatrixApp", targets: ["ModelMatrixApp"]),
        .executable(name: "ModelMatrixController", targets: ["ModelMatrixController"]),
        .executable(name: "BumpVersion", targets: ["BumpVersion"]),
        .executable(name: "CheckCycles", targets: ["CheckCycles"]),
    ],
    dependencies: [
        .package(path: "Vendor/MenuBarExtraAccess")
    ],
    targets: [
        .target(
            name: "ModelMatrixCore"
        ),
        .executableTarget(
            name: "ModelMatrixApp",
            dependencies: [
                "ModelMatrixCore",
                .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess")
            ]
        ),
        .target(
            name: "ModelMatrixControllerCore",
            dependencies: ["ModelMatrixCore"],
            linkerSettings: [.linkedFramework("Network")]
        ),
        .executableTarget(
            name: "ModelMatrixController",
            dependencies: ["ModelMatrixControllerCore", "ModelMatrixCore"]
        ),
        .target(
            name: "BumpVersionCore",
            path: "Sources/BumpVersionCore"
        ),
        .executableTarget(
            name: "BumpVersion",
            dependencies: ["BumpVersionCore"],
            path: "Sources/BumpVersion"
        ),
        .target(
            name: "CheckCyclesCore",
            path: "Sources/CheckCyclesCore"
        ),
        .executableTarget(
            name: "CheckCycles",
            dependencies: ["CheckCyclesCore"],
            path: "Sources/CheckCycles"
        ),
        .target(
            name: "ModelMatrixTestSupport",
            dependencies: ["ModelMatrixCore"],
            path: "Tests/ModelMatrixTestSupport"
        ),
        .testTarget(
            name: "ModelMatrixCoreTests",
            dependencies: ["ModelMatrixCore", "ModelMatrixTestSupport"]
        ),
        .testTarget(
            name: "ModelMatrixAppTests",
            dependencies: ["ModelMatrixApp", "ModelMatrixTestSupport"]
        ),
        .testTarget(
            name: "ModelMatrixControllerTests",
            dependencies: ["ModelMatrixControllerCore", "ModelMatrixCore"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "BumpVersionCoreTests",
            dependencies: ["BumpVersionCore"]
        ),
        .testTarget(
            name: "CheckCyclesCoreTests",
            dependencies: ["CheckCyclesCore"]
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZSignKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "ZSignKit",
            targets: ["ZSignKit"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/krzyzanowskim/OpenSSL-Package.git",
            exact: "3.6.5000"
        )
    ],
    targets: [
        .target(
            name: "CZSign",
            dependencies: [
                .product(name: "OpenSSL", package: "OpenSSL-Package")
            ],
            path: "Sources/CZSign",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("core"),
                .headerSearchPath("common"),
                .headerSearchPath("third-party/minizip"),
                .define("ZSIGN_VERSION", to: "1.1.3")
            ],
            cxxSettings: [
                .headerSearchPath("."),
                .headerSearchPath("core"),
                .headerSearchPath("common"),
                .headerSearchPath("third-party/minizip"),
                .define("ZSIGN_VERSION", to: "1.1.3")
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("c++")
            ]
        ),
        .target(
            name: "ZSignKit",
            dependencies: ["CZSign"],
            path: "Sources/ZSignKit"
        ),
        .testTarget(
            name: "ZSignKitTests",
            dependencies: ["ZSignKit"],
            path: "Tests/ZSignKitTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)

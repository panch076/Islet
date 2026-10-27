// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Islet",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.2.5"),
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Islet",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Lottie", package: "lottie-spm"),
            ],
            path: "Sources/Islet",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

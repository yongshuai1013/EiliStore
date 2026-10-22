// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnisetteKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "AnisetteKit", targets: ["AnisetteKit"])],
    targets: [
        .binaryTarget(name: "Unicorn", path: "Artifacts/Unicorn.xcframework"),
        .target(
            name: "anisette_core",
            dependencies: ["Unicorn"],
            path: "Native",
            cSettings: [.headerSearchPath(".")]
        ),
        .target(
            name: "AnisetteKit",
            dependencies: ["anisette_core"],
            path: ".",
            exclude: ["Package.swift", "Native", "Tests", "LICENSE", "UNICORN-LICENSE", "VENDORING.md", "Artifacts"],
            sources: ["Sources"]
        ),
        .testTarget(name: "AnisetteKitTests", dependencies: ["AnisetteKit"], path: "Tests")
    ],
    cxxLanguageStandard: .cxx17
)

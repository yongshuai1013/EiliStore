// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EMProxyPkg",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "EMProxy", targets: ["EMProxy"])
    ],
    targets: [
        .binaryTarget(
            name: "EMProxy",
            url: "https://github.com/SideStore/em_proxy/releases/download/v0.9.3/EMProxy.xcframework.zip",
            checksum: "3998789c38d09b55e488d46e31897affc7bbcb9c244d7a9d5b2d5cf6afd916c3"
        )
    ]
)

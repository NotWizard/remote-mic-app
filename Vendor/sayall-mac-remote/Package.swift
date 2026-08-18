// swift-tools-version: 6.2
import PackageDescription

// Fork-local stand-in for the private GetSayAll/sayall-mac-remote component.
// Package identity must stay "sayall-mac-remote" so the root manifest's product
// references keep matching upstream byte for byte.
let package = Package(
    name: "sayall-mac-remote",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SayAllMacRemoteCore", targets: ["SayAllMacRemoteCore"]),
        .library(name: "SayAllMacRemoteUI", targets: ["SayAllMacRemoteUI"]),
    ],
    targets: [
        .target(name: "SayAllMacRemoteCore"),
        .target(name: "SayAllMacRemoteUI", dependencies: ["SayAllMacRemoteCore"]),
    ],
    swiftLanguageModes: [.v5]
)

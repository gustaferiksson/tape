// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TapeCore",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "TapeCore", targets: ["TapeCore"])
  ],
  targets: [
    .target(name: "TapeCore"),
    .testTarget(name: "TapeCoreTests", dependencies: ["TapeCore"]),
  ]
)

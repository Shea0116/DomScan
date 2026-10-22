// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "DomScanBridge",
  platforms: [.macOS(.v10_15)],
  products: [.library(name: "DomScanBridge", targets: ["DomScanBridge"])],
  targets: [.target(name: "DomScanBridge", resources: [.copy("Resources/picker.js")])]
)

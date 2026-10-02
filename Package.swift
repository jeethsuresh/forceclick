// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ForceClick", platforms: [.macOS(.v13)], products: [.executable(name: "ForceClick", targets: ["ForceClick"])], targets: [.executableTarget(name: "ForceClick"), .testTarget(name: "ForceClickTests", dependencies: ["ForceClick"])])

// swift-tools-version: 5.9
import PackageDescription
import Foundation
let prefix = ProcessInfo.processInfo.environment["MTP_PREFIX"] ?? "/opt/homebrew"
let package = Package(name: "KindleUSB", platforms: [.macOS(.v13)], products: [.executable(name: "KindleUSB", targets: ["KindleUSB"])], targets: [
    .target(name: "CMTP", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-I\(prefix)/include"])], linkerSettings: [.unsafeFlags(["-L\(prefix)/lib"]), .linkedLibrary("mtp")]),
    .executableTarget(name: "KindleUSB", dependencies: ["CMTP"], swiftSettings: [.unsafeFlags(["-Xcc", "-I\(prefix)/include"])])
])

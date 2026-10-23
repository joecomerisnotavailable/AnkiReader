// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ReadingCompanion", platforms: [.macOS(.v13), .iOS(.v18)], products: [.library(name: "ReadingCore", targets: ["ReadingCore"])], targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .target(name: "ReadingCore", dependencies: ["CSQLite"]),
    .testTarget(name: "ReadingCoreTests", dependencies: ["ReadingCore"])
], swiftLanguageModes: [.v5])

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SkillShelf",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SkillShelfCore", targets: ["SkillShelfCore"]),
        .executable(name: "SkillShelf", targets: ["SkillShelf"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(name: "SkillShelfCore"),
        .executableTarget(
            name: "SkillShelf",
            dependencies: ["SkillShelfCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SkillShelfCoreTests", dependencies: ["SkillShelfCore"]),
    ]
)

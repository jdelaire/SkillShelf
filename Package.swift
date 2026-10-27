// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SkillShelf",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SkillShelfCore", targets: ["SkillShelfCore"]),
        .executable(name: "SkillShelf", targets: ["SkillShelf"]),
    ],
    targets: [
        .target(name: "SkillShelfCore"),
        .executableTarget(name: "SkillShelf", dependencies: ["SkillShelfCore"]),
        .testTarget(name: "SkillShelfCoreTests", dependencies: ["SkillShelfCore"]),
    ]
)

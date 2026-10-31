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
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .target(name: "SkillShelfCore"),
        .executableTarget(name: "SandboxProbe"),
        .executableTarget(
            name: "SkillShelf",
            dependencies: [
                "SkillShelfCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SkillShelfCoreTests", dependencies: ["SkillShelfCore", "SkillShelf", "SandboxProbe"]),
    ]
)

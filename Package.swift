// swift-tools-version: 6.0

import PackageDescription
import Foundation

private func testingMacroPluginPath() -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--find", "swiftc"]
    process.standardOutput = output
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let compiler = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !compiler.isEmpty
        else { return "" }

        return URL(fileURLWithPath: compiler)
            .deletingLastPathComponent()
            .appendingPathComponent("../lib/swift/host/plugins/testing/libTestingMacros.dylib")
            .standardizedFileURL.path
    } catch {
        return ""
    }
}

let testingPlugin = testingMacroPluginPath()

let package = Package(
    name: "VibeShot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeShot", targets: ["VibeShot"])
    ],
    targets: [
        .executableTarget(
            name: "VibeShot",
            path: "VibeShot",
            exclude: ["Info.plist", "VibeShot.entitlements", "Resources/AppIcon.source.png"]
        ),
        .testTarget(
            name: "VibeShotTests",
            dependencies: ["VibeShot"],
            path: "VibeShotTests",
            swiftSettings: [
                .unsafeFlags(testingPlugin.isEmpty ? [] : ["-load-plugin-library", testingPlugin])
            ]
        )
    ]
)

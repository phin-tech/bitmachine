import Foundation
import Testing
@testable import BitMachineKit

@Test func versionMatchesProjectYml() throws {
    // Tests/BitMachineKitTests/VersionTests.swift -> the repository
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
    #expect(project.contains("MARKETING_VERSION: \"\(BitMachineVersion.current)\""),
            "BitMachineVersion.current differs from project.yml; bump with `just bump`, which writes both")
}

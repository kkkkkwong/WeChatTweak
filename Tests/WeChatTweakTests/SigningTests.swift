import Foundation
import Testing
@testable import WeChatTweak

struct SigningTests {
    @Test
    func repairsUnentitledNestedCodeBeforeSigningItsApp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = directory.appendingPathComponent("Signing Fixture.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = macOS.appendingPathComponent("Fixture")
        let library = frameworks.appendingPathComponent("nested.dylib")
        let source = directory.appendingPathComponent("fixture.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        try Command.execute("/usr/bin/xcrun", arguments: ["clang", source.path, "-o", executable.path])
        let marker = "wechattweak-nested-signing-original"
        try "const char *fixture(void) { return \"\(marker)\"; }\n".write(to: source, atomically: true, encoding: .utf8)
        try Command.execute("/usr/bin/xcrun", arguments: ["clang", "-dynamiclib", source.path, "-o", library.path])
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "org.wechattweak.signing-fixture",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Command.execute("/usr/bin/codesign", arguments: ["--force", "--sign", "-", library.path])
        #expect(try Signing.entitlements(at: library).isEmpty)
        // Invalidate an unentitled library's signature without damaging Mach-O.
        var bytes = try Data(contentsOf: library)
        let range = try #require(bytes.range(of: Data(marker.utf8)))
        bytes[range.lowerBound] = UInt8(ascii: "W")
        try bytes.write(to: library)
        #expect(throws: (any Swift.Error).self) {
            try Command.execute("/usr/bin/codesign", arguments: ["--verify", "--strict", library.path])
        }
        // Some WeChat resources use generic code signatures stored in xattrs.
        let resource = frameworks.appendingPathComponent("signed-resource.json")
        try Data("{\"fixture\":1}".utf8).write(to: resource)
        try Command.execute("/usr/bin/codesign", arguments: ["--force", "--sign", "-", resource.path])
        #expect(try Signing.entitlements(at: resource).isEmpty)
        let updatedResource = Data("{\"fixture\":2}".utf8)
        try updatedResource.write(to: resource)
        #expect(throws: (any Swift.Error).self) {
            try Command.execute("/usr/bin/codesign", arguments: ["--verify", "--strict", resource.path])
        }
        try Signing.resign(app: app, binaries: [])
        try Command.execute("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path])
        #expect(try Signing.entitlements(at: library).isEmpty)
        #expect(try Data(contentsOf: resource) == updatedResource)
    }

    @Test
    func removesDeveloperEntitlementsWithoutDroppingSandboxPermissions() {
        let original: [String: Any] = [
            "com.apple.developer.team-identifier": "5A4RE8SF68",
            "com.apple.developer.example-capability": true,
            "com.apple.application-identifier": "5A4RE8SF68.com.tencent.xinWeChat",
            "com.apple.security.app-sandbox": true,
            "com.apple.security.application-groups": ["5A4RE8SF68.com.tencent.xinWeChat"],
            "com.apple.security.device.camera": true,
            "com.apple.security.device.audio-input": true,
            "com.apple.security.network.client": true,
            "com.apple.security.files.user-selected.read-write": true
        ]
        let result = Signing.adHocEntitlements(original)
        #expect(!result.keys.contains(where: { $0.hasPrefix("com.apple.developer.") }))
        for (key, value) in original where !key.hasPrefix("com.apple.developer.") {
            #expect(NSDictionary(dictionary: [key: result[key]!]).isEqual(to: [key: value]))
        }
        #expect(result["com.apple.security.cs.disable-library-validation"] as? Bool == true)
        #expect(result["com.apple.security.cs.allow-unsigned-executable-memory"] as? Bool == true)
        #expect(NSDictionary(dictionary: Signing.adHocEntitlements(result)).isEqual(to: result))
    }

    @Test
    func doesNotAddEntitlementsToUnprofiledLibraries() {
        #expect(Signing.adHocEntitlements([:]).isEmpty)
    }

    @Test
    func preservesHelperSandboxInheritance() {
        let original: [String: Any] = [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.inherit": true,
            "com.apple.security.cs.allow-jit": true
        ]
        let result = Signing.adHocEntitlements(original)
        #expect(result["com.apple.security.inherit"] as? Bool == true)
        #expect(result["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(result["com.apple.security.cs.allow-jit"] as? Bool == true)
    }
}

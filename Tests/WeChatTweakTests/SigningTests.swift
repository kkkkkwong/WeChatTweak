import Foundation
import Testing
@testable import WeChatTweak

struct SigningTests {
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

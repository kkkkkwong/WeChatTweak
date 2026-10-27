import Foundation
import Testing
@testable import WeChatTweak

struct RuntimeInjectionTests {
    private func library() -> Data {
        var data = Data(repeating: 0, count: 512)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
        }
        put(UInt32(0xfeedfacf), at: 0)
        put(UInt32(0x0100000c), at: 4)
        put(UInt32(6), at: 12)
        put(UInt32(1), at: 16)
        put(UInt32(152), at: 20)
        put(UInt32(0x19), at: 32)
        put(UInt32(152), at: 36)
        put(UInt64(512), at: 64)
        put(UInt64(512), at: 80)
        put(UInt32(1), at: 96)
        put(UInt64(256), at: 136)
        put(UInt64(256), at: 144)
        put(UInt32(256), at: 152)
        data.replaceSubrange(256..<260, with: [0xc0, 0x03, 0x5f, 0xd6])
        return data
    }

    private func withApp(_ body: (URL, URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = directory.appendingPathComponent("WeChat 2.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.tencent.xinWeChat",
            "CFBundleExecutable": "WeChat",
            "CFBundleVersion": "270115"
        ], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try library().write(to: resources.appendingPathComponent("wechat.dylib"))
        let runtime = directory.appendingPathComponent("runtime.dylib")
        try library().write(to: runtime)
        try body(app, runtime, resources)
    }

    @Test
    func standaloneInjectionDryRunAndRepeatPreserveCode() throws {
        try withApp { app, runtime, resources in
            let binary = resources.appendingPathComponent("wechat.dylib")
            let installed = resources.appendingPathComponent("libWeChatTweakRuntime.dylib")
            try Command.injectRuntime(app: app, runtimeDylib: runtime, dryRun: true)
            #expect(try Data(contentsOf: binary) == library())
            #expect(!FileManager.default.fileExists(atPath: installed.path))
            let binaries = try Command.injectRuntime(app: app, runtimeDylib: runtime)
            #expect(binaries == [binary, installed])
            let injected = try Data(contentsOf: binary)
            #expect(injected[256..<512] == library()[256..<512])
            #expect(injected[16..<20] == Data([2, 0, 0, 0]))
            #expect(try Data(contentsOf: installed) == Data(contentsOf: runtime))
            try Command.injectRuntime(app: app, runtimeDylib: runtime)
            #expect(try Data(contentsOf: binary) == injected)
            // Updating with the installed library itself must not delete it.
            try Command.injectRuntime(app: app, runtimeDylib: installed)
            #expect(try Data(contentsOf: installed) == library())
            #expect(try Data(contentsOf: binary) == injected)
        }
    }

    @Test
    func invalidPreflightDoesNotReplaceExistingRuntime() throws {
        try withApp { app, runtime, resources in
            let binary = resources.appendingPathComponent("wechat.dylib")
            let installed = resources.appendingPathComponent("libWeChatTweakRuntime.dylib")
            let previous = Data("previous runtime".utf8)
            try previous.write(to: installed)
            #expect(throws: (any Swift.Error).self) {
                try Command.injectRuntime(app: app, runtimeDylib: resources.appendingPathComponent("missing"))
            }
            #expect(try Data(contentsOf: binary) == library())
            try Data([0]).write(to: binary)
            #expect(throws: (any Swift.Error).self) { try Command.injectRuntime(app: app, runtimeDylib: runtime) }
            #expect(try Data(contentsOf: installed) == previous)
            #expect(try Data(contentsOf: binary) == Data([0]))
        }
    }

    @Test
    func rejectsForeignAppsAndTargetSymlinkEscapes() throws {
        try withApp { app, runtime, resources in
            let infoURL = app.appendingPathComponent("Contents/Info.plist")
            let info = try Data(contentsOf: infoURL)
            let foreignInfo = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "com.example.other-app",
                "CFBundleExecutable": "WeChat"
            ], format: .xml, options: 0)
            try foreignInfo.write(to: infoURL)
            #expect(throws: (any Swift.Error).self) { try Command.injectRuntime(app: app, runtimeDylib: runtime) }
            try info.write(to: infoURL)
            let binary = resources.appendingPathComponent("wechat.dylib")
            try FileManager.default.removeItem(at: binary)
            try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: runtime)
            #expect(throws: (any Swift.Error).self) { try Command.injectRuntime(app: app, runtimeDylib: runtime) }
            #expect(try Data(contentsOf: runtime) == library())
        }
    }

    @Test
    func runtimeDestinationSymlinkDoesNotWriteOutsideTheApp() throws {
        try withApp { app, runtime, resources in
            let outside = runtime.deletingLastPathComponent().appendingPathComponent("outside.dylib")
            let original = Data("unrelated library".utf8)
            try original.write(to: outside)
            let destination = resources.appendingPathComponent("libWeChatTweakRuntime.dylib")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
            try Command.injectRuntime(app: app, runtimeDylib: runtime)
            #expect(try Data(contentsOf: outside) == original)
            #expect(try Data(contentsOf: destination) == library())
            #expect(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        }
    }
}

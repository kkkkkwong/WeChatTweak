import Darwin
import Foundation
import Testing
@testable import WeChatTweak

struct UpdateLockTests {
    private func withApp(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("WeChat 2.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer {
            // Independent cleanup also works if the operation under test failed.
            try? Command.execute("/bin/chflags", arguments: ["-R", "nouchg", root.path])
            try? FileManager.default.removeItem(at: root)
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.tencent.xinWeChat",
            "CFBundleExecutable": "WeChat",
            "CFBundleVersion": "270115"
        ], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("original binary".utf8).write(to: resources.appendingPathComponent("wechat.dylib"))
        try body(app, root)
    }

    private func flags(_ url: URL) throws -> UInt32 {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
        return metadata.st_flags
    }

    @Test
    func preventsOverwriteAndReplacementAndUnlocksWithoutChangingContents() throws {
        try withApp { app, root in
            let binary = app.appendingPathComponent("Contents/Resources/wechat.dylib")
            let original = try Data(contentsOf: binary)
            let outside = root.appendingPathComponent("other-app-library")
            try original.write(to: outside)
            let link = app.appendingPathComponent("Contents/Resources/shared-library")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            #expect(chflags(binary.path, UInt32(UF_NODUMP)) == 0)

            try UpdateLock.apply(UpdateLock.prepare(app: app), locked: true)
            let locked = try UpdateLock.prepare(app: app)
            #expect(locked.lockedCount == locked.items.count)
            #expect(locked.items.allSatisfy { $0.url != outside && $0.url != link })
            #expect(try flags(outside) & UInt32(UF_IMMUTABLE) == 0)
            #expect(try Data(contentsOf: binary) == original)
            #expect(throws: (any Swift.Error).self) { try FileHandle(forUpdating: binary).close() }
            #expect(throws: (any Swift.Error).self) {
                try Data("replacement".utf8).write(to: binary, options: .atomic)
            }
            #expect(throws: (any Swift.Error).self) {
                try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("replaced.app"))
            }
            #expect(throws: (any Swift.Error).self) {
                try FileManager.default.createDirectory(at: app.appendingPathComponent("new"), withIntermediateDirectories: false)
            }
            // Reapplying the lock must be harmless.
            try UpdateLock.apply(locked, locked: true)
            try UpdateLock.apply(UpdateLock.prepare(app: app), locked: false)
            try UpdateLock.apply(UpdateLock.prepare(app: app), locked: false)
            #expect(try UpdateLock.prepare(app: app).lockedCount == 0)
            #expect(try flags(binary) & UInt32(UF_NODUMP) != 0)
            #expect(try Data(contentsOf: binary) == original)
            #expect(try Data(contentsOf: outside) == original)
            let file = try FileHandle(forUpdating: binary)
            try file.write(contentsOf: Data("updated".utf8))
            try file.close()
        }
    }

    @Test
    func dryRunAndStaleInspectionDoNotLockFiles() throws {
        try withApp { app, _ in
            let plan = try UpdateLock.prepare(app: app)
            try UpdateLock.apply(plan, locked: true, dryRun: true)
            #expect(try UpdateLock.prepare(app: app).lockedCount == 0)
            let binary = app.appendingPathComponent("Contents/Resources/wechat.dylib")
            #expect(chflags(binary.path, UInt32(UF_NODUMP)) == 0)
            #expect(throws: (any Swift.Error).self) { try UpdateLock.apply(plan, locked: true) }
            #expect(try UpdateLock.prepare(app: app).lockedCount == 0)
        }
    }

    @Test
    func rejectsOtherAppsAndHardLinksBeforeChangingAnything() throws {
        try withApp { app, root in
            let outside = root.appendingPathComponent("other-app-library")
            try Data("shared inode".utf8).write(to: outside)
            let link = app.appendingPathComponent("Contents/Resources/hard-link")
            try FileManager.default.linkItem(at: outside, to: link)
            #expect(throws: (any Swift.Error).self) { try UpdateLock.prepare(app: app) }
            #expect(try flags(outside) & UInt32(UF_IMMUTABLE) == 0)
            try FileManager.default.removeItem(at: link)
            let plist = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "com.example.other-app",
                "CFBundleExecutable": "WeChat"
            ], format: .xml, options: 0)
            try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
            #expect(throws: (any Swift.Error).self) { try UpdateLock.prepare(app: app) }
            #expect(try flags(app) & UInt32(UF_IMMUTABLE) == 0)
        }
    }
}

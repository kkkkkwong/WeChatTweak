import Foundation
import Testing
@testable import WeChatTweak

struct PatcherTests {
    private let original = Data([0x40, 0x10, 0x00, 0x34])
    private let replacement = Data([0x82, 0x00, 0x00, 0x14])

    private func config(entries: String = "", binary: String = "Contents/Resources/wechat.dylib") throws -> Config {
        let entries = entries.isEmpty ? #"{"arch":"arm64","addr":"100","expected":"40100034","asm":"82000014"}"# : entries
        return try JSONDecoder().decode(Config.self, from: Data("""
        {"version":"269602","targets":[{"identifier":"revoke","binary":"\(binary)","entries":[\(entries)]}]}
        """.utf8))
    }

    private func thin(cpu: UInt32 = 0x0100000c, filesize: UInt64 = 512) -> Data {
        var data = Data(repeating: 0, count: 512)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
        }
        put(UInt32(0xfeedfacf), at: 0)
        put(cpu, at: 4)
        put(UInt32(6), at: 12)
        put(UInt32(1), at: 16)
        put(UInt32(72), at: 20)
        put(UInt32(0x19), at: 32)
        put(UInt32(72), at: 36)
        put(UInt64(512), at: 64) // vmsize
        put(filesize, at: 80)
        data.replaceSubrange(256..<260, with: original)
        return data
    }

    private func fat(_ slices: [(UInt32, Data)], swapped: Bool = false) -> Data {
        var data = Data(repeating: 0, count: 4096 * (slices.count + 1))
        func put(_ value: UInt32, at offset: Int) {
            var value = swapped ? value.littleEndian : value.bigEndian
            withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        put(0xcafebabe, at: 0)
        put(UInt32(slices.count), at: 4)
        for (i, slice) in slices.enumerated() {
            let base = 8 + i * 20
            put(slice.0, at: base)
            put(UInt32((i + 1) * 4096), at: base + 8)
            put(UInt32(slice.1.count), at: base + 12)
            put(12, at: base + 16)
            data.replaceSubrange(((i + 1) * 4096)..<((i + 1) * 4096 + slice.1.count), with: slice.1)
        }
        return data
    }

    private func withBinary(_ data: Data, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("wechat.dylib")
        try data.write(to: binary)
        try body(binary)
    }

    @Test
    func testThinPatchAndIdempotency() throws {
        try withBinary(thin()) { (binary: URL) throws in
            let entries = try config().targets[0].entries
            let plan = try Patcher.prepare(binary: binary, entries: entries)
            #expect(try Data(contentsOf: binary) == thin())
            try Patcher.apply(plan)
            var expected = thin()
            expected.replaceSubrange(256..<260, with: replacement)
            #expect(try Data(contentsOf: binary) == expected)
            try Patcher.apply(Patcher.prepare(binary: binary, entries: entries))
            #expect(try Data(contentsOf: binary) == expected)
        }
    }

    @Test
    func testUniversalAndSwappedFatLeaveIntelSliceUnchanged() throws {
        for swapped in [false, true] {
            let data = fat([(0x01000007, thin(cpu: 0x01000007)), (0x0100000c, thin())], swapped: swapped)
            try withBinary(data) { (binary: URL) throws in
                let plan = try Patcher.prepare(binary: binary, entries: config().targets[0].entries)
                #expect(plan.writes[0].offset == 8192 + 256)
                try Patcher.apply(plan)
                var expected = data
                expected.replaceSubrange((8192 + 256)..<(8192 + 260), with: replacement)
                #expect(try Data(contentsOf: binary) == expected)
            }
        }
    }

    @Test
    func testRejectsUnexpectedBytesBeforeWriting() throws {
        let entries = #"{"arch":"arm64","addr":"100","expected":"40100034","asm":"82000014"},{"arch":"arm64","addr":"104","expected":"40100034","asm":"82000014"}"#
        try withBinary(thin()) { (binary: URL) throws in
            #expect(throws: (any Swift.Error).self) { try Patcher.prepare(binary: binary, entries: config(entries: entries).targets[0].entries) }
            #expect(try Data(contentsOf: binary) == thin())
        }
    }

    @Test
    func testRejectsTruncatedMissingArchitectureAndZeroFill() throws {
        for data in [Data(), Data(thin().prefix(60)), thin(cpu: 0x01000007), thin(filesize: 256)] {
            try withBinary(data) { (binary: URL) throws in
                #expect(throws: (any Swift.Error).self) { try Patcher.prepare(binary: binary, entries: config().targets[0].entries) }
                #expect(try Data(contentsOf: binary) == data)
            }
        }
    }

    @Test
    func testRejectsChangedFileAfterPreflight() throws {
        try withBinary(thin()) { (binary: URL) throws in
            let plan = try Patcher.prepare(binary: binary, entries: config().targets[0].entries)
            var changed = thin()
            changed[256] = 0
            try changed.write(to: binary)
            #expect(throws: (any Swift.Error).self) { try Patcher.apply(plan) }
            #expect(try Data(contentsOf: binary) == changed)
        }
    }

    @Test
    func testVirtualAddressTranslationAndOverlaps() throws {
        var data = thin()
        data[59] = 1 // __TEXT vmaddr = 0x1000000; fileoff remains zero.
        let entry = #"{"arch":"arm64","addr":"1000100","expected":"40100034","asm":"82000014"}"#
        try withBinary(data) { (binary: URL) throws in
            let plan = try Patcher.prepare(binary: binary, entries: config(entries: entry).targets[0].entries)
            #expect(plan.writes[0].offset == 256)
            #expect(throws: (any Swift.Error).self) {
                try Patcher.prepare(binary: binary, entries: config(entries: entry + "," + entry).targets[0].entries)
            }
        }
    }

    @Test
    func testPreflightAllBinariesAndRejectSymlinkEscape() async throws {
        #if arch(arm64)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("WeChat.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = resources.appendingPathComponent("first.dylib")
        try thin().write(to: first)
        let entries = #"[{"arch":"arm64","addr":"100","expected":"40100034","asm":"82000014"}]"#
        let json = """
        {"version":"269602","targets":[
        {"identifier":"first","binary":"Contents/Resources/first.dylib","entries":\(entries)},
        {"identifier":"second","binary":"Contents/Resources/second.dylib","entries":\(entries)}]}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        await #expect(throws: (any Swift.Error).self) { try await Command.patch(app: app, config: config) }
        #expect(try Data(contentsOf: first) == thin())
        let outside = root.appendingPathComponent("outside.dylib")
        try thin().write(to: outside)
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("second.dylib"), withDestinationURL: outside)
        await #expect(throws: (any Swift.Error).self) { try await Command.patch(app: app, config: config) }
        #expect(try Data(contentsOf: outside) == thin())
        #expect(try Data(contentsOf: first) == thin())
        #endif
    }


    @Test
    func testLegacyConfigAndInvalidEntries() throws {
        let legacy = Data(#"{"version":"34371","targets":[{"identifier":"revoke","entries":[{"arch":"arm64","addr":"100","asm":"00008052C0035FD6"}]}]}"#.utf8)
        let decoded = try JSONDecoder().decode(Config.self, from: legacy)
        #expect(decoded.targets[0].binary == "Contents/MacOS/WeChat")
        #expect(decoded.targets[0].entries[0].expected == nil)
        #expect(throws: (any Swift.Error).self) { try config(binary: "Contents/../../outside") }
        #expect(throws: (any Swift.Error).self) { try config(binary: "/tmp/outside") }
        #expect(throws: (any Swift.Error).self) { try config(entries: #"{"arch":"arm64","addr":"100","asm":""}"#) }
        #expect(throws: (any Swift.Error).self) { try config(entries: #"{"arch":"arm64","addr":"100","expected":"00","asm":"82000014"}"#) }
    }

    @Test
    func testAppWithSpacesAndDryRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = directory.appendingPathComponent("WeChat 2.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = resources.appendingPathComponent("wechat.dylib")
        try thin().write(to: binary)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "269602"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let version = try await Command.version(app: app)
        #expect(version == "269602")
        #if arch(arm64)
        let binaries = try await Command.patch(app: app, config: config(), dryRun: true)
        #expect(binaries.count == 1)
        #expect(try Data(contentsOf: binary) == thin())
        #endif
    }
}

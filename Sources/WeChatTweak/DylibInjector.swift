import Foundation
import MachO

struct DylibInjector {
    struct Write {
        let offset: UInt64
        let original: Data
        let replacement: Data
    }

    struct Plan {
        let binary: URL
        let writes: [Write]
        let alreadyInjected: Bool
    }

    enum Error: LocalizedError {
        case invalidMachO
        case noArm64Slice
        case noHeaderPadding
        case changedSincePreflight

        var errorDescription: String? {
            switch self {
            case .invalidMachO: return "Invalid Mach-O binary; cannot add the runtime load command"
            case .noArm64Slice: return "The WeChat library does not contain an arm64 slice"
            case .noHeaderPadding: return "The WeChat library has insufficient Mach-O header padding for the runtime load command"
            case .changedSincePreflight: return "The WeChat library changed after runtime preflight"
            }
        }
    }

    static func prepare(binary: URL, installName: String) throws -> Plan {
        let data = try Data(contentsOf: binary, options: .mappedIfSafe)
        let slice = try arm64Slice(in: data)
        let header = slice.offset
        guard read32(data, header) == UInt32(MH_MAGIC_64) else { throw Error.invalidMachO }
        let commandCount = Int(read32(data, header + 16))
        let commandBytes = Int(read32(data, header + 20))
        guard commandBytes <= slice.size - 32, commandCount <= commandBytes / 8 else { throw Error.invalidMachO }
        let commandStart = header + 32
        let insertion = commandStart + commandBytes
        let commandEnd = insertion
        var cursor = commandStart
        var firstSection = Int.max

        for _ in 0..<commandCount {
            guard cursor <= commandEnd - 8 else { throw Error.invalidMachO }
            let command = read32(data, cursor)
            let size = Int(read32(data, cursor + 4))
            guard size >= 8, size <= commandEnd - cursor else { throw Error.invalidMachO }
            if command == 0x0c { // LC_LOAD_DYLIB
                guard size >= 24 else { throw Error.invalidMachO }
                let nameOffset = Int(read32(data, cursor + 8))
                guard nameOffset >= 24, nameOffset < size else { throw Error.invalidMachO }
                let nameStart = cursor + nameOffset
                let nameEnd = (nameStart..<(cursor + size)).first { data[$0] == 0 } ?? (cursor + size)
                if String(data: data[nameStart..<nameEnd], encoding: .utf8) == installName {
                    return Plan(binary: binary, writes: [], alreadyInjected: true)
                }
            }
            if command == UInt32(LC_SEGMENT_64) {
                guard size >= 72 else { throw Error.invalidMachO }
                let sectionCount = Int(read32(data, cursor + 64))
                guard sectionCount <= (size - 72) / 80 else { throw Error.invalidMachO }
                if sectionCount == 0 {
                    let fileOffset = Int(read64(data, cursor + 40))
                    if fileOffset > 0 { firstSection = min(firstSection, header + fileOffset) }
                } else {
                    for index in 0..<sectionCount {
                        let fileOffset = Int(read32(data, cursor + 72 + index * 80 + 48))
                        if fileOffset > 0 { firstSection = min(firstSection, header + fileOffset) }
                    }
                }
            }
            cursor += size
        }

        guard firstSection != Int.max else { throw Error.invalidMachO }
        let path = Array(installName.utf8) + [0]
        let size = (24 + path.count + 7) & ~7
        guard firstSection >= insertion, size <= firstSection - insertion else { throw Error.noHeaderPadding }
        let command = loadCommand(path: path, size: size)
        let padding = data.subdata(in: insertion..<(insertion + size))
        guard padding.allSatisfy({ $0 == 0 }) else { throw Error.noHeaderPadding }

        let countOffset = header + 16
        let sizeOffset = header + 20
        return Plan(binary: binary, writes: [
            Write(offset: UInt64(insertion), original: padding, replacement: command),
            Write(offset: UInt64(countOffset), original: data.subdata(in: countOffset..<(countOffset + 4)), replacement: le32(UInt32(commandCount + 1))),
            Write(offset: UInt64(sizeOffset), original: data.subdata(in: sizeOffset..<(sizeOffset + 4)), replacement: le32(UInt32(commandBytes + size)))
        ], alreadyInjected: false)
    }

    static func apply(_ plan: Plan) throws {
        guard !plan.writes.isEmpty else { return }
        let file = try FileHandle(forUpdating: plan.binary)
        defer { try? file.close() }
        for write in plan.writes {
            try file.seek(toOffset: write.offset)
            guard try file.read(upToCount: write.original.count) == write.original else { throw Error.changedSincePreflight }
        }
        for write in plan.writes {
            try file.seek(toOffset: write.offset)
            try file.write(contentsOf: write.replacement)
        }
        try file.synchronize()
    }

    private struct Slice { let offset: Int; let size: Int }

    private static func arm64Slice(in data: Data) throws -> Slice {
        guard data.count >= 4 else { throw Error.invalidMachO }
        if read32(data, 0, bigEndian: true) == 0xcafebabe {
            guard data.count >= 8 else { throw Error.invalidMachO }
            let count = Int(read32(data, 4, bigEndian: true))
            guard count <= (data.count - 8) / 20 else { throw Error.invalidMachO }
            for index in 0..<count {
                let base = 8 + index * 20
                guard read32(data, base, bigEndian: true) == UInt32(CPU_TYPE_ARM64) else { continue }
                let offset = Int(read32(data, base + 8, bigEndian: true))
                let size = Int(read32(data, base + 12, bigEndian: true))
                guard offset <= data.count, size <= data.count - offset else { throw Error.invalidMachO }
                return Slice(offset: offset, size: size)
            }
            throw Error.noArm64Slice
        }
        guard read32(data, 0) == UInt32(MH_MAGIC_64), read32(data, 4) == UInt32(CPU_TYPE_ARM64) else {
            throw Error.noArm64Slice
        }
        return Slice(offset: 0, size: data.count)
    }

    private static func loadCommand(path: [UInt8], size: Int) -> Data {
        var bytes = Data()
        bytes.append(le32(0x0c))
        bytes.append(le32(UInt32(size)))
        bytes.append(le32(24))
        bytes.append(le32(2))
        bytes.append(le32(0))
        bytes.append(le32(0))
        bytes.append(contentsOf: path)
        bytes.append(contentsOf: repeatElement(0, count: size - bytes.count))
        return bytes
    }

    private static func read32(_ data: Data, _ offset: Int, bigEndian: Bool = false) -> UInt32 {
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }

    private static func read64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })
    }

    private static func le32(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

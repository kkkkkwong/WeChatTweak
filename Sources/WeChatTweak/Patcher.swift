//
//  Patcher.swift
//
//  Created by Sunny Young on 2025/12/4.
//

import Foundation
import MachO

struct Patcher {
    enum Error: LocalizedError {
        case invalidFile
        case noArchMatched
        case vaNotFound(arch: String, va: UInt64)
        case unexpectedBytes(arch: String, va: UInt64)
        case overlappingPatches

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "Invalid or truncated Mach-O file"
            case .noArchMatched: return "The binary does not contain every configured architecture"
            case let .vaNotFound(arch, va): return "Patch address is not file-backed: \(arch) 0x\(String(va, radix: 16))"
            case let .unexpectedBytes(arch, va): return "Unexpected bytes at \(arch) 0x\(String(va, radix: 16)); refusing to patch"
            case .overlappingPatches: return "Overlapping patch locations"
            }
        }
    }

    struct Write {
        let offset: UInt64
        let original: Data
        let replacement: Data
    }

    struct Plan {
        let binary: URL
        let writes: [Write]
    }

    private struct Slice {
        let cpu: UInt32
        let offset: Int
        let size: Int
    }

    // Resolve and validate every write before opening any file for modification.
    static func prepare(binary: URL, entries: [Config.Entry]) throws -> Plan {
        let data = try Data(contentsOf: binary, options: .mappedIfSafe)
        guard !entries.isEmpty else { throw Error.noArchMatched }
        let slices = try slices(in: data)
        var writes: [Write] = []
        for entry in entries {
            guard let slice = slices.first(where: { $0.cpu == entry.arch.cpu }) else {
                throw Error.noArchMatched
            }
            let offset = try fileOffset(in: data, slice: slice, entry: entry)
            let original = data.subdata(in: offset..<(offset + entry.asm.count))
            if let expected = entry.expected, !expected.contains(original) && original != entry.asm {
                throw Error.unexpectedBytes(arch: entry.arch.rawValue, va: entry.addr)
            }
            print("[\(entry.arch.rawValue)] \(binary.lastPathComponent): VA=0x\(String(entry.addr, radix: 16)), offset=0x\(String(offset, radix: 16))\(original == entry.asm ? " (already patched)" : "")")
            writes.append(Write(offset: UInt64(offset), original: original, replacement: entry.asm))
        }
        let sorted = writes.sorted { $0.offset < $1.offset }
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            guard previous.offset + UInt64(previous.replacement.count) <= next.offset else {
                throw Error.overlappingPatches
            }
        }
        return Plan(binary: binary, writes: writes)
    }

    static func apply(_ plan: Plan) throws {
        let file = try FileHandle(forUpdating: plan.binary)
        defer { try? file.close() }
        // Reject files changed after preflight, before performing this plan's writes.
        for write in plan.writes {
            try file.seek(toOffset: write.offset)
            guard try file.read(upToCount: write.original.count) == write.original else {
                throw Error.invalidFile
            }
        }
        for write in plan.writes where write.original != write.replacement {
            try file.seek(toOffset: write.offset)
            try file.write(contentsOf: write.replacement)
        }
        try file.synchronize()
    }

    private static func slices(in data: Data) throws -> [Slice] {
        let magic = try uint32(data, at: 0, bigEndian: true)
        if magic == FAT_MAGIC || magic == FAT_CIGAM {
            let bigEndian = magic == FAT_MAGIC
            let count = Int(try uint32(data, at: 4, bigEndian: bigEndian))
            guard data.count >= 8, count <= (data.count - 8) / 20 else { throw Error.invalidFile }
            return try (0..<count).map { index in
                let base = 8 + index * 20
                let cpu = try uint32(data, at: base, bigEndian: bigEndian)
                let offset = Int(try uint32(data, at: base + 8, bigEndian: bigEndian))
                let size = Int(try uint32(data, at: base + 12, bigEndian: bigEndian))
                guard offset >= 8 + count * 20, size >= 32, offset <= data.count, size <= data.count - offset else {
                    throw Error.invalidFile
                }
                return Slice(cpu: cpu, offset: offset, size: size)
            }
        }
        guard try uint32(data, at: 0) == MH_MAGIC_64 else { throw Error.invalidFile }
        return [Slice(cpu: try uint32(data, at: 4), offset: 0, size: data.count)]
    }

    private static func fileOffset(in data: Data, slice: Slice, entry: Config.Entry) throws -> Int {
        let base = slice.offset
        guard slice.size >= 32,
              try uint32(data, at: base) == MH_MAGIC_64,
              try uint32(data, at: base + 4) == slice.cpu else { throw Error.invalidFile }
        let count = Int(try uint32(data, at: base + 16))
        let commandSize = Int(try uint32(data, at: base + 20))
        guard commandSize <= slice.size - 32, count <= commandSize / 8 else { throw Error.invalidFile }
        let commandEnd = base + 32 + commandSize
        var cursor = base + 32
        var result: Int?
        for _ in 0..<count {
            guard cursor <= commandEnd - 8 else { throw Error.invalidFile }
            let command = try uint32(data, at: cursor)
            let size = Int(try uint32(data, at: cursor + 4))
            guard size >= 8, size <= commandEnd - cursor else { throw Error.invalidFile }
            if command == LC_SEGMENT_64 {
                guard size >= 72 else { throw Error.invalidFile }
                let vmaddr = try uint64(data, at: cursor + 24)
                let vmsize = try uint64(data, at: cursor + 32)
                let fileoff = try uint64(data, at: cursor + 40)
                let filesize = try uint64(data, at: cursor + 48)
                let length = UInt64(entry.asm.count)
                guard fileoff <= UInt64(slice.size), filesize <= UInt64(slice.size) - fileoff else {
                    throw Error.invalidFile
                }
                if entry.addr >= vmaddr {
                    let delta = entry.addr - vmaddr
                    if delta < vmsize, delta <= filesize, length <= filesize - delta, length <= vmsize - delta {
                        guard result == nil else { throw Error.invalidFile }
                        result = base + Int(fileoff + delta)
                    }
                }
            }
            cursor += size
        }
        guard let result else { throw Error.vaNotFound(arch: entry.arch.rawValue, va: entry.addr) }
        return result
    }

    private static func uint32(_ data: Data, at offset: Int, bigEndian: Bool = false) throws -> UInt32 {
        guard offset >= 0, offset <= data.count, 4 <= data.count - offset else { throw Error.invalidFile }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }

    private static func uint64(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count, 8 <= data.count - offset else { throw Error.invalidFile }
        return UInt64(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })
    }
}

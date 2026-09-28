//
//  Config.swift
//  WeChatTweak
//
//  Created by Sunny Young on 2025/12/5.
//

import Foundation
import MachO

struct Config: Decodable {
    enum Arch: String, Decodable {
        case arm64
        case x86_64

        var cpu: UInt32 {
            switch self {
            case .arm64:
                return UInt32(CPU_TYPE_ARM64)
            case .x86_64:
                return UInt32(CPU_TYPE_X86_64)
            }
        }
    }

    struct Entry: Decodable {
        let arch: Arch
        let addr: UInt64
        let asm: Data
        let expected: [Data]?

        private enum CodingKeys: CodingKey {
            case arch
            case addr
            case asm
            case expected
        }

        init(from decoder: any Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            self.arch = try container.decode(Arch.self, forKey: .arch)
            self.addr = try {
                let hex = try container.decode(String.self, forKey: .addr)
                guard let value = UInt64(hex, radix: 16) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: CodingKeys.addr,
                        in: container,
                        debugDescription: "Invalid Entry.addr"
                    )
                }
                return value
            }()
            self.asm = try {
                let hex = try container.decode(String.self, forKey: .asm)
                guard let value = Data(hex: hex) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: CodingKeys.asm,
                        in: container,
                        debugDescription: "Invalid Entry.asm"
                    )
                }
                return value
            }()
            guard !asm.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .asm, in: container, debugDescription: "Empty patch")
            }
            if container.contains(.expected) {
                let values: [String]
                let replacementLength = asm.count
                if let value = try? container.decode(String.self, forKey: .expected) {
                    values = [value]
                } else {
                    values = try container.decode([String].self, forKey: .expected)
                }
                let bytes = values.compactMap(Data.init(hex:))
                guard !values.isEmpty, bytes.count == values.count,
                      bytes.allSatisfy({ $0.count == replacementLength }) else {
                    throw DecodingError.dataCorruptedError(forKey: .expected, in: container, debugDescription: "Every expected byte pattern must match patch length")
                }
                self.expected = bytes
            } else {
                self.expected = nil
            }
        }
    }

    struct Target: Decodable {
        let identifier: String
        let binary: String
        let entries: [Entry]

        private enum CodingKeys: CodingKey {
            case identifier
            case binary
            case entries
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.identifier = try container.decode(String.self, forKey: .identifier)
            self.binary = try container.decodeIfPresent(String.self, forKey: .binary) ?? "Contents/MacOS/WeChat"
            guard !binary.hasPrefix("/"), !binary.split(separator: "/").contains(".."), binary.hasPrefix("Contents/") else {
                throw DecodingError.dataCorruptedError(forKey: .binary, in: container, debugDescription: "Binary must be inside the app's Contents directory")
            }
            self.entries = try container.decode([Entry].self, forKey: .entries)
        }
    }

    let version: String
    let targets: [Target]

    func targets(showRecallNotice: Bool, customRecallLabel: Bool = false) -> [Target]? {
        let recallNoticeTargets = targets.filter { $0.identifier == "revoke-keeptip" }
        let customTargets = targets.filter { $0.identifier == "runtime-tip" }
        guard !(showRecallNotice && customRecallLabel) else { return nil }
        guard !showRecallNotice || !recallNoticeTargets.isEmpty else { return nil }
        guard !customRecallLabel || (!recallNoticeTargets.isEmpty && !customTargets.isEmpty) else { return nil }
        let otherTargets = targets.filter { !["revoke", "revoke-keeptip", "runtime-tip"].contains($0.identifier) }
        if customRecallLabel { return otherTargets + recallNoticeTargets + customTargets }
        return showRecallNotice ? otherTargets + recallNoticeTargets : targets.filter { $0.identifier != "revoke-keeptip" && $0.identifier != "runtime-tip" }
    }

    static func load(url: URL) async throws -> [Config] {
        if url.isFileURL {
            return try JSONDecoder().decode(
                [Config].self,
                from: Data(contentsOf: url)
            )
        } else {
            return try JSONDecoder().decode(
                [Config].self,
                from: try await URLSession.shared.data(from: url).0
            )
        }
    }
}

private extension Data {
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }

        self.init()
        self.reserveCapacity(chars.count / 2)

        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57:  return c - 48       // '0'...'9'
            case 65...70:  return c - 55       // 'A'...'F'
            case 97...102: return c - 87       // 'a'...'f'
            default:       return nil
            }
        }

        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]),
                  let lo = nibble(chars[i + 1]) else { return nil }
            append(hi << 4 | lo)
            i += 2
        }
    }
}

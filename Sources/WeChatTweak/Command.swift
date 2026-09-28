//
//  Command.swift
//
//  Created by Sunny Young.
//

import Foundation

struct Command {
    enum Error: LocalizedError {
        case executing(command: String, status: Int32, output: String)
        case invalidBinaryPath(String)
        case unsupportedArchitecture
        case unsupportedRecallNotice

        var errorDescription: String? {
            switch self {
            case let .executing(command, status, output):
                return "\(command) failed (\(status)): \(output)"
            case let .invalidBinaryPath(path):
                return "Binary path escapes the app bundle: \(path)"
            case .unsupportedArchitecture:
                return "This configuration does not support the current CPU architecture"
            case .unsupportedRecallNotice:
                return "This WeChat build has no verified recall-notice patch"
            }
        }
    }

    static func version(app: URL) async throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["CFBundleVersion"] as? String
    }

    @discardableResult
    static func patch(
        app: URL,
        config: Config,
        dryRun: Bool = false,
        showRecallNotice: Bool = false
    ) async throws -> [URL] {
        guard let targets = config.targets(showRecallNotice: showRecallNotice) else {
            throw Error.unsupportedRecallNotice
        }
        #if arch(arm64)
        let architecture = Config.Arch.arm64
        #else
        let architecture = Config.Arch.x86_64
        #endif
        guard !targets.isEmpty,
              targets.allSatisfy({ $0.entries.contains(where: { $0.arch == architecture }) }) else {
            throw Error.unsupportedArchitecture
        }
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        let groups = Dictionary(grouping: targets, by: \.binary)
        let plans = try groups.keys.sorted().map { path in
            let binary = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard binary.path.hasPrefix(root.path + "/Contents/") else {
                throw Error.invalidBinaryPath(path)
            }
            return try Patcher.prepare(binary: binary, entries: groups[path]!.flatMap(\.entries))
        }
        if !dryRun {
            for plan in plans {
                try Patcher.apply(plan)
            }
        }
        return plans.map(\.binary)
    }

    static func resign(app: URL, binaries: [URL]) async throws {
        try Signing.resign(app: app, binaries: binaries)
    }

    static func execute(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Error.executing(
                command: executable,
                status: process.terminationStatus,
                output: String(decoding: output, as: UTF8.self)
            )
        }
    }
}

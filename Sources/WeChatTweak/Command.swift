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
        case unsupportedRecallMode
        case missingRuntimeDylib(String)
        case invalidWeChatApp

        var errorDescription: String? {
            switch self {
            case let .executing(command, status, output):
                return "\(command) failed (\(status)): \(output)"
            case let .invalidBinaryPath(path):
                return "Binary path escapes the app bundle: \(path)"
            case .unsupportedArchitecture:
                return "This configuration does not support the current CPU architecture"
            case .unsupportedRecallMode:
                return "This WeChat build has no verified patch for the selected recall-label mode"
            case let .missingRuntimeDylib(path):
                return "Runtime injection needs the library at \(path); build it with `swift build --product WeChatTweakRuntime` or pass --runtime-dylib"
            case .invalidWeChatApp:
                return "Runtime injection requires a WeChat app (com.tencent.xinWeChat) with executable WeChat"
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
        showRecallNotice: Bool = false,
        customRecallLabel: Bool = false,
        runtimeDylib: URL? = nil
    ) async throws -> [URL] {
        guard let targets = config.targets(showRecallNotice: showRecallNotice, customRecallLabel: customRecallLabel) else {
            throw Error.unsupportedRecallMode
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
        let runtime = customRecallLabel ? try prepareRuntime(app: root, source: runtimeDylib) : nil
        if !dryRun {
            if let runtime { try copyRuntime(runtime) }
            for plan in plans {
                try Patcher.apply(plan)
            }
            if let runtime { try DylibInjector.apply(runtime.plan) }
        }
        return plans.map(\.binary) + (runtime.map { [$0.destination] } ?? [])
    }

    @discardableResult
    static func injectRuntime(app: URL, runtimeDylib: URL? = nil, dryRun: Bool = false) throws -> [URL] {
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        let data = try Data(contentsOf: root.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let identifier = info?["CFBundleIdentifier"] as? String ?? ""
        guard root.pathExtension == "app",
              info?["CFBundleExecutable"] as? String == "WeChat",
              identifier == "com.tencent.xinWeChat" || identifier.hasPrefix("com.tencent.xinWeChat.antirecall.clone") else {
            throw Error.invalidWeChatApp
        }
        let runtime = try prepareRuntime(app: root, source: runtimeDylib)
        if !dryRun {
            try copyRuntime(runtime)
            try DylibInjector.apply(runtime.plan)
        }
        return [runtime.plan.binary, runtime.destination]
    }

    private struct RuntimeInstallation {
        let source: URL
        let destination: URL
        let plan: DylibInjector.Plan
    }

    private static func prepareRuntime(app: URL, source: URL?) throws -> RuntimeInstallation {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let source = (source ?? executable.deletingLastPathComponent().appendingPathComponent("libWeChatTweakRuntime.dylib"))
            .resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw Error.missingRuntimeDylib(source.path)
        }
        let binary = app.appendingPathComponent("Contents/Resources/wechat.dylib").resolvingSymlinksInPath().standardizedFileURL
        guard binary.path.hasPrefix(app.path + "/Contents/") else {
            throw Error.invalidBinaryPath(binary.path)
        }
        return RuntimeInstallation(
            source: source,
            destination: binary.deletingLastPathComponent().appendingPathComponent("libWeChatTweakRuntime.dylib"),
            plan: try DylibInjector.prepare(binary: binary, installName: "@loader_path/libWeChatTweakRuntime.dylib")
        )
    }

    private static func copyRuntime(_ runtime: RuntimeInstallation) throws {
        guard runtime.source != runtime.destination else { return }
        // Replace the library atomically, including an existing symlink, so a
        // failed copy cannot first delete the previously installed runtime.
        try Data(contentsOf: runtime.source).write(to: runtime.destination, options: .atomic)
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

//
//  main.swift
//
//  Created by Sunny Young.
//

import Foundation
import Dispatch
import ArgumentParser

// MARK: Versions
extension Tweak {
    struct Versions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all supported WeChat versions")

        @OptionGroup
        var options: Tweak.Options

        mutating func run() async throws {
            print("------ Current version ------")
            print(try await Command.version(app: options.app) ?? "unknown")
            print("------ Supported versions ------")
            try await Config.load(url: options.config).forEach({ print($0.version) })
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

// MARK: Patch
extension Tweak {
    struct Patch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Patch WeChat.app")

        @OptionGroup
        var options: Tweak.Options

        @Flag(help: "Validate all patch locations without modifying or signing the app")
        var dryRun = false

        @Flag(help: "Keep recalled messages and show WeChat's recall notice")
        var showRecallNotice = false

        @Flag(help: "Keep recalled messages and show a custom recall label")
        var customRecallLabel = false

        @Option(name: .long, help: "Path to libWeChatTweakRuntime.dylib (defaults to the CLI's directory)")
        var runtimeDylib: String?

        mutating func run() async throws {
            print("------ Version ------")
            let version = try await Command.version(app: options.app)
            print("WeChat version: \(version ?? "unknown")")

            print("------ Config ------")
            guard let config = (try await Config.load(url: options.config)).first(where: { $0.version == version }) else {
                throw Error.unsupportedVersion
            }
            print("Matched config: \(config)")

            print("------ Patch ------")
            let binaries = try await Command.patch(
                app: options.app,
                config: config,
                dryRun: dryRun,
                showRecallNotice: showRecallNotice,
                customRecallLabel: customRecallLabel,
                runtimeDylib: runtimeDylib.map { URL(fileURLWithPath: $0) }
            )
            if dryRun {
                print("Validation passed. No files were modified.")
                Darwin.exit(EXIT_SUCCESS)
            }
            print("Done!")

            print("------ Resign ------")
            try await Command.resign(
                app: options.app,
                binaries: binaries
            )
            print("Done!")

            Darwin.exit(EXIT_SUCCESS)
        }
    }

}

// MARK: Runtime Injection
extension Tweak {
    struct InjectRuntime: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "inject-runtime",
            abstract: "Inject the arm64 runtime and menu marker independently of patch profiles"
        )

        @Option(name: .shortAndLong, help: "Path of WeChat.app")
        var app = "/Applications/WeChat.app"

        @Option(name: .long, help: "Path to libWeChatTweakRuntime.dylib (defaults to the CLI's directory)")
        var runtimeDylib: String?

        @Flag(help: "Validate runtime injection without modifying or signing the app")
        var dryRun = false

        mutating func run() async throws {
            let appURL = URL(fileURLWithPath: app)
            let binaries = try Command.injectRuntime(
                app: appURL,
                runtimeDylib: runtimeDylib.map { URL(fileURLWithPath: $0) },
                dryRun: dryRun
            )
            if dryRun {
                print("Validation passed. No files were modified.")
            } else {
                try await Command.resign(app: appURL, binaries: binaries)
                print("Runtime injected. Fully quit and reopen WeChat to see WeChatTweak ✓.")
                print("Revoke-hook compatibility is shown separately in the menu.")
            }
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

// MARK: Updates
extension Tweak {
    struct Updates: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Inspect or lock a single WeChat app against replacement")

        @Option(name: .shortAndLong, help: "Path of the WeChat.app to protect")
        var app = "/Applications/WeChat.app"

        @Flag(help: "Lock this app's files against changes; unlock before updating or patching")
        var lock = false

        @Flag(help: "Allow changes again by clearing this app's Finder file locks")
        var unlock = false

        @Flag(help: "Validate the requested change without changing any file locks")
        var dryRun = false

        mutating func validate() throws {
            guard !(lock && unlock) else { throw ValidationError("Choose either --lock or --unlock") }
            guard !dryRun || lock || unlock else { throw ValidationError("Use --dry-run with --lock or --unlock") }
        }

        mutating func run() throws {
            let plan = try UpdateLock.prepare(app: URL(fileURLWithPath: app))
            print("WeChat app: \(plan.app.path)")
            if lock || unlock {
                try UpdateLock.apply(plan, locked: lock, dryRun: dryRun)
                if dryRun {
                    print("Validation passed. No file locks were changed.")
                } else {
                    print(lock ? "App files locked. Unlock before updating, patching, moving or deleting this app." : "App file locks cleared.")
                }
            }
            let current = try UpdateLock.prepare(app: plan.app)
            let state = current.lockedCount == 0 ? "unlocked" : current.lockedCount == current.items.count ? "locked" : "partially locked"
            print("Update protection: \(state) (\(current.lockedCount)/\(current.items.count) files and directories)")
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

// MARK: Tweak
struct Tweak: AsyncParsableCommand {
    enum Error: LocalizedError {
        case invalidApp
        case invalidConfig
        case invalidVersion
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .invalidApp:
                return "Invalid app path"
            case .invalidConfig:
                return "Invalid patch config"
            case .invalidVersion:
                return "Invalid app version"
            case .unsupportedVersion:
                return "Unsupported WeChat version"
            }
        }
    }

    struct Options: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Path of WeChat.app",
            transform: {
                guard FileManager.default.fileExists(atPath: $0) else {
                    throw Error.invalidApp
                }
                return URL(fileURLWithPath: $0)
            }
        )
        var app: URL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)

        @Option(
            name: .shortAndLong,
            help: "Local path or Remote URL of config.json",
            transform: {
                if FileManager.default.fileExists(atPath: $0) {
                    return URL(fileURLWithPath: $0)
                } else {
                    guard let url = URL(string: $0) else {
                        throw Error.invalidConfig
                    }
                    return url
                }
            }
        )
        var config: URL = URL(string:"https://raw.githubusercontent.com/sunnyyoung/WeChatTweak/refs/heads/master/config.json")!
    }

    static let configuration = CommandConfiguration(
        commandName: "wechattweak",
        abstract: "A command-line tool for tweaking WeChat.",
        subcommands: [
            Versions.self,
            Patch.self,
            InjectRuntime.self,
            Updates.self
        ]
    )

    mutating func run() async throws {
        print(Tweak.helpMessage())
        Darwin.exit(EXIT_SUCCESS)
    }
}

Task {
    await Tweak.main()
}

Dispatch.dispatchMain()

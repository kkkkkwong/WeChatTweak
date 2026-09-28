import Foundation
import Security

struct Signing {
    enum Error: LocalizedError {
        case inspection(String, OSStatus)
        case entitlementsChanged(String)

        var errorDescription: String? {
            switch self {
            case let .inspection(path, status):
                return "Cannot inspect signing information for \(path): \(status)"
            case let .entitlementsChanged(path):
                return "Signing did not preserve the required entitlements for \(path)"
            }
        }
    }

    // Developer capabilities require a provisioning profile and cannot be claimed
    // by our ad-hoc signature. Keep sandbox, app-group, device and file permissions.
    static func adHocEntitlements(_ original: [String: Any]) -> [String: Any] {
        guard !original.isEmpty else { return original }
        var result = original.filter { !$0.key.hasPrefix("com.apple.developer.") }
        result["com.apple.security.cs.disable-library-validation"] = true
        result["com.apple.security.cs.allow-unsigned-executable-memory"] = true
        return result
    }

    static func entitlements(at url: URL) throws -> [String: Any] {
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard createStatus == errSecSuccess, let code else {
            throw Error.inspection(url.path, createStatus)
        }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let information else {
            throw Error.inspection(url.path, status)
        }
        let dictionary = information as NSDictionary
        return dictionary[kSecCodeInfoEntitlementsDict] as? [String: Any] ?? [:]
    }

    static func resign(app: URL, binaries: [URL]) throws {
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        let containers = try bundleContainers(in: root)
        let executablePaths = Set(containers.compactMap { Bundle(url: $0)?.executableURL?.resolvingSymlinksInPath().path })
        var candidates = Set(containers)
        for binary in binaries {
            let binary = binary.resolvingSymlinksInPath().standardizedFileURL
            if !executablePaths.contains(binary.path) { candidates.insert(binary) }
        }
        // Inspect bare executables too: previous --deep signing may have retained
        // developer entitlements on one of these helper processes.
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      !executablePaths.contains(url.path) else { continue }
                if let profile = try? entitlements(at: url), !profile.isEmpty {
                    candidates.insert(url)
                }
            }
        }
        let snapshots = try candidates.map { url in
            (url: url, entitlements: adHocEntitlements(try entitlements(at: url)))
        }.sorted {
            if $0.url.pathComponents.count != $1.url.pathComponents.count {
                return $0.url.pathComponents.count > $1.url.pathComponents.count
            }
            return $0.url.path < $1.url.path
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("wechattweak-sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let plist = temporary.appendingPathComponent("entitlements.plist")
        for snapshot in snapshots {
            var arguments = ["--force", "--sign", "-", "--preserve-metadata=identifier,flags,runtime"]
            if !snapshot.entitlements.isEmpty {
                let data = try PropertyListSerialization.data(fromPropertyList: snapshot.entitlements, format: .xml, options: 0)
                try data.write(to: plist, options: .atomic)
                arguments += ["--entitlements", plist.path]
                if #available(macOS 15, *) { arguments.append("--force-library-entitlements") }
            }
            arguments.append(snapshot.url.path)
            try Command.execute("/usr/bin/codesign", arguments: arguments)
        }
        for snapshot in snapshots {
            let actual = try entitlements(at: snapshot.url)
            guard NSDictionary(dictionary: actual).isEqual(to: snapshot.entitlements) else {
                throw Error.entitlementsChanged(snapshot.url.path)
            }
        }
        // Do not clear unrelated xattrs: some nested resources store signatures there.
        _ = try? Command.execute("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", root.path])
        try Command.execute("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", root.path])
    }

    private static func bundleContainers(in root: URL) throws -> [URL] {
        var result = [root]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return result
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true,
               ["app", "appex", "xpc", "framework"].contains(url.pathExtension) {
                result.append(url)
            }
        }
        return result
    }
}

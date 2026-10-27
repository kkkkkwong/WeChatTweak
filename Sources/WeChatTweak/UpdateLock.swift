import Darwin
import Foundation

struct UpdateLock {
    enum Error: LocalizedError {
        case invalidApp
        case sharedFile(String)
        case administratorRequired
        case changedSinceInspection(String)
        case systemCall(String, Int32)
        case rollbackFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidApp:
                return "Select a WeChat .app bundle (com.tencent.xinWeChat)"
            case let .sharedFile(path):
                return "Cannot lock a hard-linked file that may be shared outside WeChat: \(path)"
            case .administratorRequired:
                return "This WeChat app is owned by another user; run the same command with sudo"
            case let .changedSinceInspection(path):
                return "The app changed during inspection; retry after quitting WeChat: \(path)"
            case let .systemCall(path, code):
                let message = "Cannot change update protection at \(path): \(String(cString: strerror(code)))"
                if code == EPERM, geteuid() == 0 {
                    return message + ". Run from a terminal allowed in System Settings > Privacy & Security > App Management; administrator privileges alone may not grant access to other apps"
                }
                return message
            case let .rollbackFailed(path):
                return "Could not restore all file locks after a failure; inspect update protection and unlock the app: \(path)"
            }
        }
    }

    struct Item {
        let url: URL
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let flags: UInt32

        var locked: Bool { flags & UInt32(UF_IMMUTABLE) != 0 }
    }

    struct Plan {
        let app: URL
        let items: [Item]

        var lockedCount: Int { items.filter(\.locked).count }
    }

    static func prepare(app: URL) throws -> Plan {
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        guard root.pathExtension == "app",
              let data = try? Data(contentsOf: root.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.tencent.xinWeChat",
              info["CFBundleExecutable"] as? String == "WeChat" else {
            throw Error.invalidApp
        }
        var urls = [root]
        var enumerationError: (any Swift.Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw Error.invalidApp }
        for case let url as URL in enumerator { urls.append(url) }
        if let enumerationError { throw enumerationError }
        let items = try urls.compactMap { url -> Item? in
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { throw Error.systemCall(url.path, errno) }
            let type = metadata.st_mode & S_IFMT
            // A locked parent protects symlink entries. Never follow their targets,
            // which can point to shared frameworks or files outside this app.
            if type == S_IFLNK { return nil }
            guard type == S_IFREG || type == S_IFDIR else { throw Error.invalidApp }
            guard type != S_IFREG || metadata.st_nlink == 1 else { throw Error.sharedFile(url.path) }
            return Item(url: url, device: metadata.st_dev, inode: metadata.st_ino,
                        owner: metadata.st_uid, flags: metadata.st_flags)
        }
        return Plan(app: root, items: items)
    }

    static func apply(_ plan: Plan, locked: Bool, dryRun: Bool = false) throws {
        let changes = plan.items.filter { $0.locked != locked }.sorted {
            let left = $0.url.pathComponents.count
            let right = $1.url.pathComponents.count
            // Lock children first; unlock parents first.
            if left != right { return locked ? left > right : left < right }
            return $0.url.path < $1.url.path
        }
        guard geteuid() == 0 || changes.allSatisfy({ $0.owner == geteuid() }) else {
            throw Error.administratorRequired
        }
        // Check every item before changing any metadata, including a dry run.
        for item in plan.items {
            try withFile(item) { _ in }
        }
        if dryRun { return }

        var applied: [Item] = []
        do {
            for item in changes {
                try withFile(item) { fd in
                    let flags = locked ? item.flags | UInt32(UF_IMMUTABLE) : item.flags & ~UInt32(UF_IMMUTABLE)
                    guard fchflags(fd, flags) == 0 else { throw Error.systemCall(item.url.path, errno) }
                }
                applied.append(item)
            }
        } catch {
            // Restore only the immutable bit we changed, preserving other flags.
            var rollbackFailed = false
            for item in applied.reversed() {
                do {
                    try withFile(item, checkFlags: false) { fd in
                        var metadata = stat()
                        guard fstat(fd, &metadata) == 0 else { throw Error.systemCall(item.url.path, errno) }
                        let flags = (metadata.st_flags & ~UInt32(UF_IMMUTABLE)) | (item.flags & UInt32(UF_IMMUTABLE))
                        guard fchflags(fd, flags) == 0 else { throw Error.systemCall(item.url.path, errno) }
                    }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw Error.rollbackFailed(plan.app.path) }
            throw error
        }
    }

    private static func withFile(_ item: Item, checkFlags: Bool = true, body: (Int32) throws -> Void) throws {
        let fd = open(item.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Error.systemCall(item.url.path, errno) }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw Error.systemCall(item.url.path, errno) }
        guard metadata.st_dev == item.device, metadata.st_ino == item.inode,
              !checkFlags || metadata.st_flags == item.flags else {
            throw Error.changedSinceInspection(item.url.path)
        }
        try body(fd)
    }
}

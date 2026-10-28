import Foundation

/// Decides whether a Python interpreter is safe to launch: after resolving
/// symlinks, the binary and every directory above it must be owned by root or
/// the current user and must not be writable by everyone. This stops a
/// world-writable or foreign-owned location from hijacking the kernel.
public enum InterpreterTrust {
    public struct Owner: Equatable {
        public let uid: uid_t
        public let mode: mode_t

        public init(uid: uid_t, mode: mode_t) {
            self.uid = uid
            self.mode = mode
        }
    }

    public static func isTrusted(path: String, currentUID: uid_t = getuid(),
                                 lookup: (String) -> Owner? = ownerOf) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var current = resolved
        while true {
            guard let owner = lookup(current) else { return false }
            let ownedSafely = owner.uid == 0 || owner.uid == currentUID
            // Any world-writable step (even a sticky one like /tmp) lets others plant files.
            let worldWritable = owner.mode & S_IWOTH != 0
            if !ownedSafely || worldWritable { return false }
            if current == "/" { return true }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
    }

    public static func ownerOf(_ path: String) -> Owner? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Owner(uid: info.st_uid, mode: info.st_mode)
    }
}

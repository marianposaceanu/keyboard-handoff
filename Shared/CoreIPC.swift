import Darwin
import Foundation

enum IPCError: LocalizedError {
    case offline
    case message(String)
    var errorDescription: String? {
        switch self {
        case .offline: "The core is stopped."
        case .message(let text): text
        }
    }
}

struct Choice: Codable, Equatable {
    let id: String
    let name: String
}

struct Snapshot: Codable, Equatable {
    var status = ""
    var peer: String?
    var keyboard: String?
    var peers: [Choice] = []
    var keyboards: [Choice] = []
    var busy = false
    var reachable = false
    var shortcut = false
    var error: String?
}

enum Command: Codable {
    case status, send, stop, refresh, forget, clear
    case trust(String), select(String)
}

struct Request: Codable {
    let version: Int
    let command: Command
}
enum CoreIPC {
    static func socketPath() throws -> String {
        var buffer = [CChar](repeating: 0, count: 104)
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard count > 0, count + "keyboard-handoff".utf8.count < buffer.count else {
            throw IPCError.message("Cannot access the private core socket directory.")
        }
        let directory = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            + "keyboard-handoff"
        guard mkdir(directory, 0o700) == 0 || errno == EEXIST else {
            throw IPCError.message("Cannot create the private core socket directory.")
        }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == getuid(), info.st_mode & 0o077 == 0
        else { throw IPCError.message("Unsafe core socket directory.") }
        let path = directory + "/core.sock"
        guard path.utf8.count < 104 else { throw IPCError.message("Core socket path is too long.") }
        return path
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < 104, !path.utf8.contains(0) else { throw IPCError.message("Invalid core socket path.") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: Array(path.utf8) + [0])
        }
        return address
    }

    static func options(_ fd: Int32, receiveTimeout: Int = 30) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, 4)
        var timeout = timeval(tv_sec: receiveTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout.tv_sec = 30
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func transfer(_ fd: Int32, bytes: inout [UInt8], writing: Bool) -> Bool {
        bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let pointer = buffer.baseAddress!.advanced(by: offset)
                let count =
                    writing ? send(fd, pointer, buffer.count - offset, 0) : recv(fd, pointer, buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        var length = [UInt8](repeating: 0, count: 4)
        guard transfer(fd, bytes: &length, writing: false) else { throw IPCError.message("Incomplete core message.") }
        let size = length.reduce(0) { $0 * 256 + Int($1) }
        guard (1...65536).contains(size) else { throw IPCError.message("Invalid core message size.") }
        var bytes = [UInt8](repeating: 0, count: size)
        guard transfer(fd, bytes: &bytes, writing: false) else { throw IPCError.message("Incomplete core message.") }
        return try JSONDecoder().decode(type, from: Data(bytes))
    }

    static func write<T: Encodable>(_ value: T, to fd: Int32) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65536 else { throw IPCError.message("Core message exceeds 64 KiB.") }
        var length = UInt32(data.count).bigEndian
        var bytes = withUnsafeBytes(of: &length) { Array($0) } + data
        guard transfer(fd, bytes: &bytes, writing: true) else { throw IPCError.message("Core connection closed.") }
    }

    static func request(_ command: Command, path: String? = nil) throws -> Snapshot {
        var address = try address(path ?? socketPath())
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.message("Cannot open the core socket.") }
        defer { close(fd) }
        options(fd, receiveTimeout: 4)
        try withUnsafePointer(to: &address) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 else {
                    if errno == ENOENT || errno == ECONNREFUSED { throw IPCError.offline }
                    throw IPCError.message("Cannot connect to the core.")
                }
            }
        }
        guard sameUser(fd) else { throw IPCError.message("The core belongs to another user.") }
        try write(Request(version: 1, command: command), to: fd)
        let snapshot = try read(Snapshot.self, from: fd)
        if let error = snapshot.error { throw IPCError.message(error) }
        return snapshot
    }
}

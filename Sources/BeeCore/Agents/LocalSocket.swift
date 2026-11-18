import Darwin
import Foundation

/// The private socket between the MCP relay and the application: a Unix socket in Bee's data folder,
/// open to its owner only, carrying one JSON message per line.
public enum LocalSocket {
    /// Where the application listens.
    public static func path(inDataDirectory directory: URL) -> String {
        directory.appendingPathComponent("agent.sock").path
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        return address
    }

    private static func with<Result>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// Connects to the application. `nil` when nothing listens there.
    public static func connect(to path: String) -> Int32? {
        guard let address = address(path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        guard with(address, { Darwin.connect(descriptor, $0, $1) }) == 0 else {
            close(descriptor)
            return nil
        }
        quiet(descriptor)
        return descriptor
    }

    /// A write to an end that is gone fails instead of ending the program with SIGPIPE.
    private static func quiet(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Starts listening at `path`, replacing a socket left by an earlier run. The socket is its owner's
    /// alone before anyone can reach it: nothing connects to a socket that does not listen yet. The mask of
    /// the whole process is left alone, since other threads create files meanwhile.
    public static func listen(at path: String) -> Int32? {
        guard let address = address(path) else { return nil }
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let bound = with(address) { bind(descriptor, $0, $1) }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 8) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Waits for the next connection. `nil` once the listening socket is closed.
    public static func accept(on descriptor: Int32) -> Int32? {
        while true {
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection >= 0 {
                quiet(connection)
                return connection
            }
            // A signal, or a caller that left before being answered: the next one is waited for.
            if errno != EINTR, errno != ECONNABORTED { return nil }
        }
    }

    /// Who is at the other end: the user it runs as, its process and the program that process runs. The
    /// program is asked of the system for that very process, not for whichever process has its number now.
    public static func peer(of descriptor: Int32) -> (user: uid_t, process: pid_t, program: String?)? {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0 else { return nil }
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath_audittoken(&token, &buffer, UInt32(buffer.count))
        let program = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return (user, audit_token_to_pid(token), program)
    }

    /// True once the other end has closed or given up.
    public static func isClosed(_ descriptor: Int32) -> Bool {
        var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&watched, 1, 0) > 0 else { return false }
        if watched.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    /// The arguments a process was started with, the name it was called by first.
    public static func arguments(of process: pid_t) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, process]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return arguments(inProcessArea: Array(buffer.prefix(size)))
    }

    /// Reads the area the system keeps for a process: the number of arguments, the program, then the arguments.
    static func arguments(inProcessArea area: [UInt8]) -> [String]? {
        let header = MemoryLayout<Int32>.size
        guard area.count > header else { return nil }
        let count = area.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0 else { return nil }
        var index = header
        while index < area.count, area[index] != 0 { index += 1 }
        while index < area.count, area[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count), index < area.count {
            let start = index
            while index < area.count, area[index] != 0 { index += 1 }
            arguments.append(String(decoding: area[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(count) ? arguments : nil
    }

    /// The folder a process works in.
    public static func workingDirectory(of process: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(process, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// The path of the program a process runs, as the system knows it.
    public static func programPath(of process: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(process, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The process that started `process`.
    public static func parent(of process: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The name the system keeps for a process and when it started: what is left to tell it by once its
    /// file is gone from the disk and the system no longer says where it came from.
    public static func birth(of process: pid_t) -> (name: String, started: Date)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let long = withUnsafeBytes(of: &info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let short = withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let name = long.isEmpty ? short : long
        guard !name.isEmpty else { return nil }
        let started = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return (name, Date(timeIntervalSince1970: started))
    }

    /// Reads up to the next line break. `nil` when the other end closed, or sent a line larger than `limit`.
    public static func readLine(from descriptor: Int32, limit: Int = 16 * 1024 * 1024) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = read(descriptor, &byte, 1)
            if count <= 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
            if bytes.count > limit { return nil }
        }
    }

    /// Writes one line. False when the other end is gone.
    @discardableResult
    public static func writeLine(_ line: String, to descriptor: Int32) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count <= 0 { return false }
            sent += count
        }
        return true
    }
}

import Darwin
import Foundation
import os

/// Ensures only one runner (`soundlanes run` or the menu bar app) applies routes at a time (SPEC §9, §11 M3).
/// Uses `flock`, so the lock disappears with the process even after `kill -9`.
public final class InstanceLock: Sendable {
    private let descriptor: Int32

    public static var defaultURL: URL { ConfigStore.defaultDirectory.appendingPathComponent("run.lock") }

    /// Returns nil if another process holds the lock. `owner` is recorded for error messages.
    public static func acquire(owner: String, at url: URL = defaultURL) throws -> InstanceLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        ftruncate(descriptor, 0)
        let record = "\(owner) \(getpid())\n"
        _ = record.withCString { write(descriptor, $0, strlen($0)) }
        return InstanceLock(descriptor: descriptor)
    }

    /// Who holds the lock, e.g. "SoundLanes 앱 1234". Best effort.
    public static func currentOwner(at url: URL = defaultURL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

// MARK: - Control socket

/// One JSON line in each direction over a Unix domain socket (SPEC §9).
public struct ControlRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        case status
        /// Re-read `routes.json` (sent by `add` / `remove`).
        case reload
    }

    public var command: Command

    public init(_ command: Command) { self.command = command }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var owner: String?
    public var routes: [RouteStatus]?
    public var error: String?

    public init(ok: Bool, owner: String? = nil, routes: [RouteStatus]? = nil, error: String? = nil) {
        self.ok = ok
        self.owner = owner
        self.routes = routes
        self.error = error
    }
}

public enum ControlError: Error, CustomStringConvertible, Sendable {
    case notRunning
    case io(String)

    public var description: String {
        switch self {
        case .notRunning: "실행 중인 SoundLanes(앱 또는 soundlanes run)가 없습니다."
        case .io(let detail): "실행 중인 인스턴스와 통신하지 못했습니다: \(detail)"
        }
    }
}

public enum ControlSocket {
    public static var defaultURL: URL { ConfigStore.defaultDirectory.appendingPathComponent("run.sock") }

    static func makeAddress(_ url: URL) throws(ControlError) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else { throw .io("socket path too long: \(url.path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }
        return address
    }
}

/// Serves control requests. Create it only while holding `InstanceLock`, since it replaces any stale socket file.
public final class ControlServer: Sendable {
    private let descriptor: Int32
    private let url: URL
    private let source: any DispatchSourceRead

    public init(at url: URL = ControlSocket.defaultURL,
                handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) throws {
        unlink(url.path)
        var address = try ControlSocket.makeAddress(url)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlError.io("socket: \(errno)") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            let code = errno
            close(descriptor)
            throw ControlError.io("bind/listen: \(code)")
        }
        chmod(url.path, 0o600)
        self.descriptor = descriptor
        self.url = url
        let queue = DispatchQueue(label: "com.zinu.soundlanes.control")
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            Self.setTimeout(client)
            Task {
                let response: ControlResponse
                if let line = Self.readLine(client),
                   let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                    response = await handler(request)
                } else {
                    response = ControlResponse(ok: false, error: "bad request")
                }
                Self.writeLine(client, response)
                close(client)
            }
        }
        source.resume()
    }

    public func stop() {
        source.cancel()
        close(descriptor)
        unlink(url.path)
    }

    static func setTimeout(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func readLine(_ descriptor: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 1 << 20 {
            let count = read(descriptor, &byte, 1)
            if count <= 0 { return data.isEmpty ? nil : data }
            if byte == UInt8(ascii: "\n") { return data }
            data.append(byte)
        }
        return nil
    }

    static func writeLine<T: Encodable>(_ descriptor: Int32, _ value: T) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}

public enum ControlClient {
    public static func send(_ request: ControlRequest, to url: URL = ControlSocket.defaultURL) throws -> ControlResponse {
        var address = try ControlSocket.makeAddress(url)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlError.io("socket: \(errno)") }
        defer { close(descriptor) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw ControlError.notRunning }
            throw ControlError.io("connect: \(errno)")
        }
        ControlServer.setTimeout(descriptor)
        ControlServer.writeLine(descriptor, request)
        guard let line = ControlServer.readLine(descriptor) else { throw ControlError.io("no response") }
        do {
            return try JSONDecoder().decode(ControlResponse.self, from: line)
        } catch {
            throw ControlError.io(String(describing: error))
        }
    }
}

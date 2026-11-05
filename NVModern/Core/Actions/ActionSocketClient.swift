import Darwin
import Foundation

/// Blocking Unix-domain client for the nvModern action socket.
///
/// Do not call `invoke` on the main actor while the app's socket server is
/// handling the same connection; the server hops to the main actor to execute.
struct ActionSocketClient: Sendable {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case appNotRunning(socketPath: String)
        case connectionFailed(String)
        case emptyResponse
        case decodeFailed(String)
        case pathTooLong(String)

        var errorDescription: String? {
            switch self {
            case .appNotRunning(let socketPath):
                return "nvModern is not running (socket missing: \(socketPath))"
            case .connectionFailed(let message):
                return "Could not connect to the action socket: \(message)"
            case .emptyResponse:
                return "The action socket closed before returning a response"
            case .decodeFailed(let message):
                return "Could not decode action response: \(message)"
            case .pathTooLong(let path):
                return "Socket path is too long for AF_UNIX: \(path)"
            }
        }
    }

    var socketURL: URL
    var timeout: TimeInterval

    init(
        socketURL: URL = ActionSocketConfiguration.defaultSocketURL(),
        timeout: TimeInterval = 15
    ) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    func invoke(_ request: ActionRequest) throws -> ActionResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(request)
        guard var line = String(data: payload, encoding: .utf8) else {
            throw Error.decodeFailed("Could not encode request as UTF-8")
        }
        line += "\n"

        let responseLine = try send(line: line)
        let trimmed = responseLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Error.emptyResponse
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw Error.decodeFailed("Response was not UTF-8")
        }

        do {
            return try JSONDecoder().decode(ActionResponse.self, from: data)
        } catch {
            throw Error.decodeFailed(error.localizedDescription)
        }
    }

    private func send(line: String) throws -> String {
        let path = socketURL.path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Error.connectionFailed("socket (errno=\(errno))")
        }
        defer { close(fd) }

        try disableSIGPIPE(on: fd)
        try applyTimeouts(to: fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxLength else {
            throw Error.pathTooLong(path)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBytes { source in
                memcpy(destination.baseAddress, source.baseAddress, pathBytes.count)
            }
        }

        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }

        if connected != 0 {
            switch errno {
            case ENOENT, ECONNREFUSED, ENOTSOCK, ECONNRESET:
                throw Error.appNotRunning(socketPath: path)
            default:
                throw Error.connectionFailed("connect (errno=\(errno))")
            }
        }

        var remaining = Array(line.utf8)
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            if written <= 0 {
                if errno == EINTR {
                    continue
                }
                throw Error.connectionFailed("write (errno=\(errno))")
            }
            remaining.removeFirst(Int(written))
        }

        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = read(fd, &chunk, chunk.count)
            if readCount > 0 {
                collected.append(chunk, count: Int(readCount))
                if let newline = collected.firstIndex(of: 0x0A) {
                    return String(decoding: collected.prefix(upTo: newline), as: UTF8.self)
                }
                continue
            }
            if readCount == 0 {
                if collected.isEmpty {
                    throw Error.emptyResponse
                }
                return String(decoding: collected, as: UTF8.self)
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                throw Error.connectionFailed("timed out waiting for a response")
            }
            throw Error.connectionFailed("read (errno=\(errno))")
        }
    }

    private func applyTimeouts(to fileDescriptor: Int32) throws {
        let seconds = max(1, Int(self.timeout.rounded(.up)))
        var timeoutValue = timeval(tv_sec: __darwin_time_t(seconds), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, size) == 0 else {
            throw Error.connectionFailed("setsockopt(SO_RCVTIMEO) (errno=\(errno))")
        }
        guard setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, size) == 0 else {
            throw Error.connectionFailed("setsockopt(SO_SNDTIMEO) (errno=\(errno))")
        }
    }

    private func disableSIGPIPE(on fileDescriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw Error.connectionFailed("setsockopt(SO_NOSIGPIPE) (errno=\(errno))")
        }
    }
}

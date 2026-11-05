import Foundation
import Darwin

/// Local automation endpoint for line-delimited JSON action requests over a Unix domain
/// socket. Each request is one UTF-8 JSON line, and each response is one UTF-8 JSON line.
@MainActor
final class ActionSocketServer {
    enum State: Equatable {
        case stopped
        case running(socketPath: String)
        case failed(message: String)
    }

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var runtime: SocketRuntime?

    private(set) var state: State = .stopped
    private(set) var socketURL: URL?
    let executor: ActionExecutor

    init(executor: ActionExecutor? = nil) {
        self.executor = executor ?? ActionExecutor.shared
        encoder.outputFormatting = [.sortedKeys]
    }

    func configure(socketURL: URL?) {
        self.socketURL = socketURL
    }

    func start() {
        stop()

        guard let socketURL else {
            state = .failed(message: "Socket URL is not configured")
            return
        }

        let directoryURL = socketURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let runtime = try SocketRuntime(
                socketURL: socketURL,
                requestHandler: { [weak self] line in
                    guard let self else {
                        return #"{"id":null,"ok":false,"error":{"code":"unavailable","message":"Socket server unavailable","details":{}}}"#
                    }
                    return await self.processIncomingLine(line)
                }
            )
            try runtime.start()
            self.runtime = runtime
            state = .running(socketPath: socketURL.path)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func stop() {
        runtime?.stop()
        runtime = nil
        state = .stopped
    }

    func processIncomingLine(_ line: String) async -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return serializedFallbackErrorResponse(
                ActionResponse.failure(
                    id: nil,
                    error: .decodeFailed("Received empty action request")
                )
            )
        }

        guard let data = trimmed.data(using: .utf8) else {
            return serializedFallbackErrorResponse(
                ActionResponse.failure(
                    id: nil,
                    error: .decodeFailed("Could not decode request as UTF-8")
                )
            )
        }

        let response: ActionResponse
        do {
            let request = try decoder.decode(ActionRequest.self, from: data)
            response = await executor.execute(request.withSocketSource())
        } catch let error as ActionError {
            response = .failure(id: nil, error: error)
        } catch {
            response = .failure(id: nil, error: .decodeFailed(error.localizedDescription))
        }

        return serializedFallbackErrorResponse(response)
    }

    private func serializedFallbackErrorResponse(_ response: ActionResponse) -> String {
        guard let data = try? encoder.encode(response),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"id":null,"ok":false,"error":{"code":"encode_failed","message":"Could not encode action response","details":{}}}"#
        }

        return string
    }
}

private final class SocketRuntime {
    private final class Connection: @unchecked Sendable {
        let fileDescriptor: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        private(set) var isClosed = false

        init(fileDescriptor: Int32, source: DispatchSourceRead) {
            self.fileDescriptor = fileDescriptor
            self.source = source
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(fileDescriptor)
        }
    }

    private let socketURL: URL
    private let requestHandler: (String) async -> String
    private let queue = DispatchQueue(label: "nvmodern.action-socket", qos: .userInitiated)

    private var listeningFileDescriptor: Int32 = -1
    private var listeningSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var isStopped = false

    init(socketURL: URL, requestHandler: @escaping (String) async -> String) throws {
        self.socketURL = socketURL
        self.requestHandler = requestHandler
    }

    deinit {
        stop()
    }

    func start() throws {
        try removeExistingSocketIfNeeded()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketRuntimeError.systemCallFailed("socket")
        }

        listeningFileDescriptor = fd
        try setNonBlocking(fd)
        try bindSocket(fd, to: socketURL.path)

        guard listen(fd, SOMAXCONN) == 0 else {
            let error = SocketRuntimeError.systemCallFailed("listen")
            close(fd)
            listeningFileDescriptor = -1
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listeningFileDescriptor >= 0 {
                close(self.listeningFileDescriptor)
                self.listeningFileDescriptor = -1
            }
        }
        listeningSource = source
        source.resume()
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true

            for connection in connections.values {
                connection.source.cancel()
                connection.close()
            }
            connections.removeAll()

            listeningSource?.cancel()
            listeningSource = nil

            if listeningFileDescriptor >= 0 {
                close(listeningFileDescriptor)
                listeningFileDescriptor = -1
            }

            unlink(socketURL.path)
        }
    }

    private func acceptPendingConnections() {
        while true {
            let clientFD = accept(listeningFileDescriptor, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    return
                }
                return
            }

            do {
                try setNonBlocking(clientFD)
                try disableSIGPIPE(clientFD)
                let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
                let connection = Connection(fileDescriptor: clientFD, source: source)
                connections[clientFD] = connection

                source.setEventHandler { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.readAvailableData(from: connection)
                }
                source.setCancelHandler { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.connections.removeValue(forKey: connection.fileDescriptor)
                    connection.close()
                }
                source.resume()
            } catch {
                close(clientFD)
            }
        }
    }

    private func readAvailableData(from connection: Connection) {
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let readCount = read(connection.fileDescriptor, &buffer, buffer.count)
            if readCount > 0 {
                connection.buffer.append(buffer, count: Int(readCount))
                drainLines(from: connection)
                continue
            }

            if readCount == 0 {
                connection.source.cancel()
                return
            }

            if errno == EWOULDBLOCK || errno == EAGAIN {
                return
            }

            connection.source.cancel()
            return
        }
    }

    private func drainLines(from connection: Connection) {
        while let newlineIndex = connection.buffer.firstIndex(of: 0x0A) {
            let lineData = connection.buffer.prefix(upTo: newlineIndex)
            connection.buffer.removeSubrange(...newlineIndex)

            guard let line = String(data: lineData, encoding: .utf8) else {
                Task { [weak self] in
                    guard let self else { return }
                    await self.sendResponse(
                        #"{"id":null,"ok":false,"error":{"code":"decode_failed","message":"Could not decode request line as UTF-8","details":{}}}"#,
                        to: connection
                    )
                }
                continue
            }

            Task { [weak self] in
                guard let self else { return }
                let response = await self.requestHandler(line)
                await self.sendResponse(response, to: connection)
            }
        }
    }

    @MainActor
    private func sendResponse(_ response: String, to connection: Connection) {
        let message = response + "\n"
        queue.async {
            guard !connection.isClosed else { return }
            var remaining = Array(message.utf8)
            while !remaining.isEmpty {
                let written = remaining.withUnsafeBytes { buffer in
                    write(connection.fileDescriptor, buffer.baseAddress, buffer.count)
                }

                if written <= 0 {
                    if errno == EWOULDBLOCK || errno == EAGAIN {
                        usleep(1_000)
                        continue
                    }
                    connection.source.cancel()
                    return
                }

                remaining.removeFirst(Int(written))
            }
        }
    }

    private func bindSocket(_ fd: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8CString)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxLength else {
            throw SocketRuntimeError.pathTooLong(path)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBytes { source in
                memcpy(destination.baseAddress, source.baseAddress, pathBytes.count)
            }
        }

        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, addressLength)
            }
        }

        guard result == 0 else {
            let error = SocketRuntimeError.systemCallFailed("bind")
            close(fd)
            listeningFileDescriptor = -1
            throw error
        }

        chmod(path, S_IRUSR | S_IWUSR)
    }

    private func setNonBlocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            throw SocketRuntimeError.systemCallFailed("fcntl(F_GETFL)")
        }
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SocketRuntimeError.systemCallFailed("fcntl(F_SETFL)")
        }
    }

    private func disableSIGPIPE(_ fileDescriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw SocketRuntimeError.systemCallFailed("setsockopt(SO_NOSIGPIPE)")
        }
    }

    private func removeExistingSocketIfNeeded() throws {
        if FileManager.default.fileExists(atPath: socketURL.path) {
            guard unlink(socketURL.path) == 0 else {
                throw SocketRuntimeError.systemCallFailed("unlink")
            }
        }
    }
}

private enum SocketRuntimeError: LocalizedError {
    case systemCallFailed(String)
    case pathTooLong(String)

    var errorDescription: String? {
        switch self {
        case .systemCallFailed(let operation):
            return "Socket operation failed: \(operation) (errno=\(errno))"
        case .pathTooLong(let path):
            return "Socket path is too long for AF_UNIX: \(path)"
        }
    }
}

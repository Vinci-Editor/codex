//
//  Created by Ethan Lipnik
//

import Foundation
import Network

internal final class CodexLoopbackCallbackServer: @unchecked Sendable {
    private let publicHost: String
    private let port: UInt16
    private let path: String
    private let timeout: Duration
    private let queue = DispatchQueue(label: "dev.codex.browser-auth")
    private let stateLock = NSLock()

    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didDeliverCallback = false

    init(publicHost: String, port: UInt16, path: String, timeout: Duration) throws {
        self.publicHost = publicHost
        self.port = port
        self.path = path
        self.timeout = timeout
    }

    func start() async throws -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CodexBrowserAuthError.invalidCallbackURL
        }
        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else {
                    return
                }
                switch state {
                case .ready:
                    self.timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: self?.timeout ?? .seconds(0))
                        self?.resumeCallback(with: .failure(CodexBrowserAuthError.callbackTimedOut))
                    }
                    self.resumeStart(
                        with: .success("http://\(self.publicHost):\(self.port)\(self.path)")
                    )
                case .failed(let error):
                    self.resumeStart(with: .failure(error))
                    self.resumeCallback(with: .failure(error))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let pendingResult: Result<URL, Error>? = withStateLock {
                if let pendingCallbackResult {
                    self.pendingCallbackResult = nil
                    didDeliverCallback = true
                    return pendingCallbackResult
                }
                callbackContinuation = continuation
                return nil
            }

            guard let pendingResult else {
                return
            }
            switch pendingResult {
            case .success(let callbackURL):
                continuation.resume(returning: callbackURL)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() {
        let state = withStateLock { () -> (Task<Void, Never>?, NWListener?) in
            let state = (timeoutTask, listener)
            timeoutTask = nil
            listener = nil
            startContinuation = nil
            callbackContinuation = nil
            pendingCallbackResult = nil
            didDeliverCallback = true
            return state
        }
        state.0?.cancel()
        state.1?.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.resumeCallback(with: .failure(error))
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if nextBuffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                self.processRequestData(nextBuffer, on: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func processRequestData(_ data: Data, on connection: NWConnection) {
        let requestText = String(decoding: data, as: UTF8.self)
        let requestLine = requestText.components(separatedBy: "\r\n").first ?? ""
        let pathWithQuery = requestLine
            .split(separator: " ", omittingEmptySubsequences: true)
            .dropFirst()
            .first
            .map(String.init) ?? ""

        guard
            !pathWithQuery.isEmpty,
            let callbackURL = URL(string: "http://\(publicHost):\(port)\(pathWithQuery)"),
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            components.path == path
        else {
            sendResponse(statusLine: "HTTP/1.1 404 Not Found", body: "Not found", on: connection)
            return
        }

        sendResponse(statusLine: "HTTP/1.1 200 OK", body: "Login complete. You can return to the app.", on: connection)
        resumeCallback(with: .success(callbackURL))
    }

    private func sendResponse(statusLine: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let header = [
            statusLine,
            "Content-Type: text/plain; charset=UTF-8",
            "Connection: close",
            "Content-Length: \(bodyData.count)",
            "",
            "",
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func resumeStart(with result: Result<String, Error>) {
        let continuation = withStateLock {
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        switch result {
        case .success(let redirectURI):
            continuation?.resume(returning: redirectURI)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func resumeCallback(with result: Result<URL, Error>) {
        let state = withStateLock { () -> (CheckedContinuation<URL, Error>?, Task<Void, Never>?, NWListener?) in
            guard !didDeliverCallback else {
                return (nil, nil, nil)
            }
            didDeliverCallback = true
            let continuation = callbackContinuation
            callbackContinuation = nil
            if continuation == nil {
                pendingCallbackResult = result
            }
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            let listener = self.listener
            self.listener = nil
            return (continuation, timeoutTask, listener)
        }
        state.1?.cancel()
        state.2?.cancel()
        switch result {
        case .success(let callbackURL):
            state.0?.resume(returning: callbackURL)
        case .failure(let error):
            state.0?.resume(throwing: error)
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

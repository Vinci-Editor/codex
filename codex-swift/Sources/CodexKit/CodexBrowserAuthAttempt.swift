//
//  Created by Ethan Lipnik
//

import AuthenticationServices
import Foundation

internal final class CodexWebAuthenticationCompletionHandler: @unchecked Sendable {
    weak var attempt: CodexBrowserAuthAttempt?

    init(attempt: CodexBrowserAuthAttempt) {
        self.attempt = attempt
    }

    nonisolated func handle(callbackURL: URL?, error: Error?) {
        let result: Result<URL, Error>
        if let callbackURL {
            result = .success(callbackURL)
        } else if let authError = error as? ASWebAuthenticationSessionError,
                  authError.code == .canceledLogin {
            result = .failure(CodexBrowserAuthError.cancelled)
        } else if let error {
            result = .failure(error)
        } else {
            result = .failure(CodexBrowserAuthError.cancelled)
        }

        Task { @MainActor [weak self] in
            self?.attempt?.finish(result)
        }
    }
}

@MainActor
internal final class CodexBrowserAuthAttempt {
    var session: ASWebAuthenticationSession?
    var callbackTask: Task<Void, Never>?
    var completionHandler: CodexWebAuthenticationCompletionHandler?

    private let callbackServer: CodexLoopbackCallbackServer
    private let continuation: CheckedContinuation<URL, Error>
    private var didFinish = false

    init(
        callbackServer: CodexLoopbackCallbackServer,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.callbackServer = callbackServer
        self.continuation = continuation
    }

    func finish(_ result: Result<URL, Error>) {
        guard !didFinish else {
            return
        }
        didFinish = true
        callbackTask?.cancel()
        callbackTask = nil
        callbackServer.stop()
        session?.cancel()
        session = nil
        completionHandler = nil
        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        finish(.failure(CodexBrowserAuthError.cancelled))
    }
}

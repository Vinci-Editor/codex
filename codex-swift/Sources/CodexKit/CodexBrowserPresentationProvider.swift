//
//  Created by Ethan Lipnik
//

import AuthenticationServices
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
internal final class CodexBrowserPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: (@MainActor @Sendable () -> ASPresentationAnchor)?

    init(anchor: (@MainActor @Sendable () -> ASPresentationAnchor)?) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor {
            return anchor()
        }
#if canImport(UIKit)
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) {
            return window
        }
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            return ASPresentationAnchor(windowScene: scene)
        }
        preconditionFailure("CodexBrowserAuthenticator requires a UIWindowScene presentation anchor.")
#else
        return ASPresentationAnchor()
#endif
    }
}

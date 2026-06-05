//
//  Created by Ethan Lipnik
//

import Foundation

internal struct BrowserTokenResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

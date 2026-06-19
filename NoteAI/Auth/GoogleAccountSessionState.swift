import Foundation

enum GoogleUserProfilePayload {
    enum ParseError: LocalizedError, Equatable {
        case missingEmail

        var errorDescription: String? {
            switch self {
            case .missingEmail:
                return "Google did not return an account email."
            }
        }
    }

    static func profile(from json: [String: Any]) throws -> GoogleUserProfile {
        let email = (json["email"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            throw ParseError.missingEmail
        }

        return GoogleUserProfile(
            name: json["name"] as? String ?? "",
            email: email,
            photoURL: json["picture"] as? String ?? ""
        )
    }
}

enum GoogleAccountSessionState: Equatable {
    case signedIn(GoogleUserProfile)
    case notSignedIn

    static func resolve(
        accessToken: String?,
        name: String,
        email: String,
        photoURL: String,
        skippedAuth: Bool
    ) -> GoogleAccountSessionState {
        let token = (accessToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !email.isEmpty else {
            return .notSignedIn
        }
        return .signedIn(GoogleUserProfile(name: name, email: email, photoURL: photoURL))
    }
}

enum OAuthFormURLEncoder {
    static func body(_ params: [(String, String)]) -> String {
        params
            .map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

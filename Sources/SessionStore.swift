import Foundation
import UIKit

/// Immutable, Sendable snapshot of the values the API needs on a request.
/// Passing this (instead of the MainActor SessionStore) keeps the networking
/// layer free of cross-actor access.
struct Identity: Sendable {
    let authToken: String?
    let userId: String?
    let deviceToken: String
    let platform: String
    let deviceName: String
    let osVersion: String
    let language: String
}

/// Holds auth state and exposes identity values the API needs on every request.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var isAuthenticated: Bool

    private(set) var authToken: String?
    private(set) var userId: String?
    @Published private(set) var displayName: String?
    @Published private(set) var email: String?

    /// Stable per-install identifier used as the backend "device_token".
    let deviceToken: String
    let platform = "iOS"
    var deviceName: String { UIDevice.current.name }
    var osVersion: String { UIDevice.current.systemVersion }

    init() {
        self.authToken = Keychain.get("authToken")
        self.userId = Keychain.get("userId")
        self.displayName = Keychain.get("displayName")
        self.email = Keychain.get("email")
        self.isAuthenticated = (Keychain.get("authToken") != nil)

        if let existing = Keychain.get("deviceToken") {
            self.deviceToken = existing
        } else {
            let token = UUID().uuidString
            Keychain.set(token, for: "deviceToken")
            self.deviceToken = token
        }
    }

    func identity() -> Identity {
        Identity(
            authToken: authToken,
            userId: userId,
            deviceToken: deviceToken,
            platform: platform,
            deviceName: deviceName,
            osVersion: osVersion,
            language: "nl"
        )
    }

    func signIn(with data: LoginData) {
        authToken = data.authToken
        userId = data.userId
        displayName = data.name ?? data.first_name
        email = data.userEmail
        Keychain.set(data.authToken, for: "authToken")
        Keychain.set(data.userId, for: "userId")
        Keychain.set(displayName, for: "displayName")
        Keychain.set(email, for: "email")
        isAuthenticated = true
    }

    func signOut() {
        authToken = nil
        userId = nil
        displayName = nil
        email = nil
        Keychain.delete("authToken")
        Keychain.delete("userId")
        Keychain.delete("displayName")
        Keychain.delete("email")
        isAuthenticated = false
    }
}

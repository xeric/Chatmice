//
//  TokenManager.swift
//  Chatmice
//
//  Created by Renat Notfullin on 03.09.2024.
//

import Foundation
import KeychainAccess

final class TokenManager {
    private static let keychainService = "xeric.com.chatmice"
    private static let tokenPrefix = "api_token_"

    // Reuse one Keychain wrapper and cache successful reads for the process lifetime.
    // This prevents model switches and agent rounds from repeatedly asking macOS to
    // authorize the same item after changing between development and release builds.
    private static let localKeychain = Keychain(service: keychainService)
        .synchronizable(false)
        .accessibility(.afterFirstUnlock)
    private static let cloudKeychain = Keychain(service: keychainService)
        .synchronizable(true)
        .accessibility(.afterFirstUnlock)
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var tokenCache: [String: String] = [:]

    enum TokenError: Error {
        case setFailed
        case getFailed
        case deleteFailed
    }

    // MARK: - Public API

    static func setToken(_ token: String, for service: String, identifier: String? = nil) throws {
        let key = makeKey(for: service, identifier: identifier)
        let syncEnabled = UserDefaults.standard.bool(forKey: PersistenceController.iCloudSyncEnabledKey)

        do {
            if syncEnabled {
                var didWrite = false
                if (try? cloudKeychain.set(token, key: key)) != nil { didWrite = true }
                if (try? localKeychain.set(token, key: key)) != nil { didWrite = true }
                guard didWrite else { throw TokenError.setFailed }
            } else {
                try localKeychain.set(token, key: key)
            }
            cache(token, forKey: key)
        } catch {
            throw TokenError.setFailed
        }
    }

    static func getToken(for service: String, identifier: String? = nil) throws -> String? {
        let key = makeKey(for: service, identifier: identifier)
        if let token = cachedToken(forKey: key) {
            return token
        }

        let syncEnabled = UserDefaults.standard.bool(forKey: PersistenceController.iCloudSyncEnabledKey)
        do {
            if syncEnabled {
                if let token = try cloudKeychain.get(key, ignoringAttributeSynchronizable: false) {
                    cache(token, forKey: key)
                    return token
                }
                if let token = try localKeychain.get(key, ignoringAttributeSynchronizable: false) {
                    try? cloudKeychain.set(token, key: key)
                    cache(token, forKey: key)
                    return token
                }
            } else {
                if let token = try localKeychain.get(key, ignoringAttributeSynchronizable: false) {
                    cache(token, forKey: key)
                    return token
                }
                if let token = try cloudKeychain.get(key, ignoringAttributeSynchronizable: false) {
                    try? localKeychain.set(token, key: key)
                    cache(token, forKey: key)
                    return token
                }
            }
            return nil
        } catch {
            throw TokenError.getFailed
        }
    }

    static func deleteToken(for service: String, identifier: String? = nil) throws {
        let key = makeKey(for: service, identifier: identifier)
        do {
            try localKeychain.remove(key)
            try cloudKeychain.remove(key)
            removeCachedToken(forKey: key)
        } catch {
            throw TokenError.deleteFailed
        }
    }

    /// Remove all synchronizable (iCloud) tokens for this app from the keychain.
    /// Local tokens and the in-memory cache are retained for the current device.
    static func clearCloudTokens() {
        _ = try? cloudKeychain.removeAll()
    }

    /// Cache all tokens into memory. Use this only before an explicit destructive
    /// keychain operation initiated by the user.
    static func cacheAllTokens() -> [String: String] {
        var tokens: [String: String] = [:]

        if let localKeys = try? localKeychain.allKeys() {
            for key in localKeys where key.hasPrefix(tokenPrefix) {
                if let token = try? localKeychain.get(key, ignoringAttributeSynchronizable: true) {
                    tokens[key] = token
                }
            }
        }

        if let cloudKeys = try? cloudKeychain.allKeys() {
            for key in cloudKeys where key.hasPrefix(tokenPrefix) {
                if let token = try? cloudKeychain.get(key, ignoringAttributeSynchronizable: true) {
                    tokens[key] = token
                }
            }
        }

        replaceCache(with: tokens)
        return tokens
    }

    static func restoreTokensToLocalKeychain(_ tokens: [String: String]) {
        for (key, token) in tokens {
            _ = try? localKeychain.set(token, key: key)
        }
        mergeIntoCache(tokens)
    }

    static func restoreTokensToCloudKeychain(_ tokens: [String: String]) {
        for (key, token) in tokens {
            _ = try? cloudKeychain.set(token, key: key)
        }
        mergeIntoCache(tokens)
    }

    /// Migrate existing tokens only when the user explicitly changes the sync setting.
    static func migrateTokensForSyncChange(toSyncEnabled: Bool) {
        let destination = toSyncEnabled ? cloudKeychain : localKeychain

        if let localKeys = try? localKeychain.allKeys() {
            for key in localKeys where key.hasPrefix(tokenPrefix) {
                if let token = try? localKeychain.get(key, ignoringAttributeSynchronizable: true) {
                    _ = try? destination.set(token, key: key)
                    cache(token, forKey: key)
                }
            }
        }

        if let cloudKeys = try? cloudKeychain.allKeys() {
            for key in cloudKeys where key.hasPrefix(tokenPrefix) {
                if let token = try? cloudKeychain.get(key, ignoringAttributeSynchronizable: true) {
                    _ = try? destination.set(token, key: key)
                    cache(token, forKey: key)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func makeKey(for service: String, identifier: String?) -> String {
        if let identifier {
            return "\(tokenPrefix)\(service)_\(identifier)"
        }
        return "\(tokenPrefix)\(service)"
    }

    private static func cachedToken(forKey key: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return tokenCache[key]
    }

    private static func cache(_ token: String, forKey key: String) {
        cacheLock.lock()
        tokenCache[key] = token
        cacheLock.unlock()
    }

    private static func removeCachedToken(forKey key: String) {
        cacheLock.lock()
        tokenCache.removeValue(forKey: key)
        cacheLock.unlock()
    }

    private static func replaceCache(with tokens: [String: String]) {
        cacheLock.lock()
        tokenCache = tokens
        cacheLock.unlock()
    }

    private static func mergeIntoCache(_ tokens: [String: String]) {
        cacheLock.lock()
        tokenCache.merge(tokens) { _, new in new }
        cacheLock.unlock()
    }
}

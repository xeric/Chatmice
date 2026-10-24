import Foundation

/// Header values can contain credentials; store the complete dictionary in Keychain.
enum ProviderHeaderStore {
    static func load(for id: UUID) throws -> [String: String] {
        guard let json = try TokenManager.getToken(for: "provider_headers_\(id.uuidString)") else { return [:] }
        let headers = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        try validate(headers)
        return headers
    }

    static func save(_ headers: [String: String], for id: UUID) throws {
        try validate(headers)
        let json = String(decoding: try JSONEncoder().encode(headers), as: UTF8.self)
        try TokenManager.setToken(json, for: "provider_headers_\(id.uuidString)")
    }

    static func remove(for id: UUID) throws {
        try TokenManager.deleteToken(for: "provider_headers_\(id.uuidString)")
    }

    static func parse(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var names = Set<String>()
        guard !text.contains("\r") else { throw HeaderError.invalid("HTTP headers cannot contain carriage returns.") }
        for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw HeaderError.invalid("Use Header-Name: value, one header per line.")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard names.insert(name.lowercased()).inserted else {
                throw HeaderError.invalid("Duplicate header: \(name)")
            }
            result[name] = value
        }
        try validate(result)
        return result
    }

    static func validate(_ headers: [String: String]) throws {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var names = Set<String>()
        for (name, value) in headers {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  names.insert(name.lowercased()).inserted,
                  value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }) else {
                throw HeaderError.invalid("Invalid or duplicate HTTP header: \(name)")
            }
        }
    }

    static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers {
            // URLRequest handles header field names case-insensitively.
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    enum HeaderError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
}

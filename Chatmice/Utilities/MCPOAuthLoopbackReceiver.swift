import AppKit
import Darwin
import Foundation

/// A short-lived HTTP receiver bound exclusively to loopback, never to all interfaces.
@MainActor
final class MCPOAuthLoopbackReceiver {
    private struct Client {
        let descriptor: Int32
        let reader: DispatchSourceRead
        var request = Data()
        var writer: DispatchSourceWrite?
        var response = Data()
        var sent = 0
        var callback: URL?
    }

    private var listeners: [DispatchSourceRead] = []
    private var clients: [UUID: Client] = [:]
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeoutTask: Task<Void, Never>?

    func authorize(_ authorizationURL: URL, redirectURI: String, state: String,
                   timeout: TimeInterval = 180) async throws -> URL {
        let redirect = try MCPOAuthConfiguration.callbackURL(redirectURI)
        guard redirect.scheme == "http", let port = redirect.port else {
            throw MCPOAuthError.message("A local OAuth callback requires an explicit port")
        }
        try Task.checkCancellation()
        let families: [Int32] = redirect.host == "localhost" ? [AF_INET, AF_INET6]
            : [redirect.host == "127.0.0.1" ? AF_INET : AF_INET6]
        do {
            for family in families {
                let descriptor = try Self.listen(family: family, port: UInt16(port))
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
                source.setEventHandler { [weak self] in
                    self?.acceptConnections(descriptor, redirect: redirect, state: state)
                }
                source.setCancelHandler { Darwin.close(descriptor) }
                listeners.append(source)
                source.resume()
            }
        } catch {
            stop()
            throw MCPOAuthError.message("Cannot listen on OAuth callback port \(port): \(error.localizedDescription)")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(MCPOAuthError.message("OAuth sign-in timed out")))
                }
                if !NSWorkspace.shared.open(authorizationURL) {
                    finish(.failure(MCPOAuthError.message("Cannot open the OAuth authorization URL")))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private static func listen(family: Int32, port: UInt16) throws -> Int32 {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError() }
        do {
            if family == AF_INET6 {
                var onlyIPv6: Int32 = 1
                guard setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &onlyIPv6,
                                 socklen_t(MemoryLayout.size(ofValue: onlyIPv6))) == 0 else { throw socketError() }
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                address.sin6_addr = in6addr_loopback
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
                guard result == 0 else { throw socketError() }
            } else {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard result == 0 else { throw socketError() }
            }
            guard Darwin.listen(descriptor, 8) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                throw socketError()
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func socketError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private func acceptConnections(_ descriptor: Int32, redirect: URL, state: String) {
        while continuation != nil {
            let clientDescriptor = Darwin.accept(descriptor, nil, nil)
            guard clientDescriptor >= 0 else { return }
            guard clients.count < 8, fcntl(clientDescriptor, F_SETFL, O_NONBLOCK) == 0 else {
                Darwin.close(clientDescriptor)
                continue
            }
            var noSignal: Int32 = 1
            guard setsockopt(clientDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                             socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else {
                Darwin.close(clientDescriptor)
                continue
            }
            let id = UUID()
            let reader = DispatchSource.makeReadSource(fileDescriptor: clientDescriptor, queue: .main)
            reader.setEventHandler { [weak self] in self?.receive(id, redirect: redirect, state: state) }
            reader.setCancelHandler { Darwin.close(clientDescriptor) }
            clients[id] = Client(descriptor: clientDescriptor, reader: reader)
            reader.resume()
        }
    }

    private func receive(_ id: UUID, redirect: URL, state: String) {
        guard var client = clients[id], client.writer == nil else { return }
        var bytes = [UInt8](repeating: 0, count: 2048)
        let count = Darwin.recv(client.descriptor, &bytes, bytes.count, 0)
        if count <= 0 {
            if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { closeClient(id) }
            return
        }
        client.request.append(contentsOf: bytes.prefix(count))
        clients[id] = client
        guard client.request.count <= 8192 else {
            respond(id, status: "431 Request Header Fields Too Large", body: "Request rejected.")
            return
        }
        if client.request.range(of: Data("\r\n\r\n".utf8)) != nil {
            handle(client.request, id: id, redirect: redirect, state: state)
        }
    }

    private func handle(_ data: Data, id: UUID, redirect: URL, state: String) {
        guard let request = String(data: data, encoding: .utf8) else {
            respond(id, status: "400 Bad Request", body: "Request rejected.")
            return
        }
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let hostFields = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        let host = hostFields.first.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
              hostFields.count == 1,
              host?.lowercased() == "\(redirect.host ?? ""):\(redirect.port ?? 0)".lowercased(),
              let callback = URL(string: String(parts[1]), relativeTo: redirect)?.absoluteURL,
              callback.path == redirect.path else {
            respond(id, status: "404 Not Found", body: "Not an OAuth callback.")
            return
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else {
            respond(id, status: "400 Bad Request", body: "OAuth state verification failed.")
            return
        }
        do {
            let denied = items.contains(where: { $0.name == "error" })
            if !denied {
                _ = try MCPOAuthManager.authorizationCode(callback: callback, redirectURI: redirect.absoluteString, state: state)
            }
            respond(id, status: "200 OK", body: denied
                    ? "Authorization was not completed. Return to Chatmice to review the error and try again."
                    : "Your callback has been received. Return to Chatmice to finish connecting your MCP server.",
                    callback: callback, succeeded: !denied)
        } catch {
            respond(id, status: "400 Bad Request", body: "Invalid OAuth callback.")
        }
    }

    private func respond(_ id: UUID, status: String, body: String, callback: URL? = nil, succeeded: Bool = false) {
        guard var client = clients[id], client.writer == nil else { return }
        let html = Self.callbackPage(message: body, succeeded: succeeded)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\n"
            + "Content-Security-Policy: default-src 'none'; img-src data:; style-src 'unsafe-inline'; "
            + "base-uri 'none'; frame-ancestors 'none'; form-action 'none'\r\n"
            + "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n\(html)"
        client.response = Data(response.utf8)
        client.callback = callback
        let writer = DispatchSource.makeWriteSource(fileDescriptor: client.descriptor, queue: .main)
        writer.setEventHandler { [weak self] in self?.sendResponse(id) }
        client.writer = writer
        clients[id] = client
        writer.resume()
    }

    private static let iconDataURI: String = {
        let file = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon"
        let iconURL = Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: "icns")
        let image = iconURL.flatMap { NSImage(contentsOf: $0) } ?? NSImage(named: NSImage.applicationIconName)
        guard let tiff = image?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }()

    static func callbackPage(message: String, succeeded: Bool) -> String {
        let escaped = message.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        let title = succeeded ? "Callback received" : "Unable to complete sign-in"
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(title) · Chatmice</title>
        <style>
        :root { color-scheme: light dark; --bg: #f5f6fa; --card: #fff; --fg: #20232d; --muted: #6b7280; --border: #e6e8ef; --accent: #456bda; --status: #26805a; --status-bg: #eaf6ee; }
        @media(prefers-color-scheme: dark) { :root { --bg: #151720; --card: #20232e; --fg: #f0f1f6; --muted: #a9b0c1; --border: #343947; --accent: #93aeff; --status: #81d9a8; --status-bg: #263b31; } }
        * { box-sizing: border-box; }
        body { margin: 0; min-height: 100svh; display: grid; place-items: center; padding: 24px;
        background: var(--bg); color: var(--fg); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        main { width: min(100%, 460px); text-align: center; padding: 42px 36px 30px; background: var(--card); border: 1px solid var(--border); border-radius: 28px; box-shadow: 0 18px 70px #0000000c; }
        .icon { width: 104px; height: 104px; object-fit: contain; display: block; margin: 0 auto 16px; }
        .brand { font-size: 15px; font-weight: 600; letter-spacing: .02em; color: var(--muted); margin: 0 0 28px; }
        .status { display: inline-flex; align-items: center; gap: 7px; color: var(--status); background: var(--status-bg); border-radius: 999px; padding: 7px 12px; font-size: 12px; font-weight: 600; }
        .error { --status: #bd4b42; --status-bg: #fcefeb; } @media(prefers-color-scheme: dark) { .error { --status: #ffaaa0; --status-bg: #442d2b; } }
        h1 { font-size: 27px; line-height: 1.25; letter-spacing: -.035em; margin: 18px 0 14px; }
        .message { color: var(--muted); font-size: 15px; line-height: 1.7; margin: 0; }
        .return { margin: 28px 0 0; padding: 14px; border: 1px solid var(--border); border-radius: 12px; font-size: 14px; font-weight: 600; color: var(--accent); }
        footer { margin-top: 22px; font-size: 12px; color: var(--muted); } @media(max-width: 480px) { main { padding: 32px 22px 26px; } h1 { font-size: 24px; } }
        </style></head><body><main class="\(succeeded ? "success" : "error")">
        <img class="icon" src="\(iconDataURI)" alt="Chatmice app icon" width="104" height="104">
        <p class="brand">Chatmice</p><div class="status"><span aria-hidden="true">\(succeeded ? "✓" : "!")</span>\(succeeded ? "Callback verified" : "Sign-in interrupted")</div>
        <h1>\(title)</h1><p class="message">\(escaped)</p><p class="return">Continue in Chatmice</p>
        <footer>You can safely close this browser tab.</footer></main></body></html>
        """
    }


    private func sendResponse(_ id: UUID) {
        guard var client = clients[id] else { return }
        let count = client.response.withUnsafeBytes {
            Darwin.send(client.descriptor, $0.baseAddress!.advanced(by: client.sent), $0.count - client.sent, 0)
        }
        if count < 0 {
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { closeClient(id) }
            return
        }
        client.sent += count
        clients[id] = client
        if client.sent == client.response.count {
            closeClient(id)
            if let callback = client.callback { finish(.success(callback)) }
        }
    }

    private func closeClient(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.writer?.cancel()
        client.reader.cancel()
    }

    private func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        for id in Array(clients.keys) { closeClient(id) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        stop()
        continuation.resume(with: result)
    }
}

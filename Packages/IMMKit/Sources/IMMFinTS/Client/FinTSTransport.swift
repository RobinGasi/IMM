import Foundation

/// Carries one FinTS message to the bank and returns the bank's answer. The dialog layer talks to this protocol only,
/// so tests script the bank without a network.
public protocol FinTSTransport: Sendable {
    /// - Parameters:
    ///   - message: The raw FinTS message (ISO 8859-1 bytes, as built by `FinTSMessageBuilder`).
    ///   - url: The bank's PIN/TAN endpoint.
    /// - Returns: The raw bytes of the bank's answer message.
    /// - Throws: `FinTSError` (`.transport`, `.maintenance`, `.malformedResponse`).
    func send(_ message: Data, to url: URL) async throws -> Data
}

/// HTTPS transport of FinTS PIN/TAN: the message travels base64-encoded in the body of a POST request, and the
/// answer comes back base64-encoded.
public struct URLSessionFinTSTransport: FinTSTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 60) {
        self.session = session
        self.timeout = timeout
    }

    public func send(_ message: Data, to url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=ISO-8859-1", forHTTPHeaderField: "Content-Type")
        // `base64EncodedData()` writes no line breaks unless asked to.
        request.httpBody = message.base64EncodedData()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw FinTSError.transport(message: error.localizedDescription, offline: Self.isOffline(error))
        } catch is CancellationError {
            throw FinTSError.transport(message: "The request was cancelled.", offline: false)
        } catch {
            throw FinTSError.transport(message: error.localizedDescription, offline: false)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FinTSError.transport(message: "The bank did not answer with an HTTP response.", offline: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if http.statusCode == 503 {
                throw FinTSError.maintenance(message: "HTTP 503: \(text)")
            }
            throw FinTSError.transport(message: "HTTP \(http.statusCode): \(text)", offline: false)
        }
        // The body is base64; servers wrap lines, so whitespace and line breaks are skipped.
        guard let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else {
            throw FinTSError.malformedResponse("The bank's answer is not valid base64.")
        }
        return decoded
    }

    private static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dataNotAllowed:
            true
        default:
            false
        }
    }
}

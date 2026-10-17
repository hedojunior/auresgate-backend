import Foundation
import Vapor

/// Rejects requests that do not carry the shared key.
///
/// WHAT THIS IS, AND IS NOT: the key ships inside the app, so anyone who can
/// read the binary can extract it. It is not an authentication scheme and does
/// not identify users. What it does is keep the API from answering to whoever
/// happens upon the URL — which matters here because the endpoints carry
/// location data: the coordinates of each sighting and the owner's trail.
///
/// A production system would authenticate per user and authorise per search.
/// That is out of scope for the prototype and is recorded as a limitation.
struct APIKeyMiddleware: AsyncMiddleware {

    static let headerName = "X-AuResgate-Key"

    /// Nil means no key was configured, which is only tolerated outside
    /// production — see `configure`, which refuses to boot without one there.
    let expectedKey: String?

    init(expectedKey: String? = Environment.get("AURESGATE_API_KEY")) {
        self.expectedKey = expectedKey
    }

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard let expectedKey, !expectedKey.isEmpty else {
            // Unprotected mode, local development only.
            return try await next.respond(to: request)
        }

        guard let presented = request.headers.first(name: APIKeyMiddleware.headerName),
              APIKeyMiddleware.constantTimeEquals(presented, expectedKey)
        else {
            // Deliberately vague: distinguishing "missing" from "wrong" would
            // tell a prober which half they got right.
            throw Abort(.unauthorized, reason: "Credencial ausente ou inválida.")
        }

        return try await next.respond(to: request)
    }

    /// Compares without short-circuiting on the first differing byte.
    ///
    /// A plain `==` returns as soon as it finds a mismatch, so the time it
    /// takes leaks how much of the key was guessed correctly. The length
    /// itself still leaks, which is acceptable for a fixed-length key.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }

        var difference: UInt8 = 0
        for index in 0..<left.count {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

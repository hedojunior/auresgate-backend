import Foundation
import Vapor

struct APIKeyMiddleware: AsyncMiddleware {
    static let headerName = "X-AuResgate-Key"

    let expectedKey: String?

    init(expectedKey: String? = Environment.get("AURESGATE_API_KEY")) {
        self.expectedKey = expectedKey
    }

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard let expectedKey, !expectedKey.isEmpty else {
            return try await next.respond(to: request)
        }

        guard let presented = request.headers.first(name: APIKeyMiddleware.headerName),
              APIKeyMiddleware.constantTimeEquals(presented, expectedKey)
        else {
            throw Abort(.unauthorized, reason: "Credencial ausente ou inválida.")
        }

        return try await next.respond(to: request)
    }

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

import Foundation
import Vapor

/// HTTP surface of the collaborative search.
///
/// No authentication: the prototype runs for a controlled field test with two
/// devices. A production version would need it, not least because anyone able
/// to start a search can notify every nearby user — the abuse vector is noted
/// in the thesis rather than solved here.
struct SearchController: RouteCollection {

    /// Default radius for "who should hear about this search".
    ///
    /// Not derived from the beacon range: this is the recruiting radius, which
    /// is about who can plausibly walk over and help, not about who can hear
    /// the signal. 2 km is a few minutes on foot or by bicycle.
    static let defaultNotifyRadiusMeters: Double = 2_000

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")

        // Left open on purpose: it reveals nothing, and a deploy platform's
        // health check cannot carry the key.
        api.get("health") { _ -> SimpleResponse in
            SimpleResponse(message: "auresgate")
        }

        // Everything past this point carries location data, so it sits behind
        // the shared key.
        let protected = api.grouped(APIKeyMiddleware())
        let searches = protected.grouped("searches")
        searches.post(use: start)
        searches.get("nearby", use: nearby)
        searches.get("all", use: all)

        let single = searches.grouped(":searchId")
        single.get(use: state)
        single.post("join", use: join)
        single.post("leave", use: leave)
        single.post("detections", use: reportDetection)
        single.post("trail", use: appendTrail)
        single.post("close", use: close)
    }

    // MARK: - Routes

    /// Step 1 of the flow: the owner opens a search.
    func start(request: Request) async throws -> SearchState {
        let payload = try request.content.decode(StartSearchRequest.self)
        guard !payload.pet.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "O nome do animal é obrigatório.")
        }
        let state = await request.application.searchStore.startSearch(payload)
        request.logger.info("busca iniciada: \(state.id) — \(state.pet.name)")
        return state
    }

    /// Step 2: devices poll this to find searches they can help with.
    ///
    /// Stands in for the push notification, which needs an APNs certificate
    /// the prototype does not have. The server-side decision — who is close
    /// enough to be told — is the same either way.
    func nearby(request: Request) async throws -> [SearchSummary] {
        guard let latitude = request.query[Double.self, at: "lat"],
              let longitude = request.query[Double.self, at: "lon"]
        else {
            throw Abort(.badRequest, reason: "Informe lat e lon.")
        }

        let radius = request.query[Double.self, at: "radius"]
            ?? SearchController.defaultNotifyRadiusMeters

        return await request.application.searchStore.nearbySearches(
            to: Coordinate(latitude: latitude, longitude: longitude),
            radiusMeters: radius
        )
    }

    /// Everything the active-search screen needs, in one poll.
    func state(request: Request) async throws -> SearchState {
        let id = try searchId(from: request)
        guard let state = await request.application.searchStore.searchState(id: id) else {
            throw Abort(.notFound, reason: "Busca não encontrada.")
        }
        return state
    }

    func join(request: Request) async throws -> SearchState {
        let id = try searchId(from: request)
        let payload = try request.content.decode(JoinRequest.self)
        guard let state = await request.application.searchStore.join(
            searchId: id, request: payload
        ) else {
            throw Abort(.notFound, reason: "Busca não encontrada ou já encerrada.")
        }
        return state
    }

    func leave(request: Request) async throws -> SimpleResponse {
        let id = try searchId(from: request)
        let payload = try request.content.decode(JoinRequest.self)
        await request.application.searchStore.leave(
            searchId: id, participantId: payload.participantId
        )
        return SimpleResponse()
    }

    /// Step 4: a participant heard the beacon.
    ///
    /// The body carries a radius computed on the device from RSSI, not the
    /// detector's exact position — the whole point of the privacy decision.
    func reportDetection(request: Request) async throws -> SearchState {
        let id = try searchId(from: request)
        let payload = try request.content.decode(ReportDetectionRequest.self)

        guard payload.radiusMeters > 0 else {
            throw Abort(.badRequest, reason: "O raio informado deve ser positivo.")
        }

        guard let state = await request.application.searchStore.reportDetection(
            searchId: id, request: payload
        ) else {
            throw Abort(.notFound, reason: "Busca não encontrada ou já encerrada.")
        }

        request.logger.info(
            "detecção em \(id): rssi \(payload.rssi) dBm, raio \(payload.radiusMeters) m"
        )
        return state
    }

    /// The owner's trail — where they have already looked.
    func appendTrail(request: Request) async throws -> SearchState {
        let id = try searchId(from: request)
        let payload = try request.content.decode(TrailRequest.self)
        guard let state = await request.application.searchStore.appendTrailPoint(
            searchId: id, request: payload
        ) else {
            throw Abort(.notFound, reason: "Busca não encontrada, encerrada, ou o autor não é o tutor.")
        }
        return state
    }

    func close(request: Request) async throws -> SearchState {
        let id = try searchId(from: request)
        let payload = try request.content.decode(CloseSearchRequest.self)
        guard let state = await request.application.searchStore.closeSearch(
            searchId: id, request: payload
        ) else {
            throw Abort(.notFound, reason: "Busca não encontrada, ou o autor não é o tutor.")
        }
        request.logger.info("busca encerrada: \(id) — encontrado: \(payload.found)")
        return state
    }

    /// Diagnostic listing, handy while running the field test.
    ///
    /// The widest endpoint there is — every search with every coordinate. It
    /// stays because it is what makes the two-device test debuggable, and the
    /// shared key is what makes that acceptable.
    func all(request: Request) async throws -> [SearchState] {
        await request.application.searchStore.allSearches()
    }

    // MARK: - Helpers

    private func searchId(from request: Request) throws -> UUID {
        guard let raw = request.parameters.get("searchId"),
              let id = UUID(uuidString: raw)
        else {
            throw Abort(.badRequest, reason: "Identificador de busca inválido.")
        }
        return id
    }
}

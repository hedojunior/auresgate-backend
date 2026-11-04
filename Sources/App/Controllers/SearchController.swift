import Foundation
import Vapor

struct SearchController: RouteCollection {
    static let defaultNotifyRadiusMeters: Double = 2_000

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")

        api.get("health") { _ -> SimpleResponse in
            SimpleResponse(message: "auresgate")
        }

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

    func start(request: Request) async throws -> SearchState {
        let payload = try request.content.decode(StartSearchRequest.self)
        guard !payload.pet.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "O nome do animal é obrigatório.")
        }
        let state = await request.application.searchStore.startSearch(payload)
        request.logger.info("busca iniciada: \(state.id) — \(state.pet.name)")
        return state
    }

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

    func all(request: Request) async throws -> [SearchState] {
        await request.application.searchStore.allSearches()
    }

    private func searchId(from request: Request) throws -> UUID {
        guard let raw = request.parameters.get("searchId"),
              let id = UUID(uuidString: raw)
        else {
            throw Abort(.badRequest, reason: "Identificador de busca inválido.")
        }
        return id
    }
}

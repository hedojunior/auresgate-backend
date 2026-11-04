import Foundation
import Vapor

public func configure(_ app: Application) async throws {
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "0.0.0.0"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080

    app.routes.defaultMaxBodySize = "512kb"

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
    encoder.outputFormatting = [.withoutEscapingSlashes]

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds

    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    app.searchStore = SearchStore()

    let apiKey = Environment.get("AURESGATE_API_KEY")
    if app.environment == .production, apiKey?.isEmpty != false {
        app.logger.critical("AURESGATE_API_KEY nao definida — recusando iniciar em producao.")
        throw Abort(.internalServerError, reason: "AURESGATE_API_KEY nao definida.")
    }
    if apiKey?.isEmpty != false {
        app.logger.warning("Rodando SEM chave de API. Aceitavel apenas localmente.")
    }

    try routes(app)
}

func routes(_ app: Application) throws {
    try app.register(collection: SearchController())

    app.get { _ in
        "AuResgate — servidor de buscas colaborativas. Veja /api/health."
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.fractional.string(from: date))
        }
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: text) {
                return date
            }
            if let date = ISO8601DateFormatter.plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Data em formato não reconhecido: \(text)"
            )
        }
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

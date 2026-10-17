import Foundation
import Vapor

public func configure(_ app: Application) async throws {
    // Cloud hosts inject the port; default to 8080 for local runs.
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "0.0.0.0"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080

    // Dates travel as ISO 8601 with fractional seconds, matching what the iOS
    // app already writes to its passive log. Keeping one format across both
    // sides avoids a class of parsing bugs that only show up in the field.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
    encoder.outputFormatting = [.withoutEscapingSlashes]

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds

    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    // Build the store once, at boot. Creating it lazily on first access would
    // let two concurrent requests each make their own and diverge.
    app.searchStore = SearchStore()

    // Fail loudly rather than deploying an open API by accident. The endpoints
    // carry location data, so an unprotected production boot is a bug, not a
    // configuration choice.
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

// MARK: - ISO 8601 with fractional seconds

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
            // Some clients omit the fractional part; accept both rather than
            // failing a whole request over a formatting detail.
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

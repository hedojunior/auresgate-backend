import Foundation
import Vapor

struct Pet: Content, Sendable {
    var name: String
    var breed: String
    var nicknames: [String]
    var note: String
    var major: Int
    var minor: Int
    var photoBase64: String?
}

struct Coordinate: Content, Sendable {
    var latitude: Double
    var longitude: Double

    func distance(to other: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let deltaLat = (other.latitude - latitude) * .pi / 180
        let deltaLon = (other.longitude - longitude) * .pi / 180

        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(a)))
    }
}

struct TrailPoint: Content, Sendable {
    var coordinate: Coordinate
    var timestamp: Date
}

struct Detection: Content, Sendable {
    var id: UUID
    var participantId: UUID
    var participantLabel: String
    var coordinate: Coordinate
    var radiusMeters: Double
    var rssi: Int
    var timestamp: Date
}

struct Participant: Sendable {
    var id: UUID
    var label: String
    var joinedAt: Date
    var lastSeenAt: Date
}

struct Search: Sendable {
    var id: UUID
    var pet: Pet
    var ownerId: UUID
    var ownerLabel: String
    var origin: Coordinate
    var startedAt: Date
    var closedAt: Date?
    var ownerTrail: [TrailPoint]
    var detections: [Detection]
    var participants: [UUID: Participant]

    var isOpen: Bool { closedAt == nil }
}

struct StartSearchRequest: Content {
    var pet: Pet
    var ownerId: UUID
    var ownerLabel: String
    var origin: Coordinate
}

struct JoinRequest: Content {
    var participantId: UUID
    var label: String
}

struct TrailRequest: Content {
    var ownerId: UUID
    var coordinate: Coordinate
}

struct ReportDetectionRequest: Content {
    var participantId: UUID
    var participantLabel: String
    var coordinate: Coordinate
    var radiusMeters: Double
    var rssi: Int
}

struct CloseSearchRequest: Content {
    var ownerId: UUID
    var found: Bool
}

struct SearchSummary: Content {
    var id: UUID
    var petName: String
    var petBreed: String
    var ownerLabel: String
    var startedAt: Date
    var distanceMeters: Double
    var participantCount: Int
    var detectionCount: Int
}

struct SearchState: Content {
    var id: UUID
    var pet: Pet
    var ownerLabel: String
    var origin: Coordinate
    var startedAt: Date
    var closedAt: Date?
    var isOpen: Bool
    var participantCount: Int
    var ownerTrail: [TrailPoint]
    var detections: [Detection]
}

struct SimpleResponse: Content {
    var ok: Bool
    var message: String?

    init(ok: Bool = true, message: String? = nil) {
        self.ok = ok
        self.message = message
    }
}

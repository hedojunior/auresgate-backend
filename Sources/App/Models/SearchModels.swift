import Foundation
import Vapor

// MARK: - Domain

/// The animal being looked for, as the participants see it.
///
/// Kept deliberately small. The app can tell a participant how close the
/// signal is, but not in which direction — the name and the nicknames are
/// what close that gap, since the person calls the animal and recognises it.
struct Pet: Content, Sendable {
    var name: String
    var breed: String
    /// Other names the animal answers to. Shown to whoever detects the signal.
    var nicknames: [String]
    /// Free-form hint for whoever finds the animal (temperament, medication…).
    var note: String
    /// Beacon identity. All beacons share the system UUID; this pair is what
    /// distinguishes one animal from another during ranging.
    var major: Int
    var minor: Int
    /// The animal's photo, JPEG in base64, already downscaled by the app.
    ///
    /// Stored inline with the search rather than as an uploaded file: the
    /// server keeps no file storage, and the image is small by construction
    /// (~20 KB). It is relayed to every participant, because a face is what
    /// lets someone tell the right animal from another loose dog once the
    /// signal says "close by".
    var photoBase64: String?
}

struct Coordinate: Content, Sendable {
    var latitude: Double
    var longitude: Double

    /// Great-circle distance in meters.
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

/// A point on the owner's trail — where they have already looked.
///
/// Only the owner's position is tracked this way, and only while a search is
/// open. They are the one who asked for help, so exposing their own position
/// is their explicit choice; participants are never tracked.
struct TrailPoint: Content, Sendable {
    var coordinate: Coordinate
    var timestamp: Date
}

/// A reported sighting of the beacon.
///
/// Carries a radius rather than a point estimate. The radius is derived on the
/// device from the measured RSSI, so what reaches the server is an area of
/// uncertainty, never the detector's exact position.
struct Detection: Content, Sendable {
    var id: UUID
    var participantId: UUID
    var participantLabel: String
    var coordinate: Coordinate
    /// Radius of uncertainty in meters, derived from RSSI on the device.
    var radiusMeters: Double
    var rssi: Int
    var timestamp: Date
}

/// Someone who joined an active search. Stored only to count participants and
/// to expire stale ones — no position is kept.
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
    /// Where the search was started, used to decide who gets notified.
    var origin: Coordinate
    var startedAt: Date
    var closedAt: Date?
    var ownerTrail: [TrailPoint]
    var detections: [Detection]
    var participants: [UUID: Participant]

    var isOpen: Bool { closedAt == nil }
}

// MARK: - Requests

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
    /// Whether the animal was found, for the record.
    var found: Bool
}

// MARK: - Responses

/// What a participant sees in the list of nearby searches.
struct SearchSummary: Content {
    var id: UUID
    var petName: String
    var petBreed: String
    var ownerLabel: String
    var startedAt: Date
    /// How far the requesting device is from where the search started.
    var distanceMeters: Double
    var participantCount: Int
    var detectionCount: Int
}

/// Everything the active-search screen needs, in one poll.
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
    /// Newest first. The app renders only the first as a radius; the rest
    /// become pins joined by a line.
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

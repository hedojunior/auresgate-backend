import Foundation
import Vapor

/// In-memory store for active searches.
///
/// An actor rather than a lock: every mutation goes through one executor, so
/// two devices reporting detections at the same instant cannot interleave.
///
/// Deliberately not persisted. The prototype demonstrates the collaborative
/// flow, and a restart losing state is acceptable for that purpose; swapping
/// this type for a Fluent-backed repository would not change the controllers.
actor SearchStore {

    /// A participant is counted as present while a heartbeat arrived within
    /// this window. Without it, someone who closed the app would inflate the
    /// "X people helping" figure indefinitely.
    private static let participantTimeout: TimeInterval = 90

    /// Searches older than this are closed automatically, so a forgotten
    /// prototype session does not keep notifying people.
    private static let maxSearchAge: TimeInterval = 60 * 60 * 6

    private var searches: [UUID: Search] = [:]

    // MARK: - Creating

    func startSearch(_ request: StartSearchRequest) -> SearchState {
        let search = Search(
            id: UUID(),
            pet: request.pet,
            ownerId: request.ownerId,
            ownerLabel: request.ownerLabel,
            origin: request.origin,
            startedAt: Date(),
            closedAt: nil,
            ownerTrail: [TrailPoint(coordinate: request.origin, timestamp: Date())],
            detections: [],
            participants: [:]
        )
        searches[search.id] = search
        return state(of: search)
    }

    // MARK: - Reading

    /// Open searches whose origin lies within `radiusMeters` of the caller.
    ///
    /// This is the server side of the notification step: with no push
    /// infrastructure, the device polls this and surfaces what it finds.
    func nearbySearches(
        to coordinate: Coordinate,
        radiusMeters: Double
    ) -> [SearchSummary] {
        expireStaleSearches()

        return searches.values
            .filter(\.isOpen)
            .compactMap { search in
                let distance = search.origin.distance(to: coordinate)
                guard distance <= radiusMeters else { return nil }
                return SearchSummary(
                    id: search.id,
                    petName: search.pet.name,
                    petBreed: search.pet.breed,
                    ownerLabel: search.ownerLabel,
                    startedAt: search.startedAt,
                    distanceMeters: distance,
                    participantCount: activeParticipantCount(in: search),
                    detectionCount: search.detections.count
                )
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    func searchState(id: UUID) -> SearchState? {
        guard let search = searches[id] else { return nil }
        return state(of: search)
    }

    /// Every search, open or closed. Used by the debug endpoint during the
    /// field test, when it helps to see what the server actually holds.
    func allSearches() -> [SearchState] {
        searches.values
            .sorted { $0.startedAt > $1.startedAt }
            .map { state(of: $0) }
    }

    // MARK: - Participating

    @discardableResult
    func join(searchId: UUID, request: JoinRequest) -> SearchState? {
        guard var search = searches[searchId], search.isOpen else { return nil }

        let now = Date()
        if var existing = search.participants[request.participantId] {
            existing.lastSeenAt = now
            existing.label = request.label
            search.participants[request.participantId] = existing
        } else {
            search.participants[request.participantId] = Participant(
                id: request.participantId,
                label: request.label,
                joinedAt: now,
                lastSeenAt: now
            )
        }

        searches[searchId] = search
        return state(of: search)
    }

    func leave(searchId: UUID, participantId: UUID) {
        guard var search = searches[searchId] else { return }
        search.participants.removeValue(forKey: participantId)
        searches[searchId] = search
    }

    // MARK: - Reporting

    func reportDetection(
        searchId: UUID,
        request: ReportDetectionRequest
    ) -> SearchState? {
        guard var search = searches[searchId], search.isOpen else { return nil }

        let detection = Detection(
            id: UUID(),
            participantId: request.participantId,
            participantLabel: request.participantLabel,
            coordinate: request.coordinate,
            radiusMeters: request.radiusMeters,
            rssi: request.rssi,
            timestamp: Date()
        )
        search.detections.append(detection)

        // Reporting also counts as presence: someone who just detected the
        // beacon is plainly still in the search.
        if var participant = search.participants[request.participantId] {
            participant.lastSeenAt = Date()
            search.participants[request.participantId] = participant
        }

        searches[searchId] = search
        return state(of: search)
    }

    func appendTrailPoint(searchId: UUID, request: TrailRequest) -> SearchState? {
        guard var search = searches[searchId],
              search.isOpen,
              search.ownerId == request.ownerId
        else { return nil }

        // Drop points that barely moved: the trail is meant to show which
        // ground has been covered, and a dense cluster of near-identical
        // points only makes the map harder to read.
        if let last = search.ownerTrail.last,
           last.coordinate.distance(to: request.coordinate) < 10 {
            return state(of: search)
        }

        search.ownerTrail.append(
            TrailPoint(coordinate: request.coordinate, timestamp: Date())
        )
        searches[searchId] = search
        return state(of: search)
    }

    // MARK: - Closing

    func closeSearch(searchId: UUID, request: CloseSearchRequest) -> SearchState? {
        guard var search = searches[searchId], search.ownerId == request.ownerId
        else { return nil }

        search.closedAt = Date()
        searches[searchId] = search
        return state(of: search)
    }

    // MARK: - Helpers

    private func activeParticipantCount(in search: Search) -> Int {
        let cutoff = Date().addingTimeInterval(-SearchStore.participantTimeout)
        return search.participants.values.filter { $0.lastSeenAt > cutoff }.count
    }

    private func expireStaleSearches() {
        let cutoff = Date().addingTimeInterval(-SearchStore.maxSearchAge)
        for (id, search) in searches where search.isOpen && search.startedAt < cutoff {
            var expired = search
            expired.closedAt = Date()
            searches[id] = expired
        }
    }

    private func state(of search: Search) -> SearchState {
        SearchState(
            id: search.id,
            pet: search.pet,
            ownerLabel: search.ownerLabel,
            origin: search.origin,
            startedAt: search.startedAt,
            closedAt: search.closedAt,
            isOpen: search.isOpen,
            participantCount: activeParticipantCount(in: search),
            ownerTrail: search.ownerTrail,
            detections: search.detections.sorted { $0.timestamp > $1.timestamp }
        )
    }
}

// MARK: - Application storage

extension Application {
    private struct SearchStoreKey: StorageKey {
        typealias Value = SearchStore
    }

    var searchStore: SearchStore {
        get {
            if let existing = storage[SearchStoreKey.self] {
                return existing
            }
            let store = SearchStore()
            storage[SearchStoreKey.self] = store
            return store
        }
        set {
            storage[SearchStoreKey.self] = newValue
        }
    }
}

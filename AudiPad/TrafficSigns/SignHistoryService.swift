import Foundation
import Combine

/// Rolling log of distinct speed-limit signs the driver has just passed.
/// Driven entirely by the publisher exposed by `RoadSpeedLimitService` —
/// whenever the *limit value* changes (not just the source), the new
/// limit is prepended to the history.
///
/// Lives at the app level so the list survives tab switches; HomeView's
/// RecentSignsStrip is just a read-only view of `signs`.
///
/// Non-speed-limit signs (stop, yield, speedBump…) wait for TSR — we
/// don't have a generic sign feed today and would rather show nothing
/// than fabricate.
@MainActor
final class SignHistoryService: ObservableObject {

    /// Most-recent first. Capped at `maxCount`.
    @Published private(set) var signs: [TrafficSign] = []

    static let maxCount = 4

    /// Subscribe to a road-limit publisher. Call once at app startup;
    /// safe to re-call (replaces the prior subscription).
    func subscribe(to publisher: Published<RoadSpeedLimitService.Reading?>.Publisher) {
        cancellable = publisher
            .compactMap { $0?.limit }
            .removeDuplicates()
            .sink { [weak self] limit in
                self?.record(limit: limit)
            }
    }

    private func record(limit: Int) {
        // Dedup against the head only — if the head is the same limit
        // (regardless of source switch), don't push a duplicate.
        if case .speedLimit(let head)? = signs.first, head == limit {
            return
        }
        signs.insert(.speedLimit(limit), at: 0)
        if signs.count > Self.maxCount {
            signs.removeLast(signs.count - Self.maxCount)
        }
    }

    private var cancellable: AnyCancellable?
}

import Foundation

/// A single recorded dashcam segment on disk. Built by enumerating
/// Documents/dashcam/segments/ (and the locked/ subfolder) — the
/// service doesn't hold a database, the filesystem is the source
/// of truth.
struct DashcamSegment: Identifiable, Hashable {
    /// Identity is the URL — filename is the timestamp-based name
    /// we wrote, and the URL is unique by definition.
    var id: URL { url }
    let url: URL
    let recordedAt: Date
    let durationSeconds: Double?
    let fileSizeBytes: Int64
    /// True when the segment lives in segments/locked/ instead of
    /// segments/ — the loop-deletion routine skips locked files.
    let isLocked: Bool

    static func == (lhs: DashcamSegment, rhs: DashcamSegment) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

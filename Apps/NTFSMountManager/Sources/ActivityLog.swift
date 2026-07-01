import SwiftUI
import NTFSUIKit

/// In-memory record of what the app has been doing this session — mounts/ejects,
/// verify/health scans, format/repair, and system-extension activation. Each
/// long-running operation logs a `.running` entry and later `update(_:status:)`s
/// it to `.success`/`.warning`/`.error`, so the Activity view can show a live
/// in-progress → done/failed timeline.
///
/// Not persisted across launches — this is a session log only (fine for v1).
@MainActor
final class ActivityLog: ObservableObject {
    enum Status: Equatable {
        case running
        case success
        case warning
        case error
        case info

        var systemImage: String {
            switch self {
            case .running: return "clock"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error:   return "xmark.octagon.fill"
            case .info:    return "info.circle"
            }
        }

        var tone: Color {
            switch self {
            case .success:         return .ntfsSuccess
            case .warning, .error: return .ntfsError
            case .running:         return .ntfsPrimary
            case .info:            return .ntfsOnSurfaceVariant
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let time: Date
        var title: String
        var detail: String?
        var status: Status
        var volume: String?      // display name, optional
    }

    /// Newest first. Capped so a long session can't grow unbounded.
    @Published private(set) var entries: [Entry] = []

    private static let cap = 200

    @discardableResult
    func log(_ title: String, detail: String? = nil, status: Status = .info, volume: String? = nil) -> UUID {
        let entry = Entry(id: UUID(), time: Date(), title: title, detail: detail, status: status, volume: volume)
        entries.insert(entry, at: 0)
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
        return entry.id
    }

    /// Transition an existing entry (typically `.running` → `.success`/`.error`).
    /// The title is preserved; callers usually already worded it as an in-progress
    /// verb ("Mounting …"), so pass a completed `detail` to explain the outcome.
    func update(_ id: UUID, status: Status, detail: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        if let detail {
            entries[index].detail = detail
        }
    }

    func clear() {
        entries.removeAll()
    }
}

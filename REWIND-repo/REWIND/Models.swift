import Foundation
import SwiftData

enum SessionStatus: String {
    case pending, inProgress, reviewed, confirmed
    var label: String {
        switch self {
        case .pending: "Pendiente"
        case .inProgress: "En progreso"
        case .reviewed: "Revisada"
        case .confirmed: "Limpieza confirmada"
        }
    }
}

@Model
final class CleanupSession {
    /// Clave del día objetivo (yyyy-MM-dd), p. ej. "2025-11-01".
    @Attribute(.unique) var dayKey: String
    var targetDate: Date
    var createdAt: Date
    var statusRaw: String
    var foundCount: Int
    @Relationship(deleteRule: .cascade, inverse: \Decision.session)
    var decisions: [Decision] = []

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(dayKey: String, targetDate: Date, foundCount: Int) {
        self.dayKey = dayKey
        self.targetDate = targetDate
        self.createdAt = Date()
        self.statusRaw = SessionStatus.pending.rawValue
        self.foundCount = foundCount
    }
}

/// Decisión sobre un elemento. Se enlaza con PHAsset.localIdentifier (identificador persistente de PhotoKit).
/// No se guarda ninguna copia de la foto.
@Model
final class Decision {
    @Attribute(.unique) var assetID: String
    var isVideo: Bool
    var keep: Bool
    var bytes: Int64
    var decidedAt: Date
    /// true solo cuando PhotoKit confirmó el borrado.
    var deleted: Bool
    var session: CleanupSession?

    init(assetID: String, isVideo: Bool, keep: Bool, bytes: Int64) {
        self.assetID = assetID
        self.isVideo = isVideo
        self.keep = keep
        self.bytes = bytes
        self.decidedAt = Date()
        self.deleted = false
    }
}

struct StatsData {
    var photos = 0, videos = 0, kept = 0, deleted = 0
    var freed: Int64 = 0
    var usageDays: Set<Date> = []
    var reviewed: Int { photos + videos }

    init(decisions: [Decision]) {
        let cal = Calendar.current
        for d in decisions {
            if d.isVideo { videos += 1 } else { photos += 1 }
            if d.deleted { deleted += 1; freed += d.bytes } else if d.keep { kept += 1 }
            usageDays.insert(cal.startOfDay(for: d.decidedAt))
        }
    }

    var streak: Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        if !usageDays.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while usageDays.contains(day) {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }
}

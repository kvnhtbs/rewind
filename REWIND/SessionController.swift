import Foundation
import Observation
import Photos
import SwiftData

@MainActor @Observable
final class SessionController {
    let referenceDay: Date
    let yearsBack: Int
    let interval: DateInterval
    private let library: PhotoLibraryService
    private let context: ModelContext

    private(set) var assets: [PHAsset] = []
    private(set) var pending: [PHAsset] = []
    private(set) var decisions: [String: Decision] = [:]
    private(set) var session: CleanupSession?
    var lastError: String?

    init(referenceDay: Date, yearsBack: Int = 1, library: PhotoLibraryService, context: ModelContext) {
        self.referenceDay = referenceDay
        self.yearsBack = yearsBack
        self.interval = DateRules.reviewInterval(for: referenceDay, yearsBack: yearsBack)
        self.library = library
        self.context = context
    }

    // MARK: Carga / reanudación

    func load() {
        assets = library.assets(in: interval)
        let key = DateRules.key(for: interval.start)
        let existing = try? context.fetch(FetchDescriptor<CleanupSession>(
            predicate: #Predicate<CleanupSession> { $0.dayKey == key })).first
        if assets.isEmpty && existing == nil {   // año sin recuerdos: no se crea sesión vacía
            session = nil
            decisions = [:]
            refreshPending()
            return
        }
        let s = existing ?? CleanupSession(dayKey: key, targetDate: interval.start, foundCount: assets.count)
        if existing == nil { context.insert(s) }
        s.foundCount = assets.count
        session = s

        // Decisiones previas (no se vuelven a mostrar). Las de archivos borrados a mano en Fotos
        // simplemente no aparecen en `assets` y se ignoran.
        let ids = Set(assets.map(\.localIdentifier))
        let all = (try? context.fetch(FetchDescriptor<Decision>())) ?? []
        decisions = Dictionary(uniqueKeysWithValues: all.filter { ids.contains($0.assetID) }.map { ($0.assetID, $0) })
        refreshPending()
        updateStatus()
        try? context.save()
    }

    private func refreshPending() { pending = assets.filter { decisions[$0.localIdentifier] == nil } }

    private func updateStatus() {
        guard let s = session, s.status != .confirmed else { return }
        if assets.isEmpty || decisions.isEmpty { s.status = .pending }
        else if pending.isEmpty { s.status = .reviewed }
        else { s.status = .inProgress }
    }

    // MARK: Contadores

    var reviewedCount: Int { decisions.count }
    var photosReviewed: Int { decisions.values.filter { !$0.isVideo }.count }
    var videosReviewed: Int { decisions.values.filter { $0.isVideo }.count }
    var keptCount: Int { decisions.values.filter { $0.keep }.count }
    var markedCount: Int { decisions.values.filter { !$0.keep && !$0.deleted }.count }
    var markedBytes: Int64 { decisions.values.filter { !$0.keep && !$0.deleted }.reduce(0) { $0 + $1.bytes } }
    var markedAssets: [PHAsset] { assets.filter { decisions[$0.localIdentifier].map { !$0.keep && !$0.deleted } ?? false } }
    var keptAssets: [PHAsset] { assets.filter { decisions[$0.localIdentifier]?.keep == true } }
    var canUndo: Bool { decisions.values.contains { !$0.deleted } }

    // MARK: Acciones

    func decide(_ asset: PHAsset, keep: Bool) {
        guard let session, decisions[asset.localIdentifier] == nil else { return }
        let d = Decision(assetID: asset.localIdentifier, isVideo: asset.mediaType == .video,
                         keep: keep, bytes: PhotoLibraryService.fileSize(asset))
        context.insert(d)
        d.session = session
        decisions[d.assetID] = d
        refreshPending(); updateStatus()
        try? context.save()
    }

    func toggle(_ asset: PHAsset) {
        guard let d = decisions[asset.localIdentifier], !d.deleted else { return }
        d.keep.toggle()
        try? context.save()
        decisions[d.assetID] = d   // fuerza actualización de la UI
    }

    func undo() {
        guard let last = decisions.values.filter({ !$0.deleted }).max(by: { $0.decidedAt < $1.decidedAt }) else { return }
        decisions[last.assetID] = nil
        context.delete(last)
        if session?.status == .reviewed { session?.status = .inProgress }
        refreshPending(); updateStatus()
        try? context.save()
    }

    func restart() {
        for d in decisions.values where !d.deleted { context.delete(d) }
        decisions = decisions.filter { $0.value.deleted }
        session?.status = .pending
        refreshPending(); updateStatus()
        try? context.save()
    }

    // MARK: Favoritos (solo lectura: nunca se modifica la marca original)

    var markedFavoriteAssets: [PHAsset] { markedAssets.filter { $0.isFavorite } }
    var markedFavoriteCount: Int { markedFavoriteAssets.count }

    struct DeletionOutcome {
        var deleted = 0
        var deletedBytes: Int64 = 0
        var keptFavorites = 0   // favoritos excluidos del borrado: se conservan
        var unverified = 0      // no verificables: NO se eliminan y siguen marcados
    }

    /// Pide a PhotoKit borrar lo marcado. Solo se invoca tras la confirmación en la UI.
    /// - Parameter includeFavorites: el usuario confirmó expresamente eliminar también los favoritos
    ///   que ve en el resumen. Justo antes de borrar se vuelve a leer el estado de favorito de cada
    ///   elemento: un favorito no confirmado (o que lo sea ahora y no lo era) NO se elimina, y lo que
    ///   no se pueda verificar tampoco.
    /// - Returns: nil si no se eliminó nada por cancelación o error (ver `lastError`).
    func confirmDeletion(includeFavorites: Bool) async -> DeletionOutcome? {
        let targets = decisions.values.filter { !$0.keep && !$0.deleted }
        guard !targets.isEmpty else {
            session?.status = .confirmed
            try? context.save()
            return DeletionOutcome()
        }

        // Favoritos que el usuario vio en el resumen y confirmó eliminar.
        let confirmedFavorites: Set<String> = includeFavorites
            ? Set(markedFavoriteAssets.map(\.localIdentifier)) : []

        // Re-comprobación inmediata del estado de favorito.
        guard let states = library.favoriteStates(for: targets.map(\.assetID)) else {
            lastError = "No se pudo verificar el estado de favoritos (sin acceso a la biblioteca). No se ha eliminado nada."
            return nil
        }

        var toDelete: [Decision] = []
        var toKeep: [Decision] = []
        var outcome = DeletionOutcome()
        for d in targets {
            switch states[d.assetID] {
            case .none:
                outcome.unverified += 1
            case .some(true):
                if confirmedFavorites.contains(d.assetID) { toDelete.append(d) } else { toKeep.append(d) }
            case .some(false):
                toDelete.append(d)
            }
        }

        if !toDelete.isEmpty {
            do {
                try await library.delete(assetIDs: toDelete.map(\.assetID))
            } catch {
                if (error as? PHPhotosError)?.code != .userCancelled {
                    lastError = "No se pudo completar la eliminación: \(error.localizedDescription)"
                }
                return nil
            }
        }

        for d in toDelete {
            d.deleted = true
            outcome.deleted += 1
            outcome.deletedBytes += d.bytes
        }
        for d in toKeep { d.keep = true }   // favoritos excluidos: pasan a "conservar" (la marca de Apple Fotos no se toca)
        outcome.keptFavorites = toKeep.count

        let stillMarked = decisions.values.contains { !$0.keep && !$0.deleted }
        session?.status = stillMarked ? .reviewed : .confirmed
        try? context.save()
        let copy = decisions; decisions = copy   // fuerza actualización de la UI
        return outcome
    }

    // MARK: Navegación por años

    var yearsAgoText: String { yearsBack == 1 ? "hace 1 año" : "hace \(yearsBack) años" }

    /// Año natural (p. ej. 2024) que corresponde a "hace N años".
    func year(yearsBack n: Int) -> Int {
        let start = DateRules.reviewInterval(for: referenceDay, yearsBack: n).start
        return DateRules.calendar.component(.year, from: start)
    }

    /// Siguiente año más antiguo que el actual con fotos o vídeos de este mismo día; salta los
    /// años vacíos. Sin límite artificial: se detiene al pasar el año de la foto más antigua.
    func nextYearWithMemories() -> Int? {
        guard let oldest = library.oldestCaptureDate() else { return nil }
        let oldestYear = DateRules.calendar.component(.year, from: oldest)
        var n = yearsBack + 1
        while year(yearsBack: n) >= oldestYear {
            if !library.refs(in: DateRules.reviewInterval(for: referenceDay, yearsBack: n)).isEmpty { return n }
            n += 1
        }
        return nil
    }
}

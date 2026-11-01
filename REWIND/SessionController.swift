import Photos
import SwiftData
import Foundation

@MainActor @Observable
final class SessionController {
    let interval: DateInterval
    private let library: PhotoLibraryService
    private let context: ModelContext

    private(set) var assets: [PHAsset] = []
    private(set) var pending: [PHAsset] = []
    private(set) var decisions: [String: Decision] = [:]
    private(set) var session: CleanupSession?
    var lastError: String?

    init(referenceDay: Date, library: PhotoLibraryService, context: ModelContext) {
        self.interval = DateRules.reviewInterval(for: referenceDay)
        self.library = library
        self.context = context
    }

    // MARK: Carga / reanudación

    func load() {
        assets = library.assets(in: interval)
        let key = DateRules.key(for: interval.start)
        let existing = try? context.fetch(FetchDescriptor<CleanupSession>(
            predicate: #Predicate { $0.dayKey == key })).first
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

    /// Pide a PhotoKit borrar lo marcado. Solo se invoca tras la doble confirmación en la UI.
    func confirmDeletion() async -> Bool {
        let targets = decisions.values.filter { !$0.keep && !$0.deleted }
        guard !targets.isEmpty else { session?.status = .confirmed; try? context.save(); return true }
        do {
            try await library.delete(assetIDs: targets.map(\.assetID))
            targets.forEach { $0.deleted = true }
            session?.status = .confirmed
            try? context.save()
            let copy = decisions; decisions = copy
            return true
        } catch {
            if (error as? PHPhotosError)?.code != .userCancelled {
                lastError = "No se pudo completar la eliminación: \(error.localizedDescription)"
            }
            return false
        }
    }
}

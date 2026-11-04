import Foundation
import Observation
import Photos
import PhotosUI
import UIKit
import AVFoundation
import CoreLocation

struct AssetRef: Hashable {
    let id: String
    let isVideo: Bool
}

/// Progreso de revisión de la biblioteca. Solo se calcula a partir de datos reales de PhotoKit y de las decisiones guardadas.
struct LibraryProgress: Equatable {
    /// Fotos y vídeos existentes con fecha de captura anterior al límite de "hace un año" (lo único revisable).
    var reviewable: Int
    /// Decisiones cuyo elemento sigue existiendo en la biblioteca (incluye los marcados "por confirmar").
    var existingReviewed: Int
    /// Decisiones cuyo elemento ya no existe (eliminado desde REWIND o desde Fotos).
    var goneReviewed: Int
    /// Marcados para eliminar que siguen existiendo: NO están eliminados todavía.
    var awaitingConfirmation: Int
    /// Acceso limitado a Fotos: los totales son parciales.
    var isPartialAccess: Bool

    var reviewed: Int { existingReviewed + goneReviewed }
    var pending: Int { max(0, reviewable - existingReviewed) }
    var isConsistent: Bool { existingReviewed <= reviewable }

    /// Solo hay porcentaje cuando es fiable: acceso completo, datos coherentes y algo que medir.
    var fraction: Double? {
        guard !isPartialAccess, isConsistent else { return nil }
        let total = reviewed + pending
        guard total > 0 else { return nil }
        return Double(reviewed) / Double(total)
    }
}

struct StreakResult: Equatable {
    var days: Int
    /// true si se alcanzó el límite de cálculo (400 días): la racha real puede ser mayor.
    var capped: Bool
}

/// Acceso a la biblioteca de Fotos (PhotoKit). Todo se ejecuta en el hilo principal;
/// las llamadas pesadas de PhotoKit (carga de imágenes) son asíncronas por sí mismas.
@MainActor
@Observable
final class PhotoLibraryService {
    var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var hasAccess: Bool { status == .authorized || status == .limited }

    @ObservationIgnored private let imageCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private var progressCache: (key: Int, at: Date, value: LibraryProgress)?
    @ObservationIgnored private var streakCache: (key: String, at: Date, value: StreakResult)?
    @ObservationIgnored private var memoriesCache: [String: Bool] = [:]
    @ObservationIgnored private var memoriesStamp = Date()

    /// Límite de días que recorre el cálculo de la racha.
    static let streakLimitDays = 400
    private static let cacheSeconds: TimeInterval = 300

    func refreshStatus() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: Consultas

    private func fetch(_ interval: DateInterval) -> PHFetchResult<PHAsset> {
        guard hasAccess else {
            return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaType == %ld OR mediaType == %ld) AND creationDate >= %@ AND creationDate < %@",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue,
            interval.start as NSDate,
            interval.end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: options)
    }

    func assets(in interval: DateInterval) -> [PHAsset] {
        let result = fetch(interval)
        var out: [PHAsset] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            out.append(asset)
        }
        return out
    }

    func refs(in interval: DateInterval) -> [AssetRef] {
        let result = fetch(interval)
        var out: [AssetRef] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            out.append(AssetRef(id: asset.localIdentifier, isVideo: asset.mediaType == .video))
        }
        return out
    }

    /// Fecha de captura de la foto/vídeo más antiguo de la biblioteca (tope natural de la navegación por años).
    func oldestCaptureDate() -> Date? {
        guard hasAccess else { return nil }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaType == %ld OR mediaType == %ld) AND creationDate >= %@",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue,
            Date.distantPast as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: options).firstObject?.creationDate
    }

    /// Estado de favorito de cada identificador, leído de PhotoKit en este instante (solo lectura:
    /// la marca de favorito nunca se modifica). Devuelve nil si no se puede verificar la biblioteca
    /// (sin permiso). Los identificadores que PhotoKit no devuelve NO aparecen en el diccionario:
    /// son "no verificables".
    func favoriteStates(for ids: [String]) -> [String: Bool]? {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .authorized || current == .limited else { return nil }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var states: [String: Bool] = [:]
        result.enumerateObjects { asset, _, _ in
            states[asset.localIdentifier] = asset.isFavorite
        }
        return states
    }

    /// Tamaño del recurso principal. "fileSize" no es API pública documentada; si falla devuelve 0.
    static func fileSize(_ asset: PHAsset) -> Int64 {
        guard let resource = PHAssetResource.assetResources(for: asset).first else { return 0 }
        let value = resource.value(forKey: "fileSize") as? NSNumber
        return value?.int64Value ?? 0
    }

    func totalSize(of ids: [String]) async -> Int64 {
        guard !ids.isEmpty else { return 0 }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var total: Int64 = 0
        var index = 0
        let count = assets.count
        while index < count {
            total += PhotoLibraryService.fileSize(assets.object(at: index))
            index += 1
            if index % 40 == 0 { await Task.yield() }   // no bloquear la interfaz
        }
        return total
    }

    // MARK: Estadísticas (solo lectura; consultas acotadas y en caché)

    /// ¿Hay al menos un elemento en ese intervalo? (consulta con límite 1, sin recorrer resultados)
    private func hasAssets(in interval: DateInterval) -> Bool {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaType == %ld OR mediaType == %ld) AND creationDate >= %@ AND creationDate < %@",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue,
            interval.start as NSDate,
            interval.end as NSDate)
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: options).count > 0
    }

    /// ¿Había recuerdos que revisar ese día, en cualquier año anterior? (resultado en caché por día)
    private func hasMemories(on day: Date, oldestYear: Int) -> Bool {
        let cacheKey = DateRules.key(for: day)
        if let cached = memoriesCache[cacheKey] { return cached }
        let cal = DateRules.calendar
        var found = false
        var n = 1
        while true {
            let interval = DateRules.reviewInterval(for: day, yearsBack: n)
            if cal.component(.year, from: interval.start) < oldestYear { break }
            if hasAssets(in: interval) { found = true; break }
            n += 1
        }
        memoriesCache[cacheKey] = found
        return found
    }

    /// Racha de días consecutivos con actividad.
    /// - Día con actividad: suma.
    /// - Día sin actividad y SIN recuerdos que revisar: no suma ni rompe.
    /// - Día sin actividad y CON recuerdos: rompe la racha.
    /// - Hoy sin actividad todavía: no rompe (simplemente no suma).
    /// Recorre como máximo `streakLimitDays` días hacia atrás y se detiene antes si llega al primer día con actividad.
    /// Devuelve nil si no se puede calcular (sin acceso a Fotos o tarea cancelada).
    func streak(activeDays: Set<Date>) async -> StreakResult? {
        guard hasAccess else { return nil }
        let cal = DateRules.calendar
        let today = cal.startOfDay(for: Date())
        guard let earliest = activeDays.min() else { return StreakResult(days: 0, capped: false) }

        let key = "\(DateRules.key(for: today))-\(activeDays.hashValue)"
        if let cached = streakCache, cached.key == key, Date().timeIntervalSince(cached.at) < Self.cacheSeconds {
            return cached.value
        }
        if Date().timeIntervalSince(memoriesStamp) > Self.cacheSeconds {
            memoriesCache.removeAll()
            memoriesStamp = Date()
        }

        let oldestYear = oldestCaptureDate().map { cal.component(.year, from: $0) } ?? Int.max
        var days = activeDays.contains(today) ? 1 : 0
        var day = today
        var steps = 0
        var capped = false
        while true {
            guard let previous = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = cal.startOfDay(for: previous)
            steps += 1
            if day < earliest { break }
            if steps > Self.streakLimitDays { capped = true; break }
            if activeDays.contains(day) {
                days += 1
            } else if hasMemories(on: day, oldestYear: oldestYear) {
                break
            }
            if steps % 20 == 0 {
                await Task.yield()
                if Task.isCancelled { return nil }
            }
        }
        let result = StreakResult(days: days, capped: capped)
        streakCache = (key, Date(), result)
        return result
    }

    /// Cuántos de estos identificadores siguen existiendo en la biblioteca (por lotes, sin bloquear la interfaz).
    private func existingCount(of ids: [String]) async -> Int {
        var total = 0
        var index = 0
        while index < ids.count {
            let end = min(index + 500, ids.count)
            total += PHAsset.fetchAssets(withLocalIdentifiers: Array(ids[index..<end]), options: nil).count
            index = end
            await Task.yield()
            if Task.isCancelled { break }
        }
        return total
    }

    /// Progreso de revisión. Devuelve nil sin acceso a Fotos o si la tarea se cancela.
    /// Resultado en caché mientras no cambien las decisiones ni el permiso.
    func libraryProgress(allIDs: [String], markedIDs: [String]) async -> LibraryProgress? {
        guard hasAccess else { return nil }
        let partial = (status == .limited)
        var hasher = Hasher()
        hasher.combine(Set(allIDs))
        hasher.combine(Set(markedIDs))
        hasher.combine(partial)
        let key = hasher.finalize()
        if let cached = progressCache, cached.key == key, Date().timeIntervalSince(cached.at) < Self.cacheSeconds {
            return cached.value
        }

        // Revisables: existentes y anteriores al límite de "hace un año" (los últimos 12 meses no se ofrecen nunca).
        let cutoff = DateRules.reviewInterval(for: Date()).end
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaType == %ld OR mediaType == %ld) AND creationDate >= %@ AND creationDate < %@",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue,
            Date.distantPast as NSDate,
            cutoff as NSDate)
        let reviewable = PHAsset.fetchAssets(with: options).count

        let existing = await existingCount(of: allIDs)
        let awaiting = await existingCount(of: markedIDs)
        guard !Task.isCancelled else { return nil }

        let value = LibraryProgress(
            reviewable: reviewable,
            existingReviewed: existing,
            goneReviewed: max(0, allIDs.count - existing),
            awaitingConfirmation: awaiting,
            isPartialAccess: partial)
        progressCache = (key, Date(), value)
        return value
    }

    // MARK: Carga de medios (miniaturas bajo demanda, sin copias en disco)

    func image(for asset: PHAsset, size: CGSize) async -> UIImage? {
        let key = NSString(string: "\(asset.localIdentifier)-\(Int(size.width))")
        if let cached = imageCache.object(forKey: key) { return cached }

        let loaded: UIImage? = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat   // un único callback
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true       // fotos en iCloud
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        if let loaded { imageCache.setObject(loaded, forKey: key) }
        return loaded
    }

    func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let item: AVPlayerItem? = await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayerItem?, Never>) in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
                continuation.resume(returning: playerItem)
            }
        }
        return item
    }

    func placeName(for asset: PHAsset) async -> String? {
        guard let location = asset.location else { return nil }
        let marks = try? await geocoder.reverseGeocodeLocation(location)
        guard let mark = marks?.first else { return nil }
        let text = [mark.locality, mark.country].compactMap { $0 }.joined(separator: ", ")
        return text.isEmpty ? nil : text
    }

    // MARK: Borrado (solo tras confirmación explícita en la UI)

    /// iOS muestra su propio diálogo de autorización. Los elementos van a "Eliminados recientemente".
    func delete(assetIDs: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            var list: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in
                list.append(asset)
            }
            PHAssetChangeRequest.deleteAssets(list as NSArray)
        }
    }

    func presentLimitedPicker() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.compactMap({ $0.keyWindow?.rootViewController }).first else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }
}

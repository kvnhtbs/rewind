import Foundation
import Observation
import Photos
import UIKit
import AVFoundation
import CoreLocation

struct AssetRef: Hashable {
    let id: String
    let isVideo: Bool
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

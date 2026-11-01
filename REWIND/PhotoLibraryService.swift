import Photos
import UIKit
import AVFoundation
import CoreLocation

struct AssetRef: Hashable {
    let id: String
    let isVideo: Bool
}

@MainActor @Observable
final class PhotoLibraryService {
    var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var hasAccess: Bool { status == .authorized || status == .limited }

    @ObservationIgnored private let imageCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private let geocoder = CLGeocoder()

    func refreshStatus() { status = PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: Consultas

    private func fetch(_ interval: DateInterval) -> PHFetchResult<PHAsset> {
        guard hasAccess else { return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }
        let o = PHFetchOptions()
        o.predicate = NSPredicate(
            format: "(mediaType == %ld OR mediaType == %ld) AND creationDate >= %@ AND creationDate < %@",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue,
            interval.start as NSDate, interval.end as NSDate)
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: o)
    }

    func assets(in interval: DateInterval) -> [PHAsset] {
        let r = fetch(interval)
        var out: [PHAsset] = []
        out.reserveCapacity(r.count)
        r.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    func refs(in interval: DateInterval) -> [AssetRef] {
        let r = fetch(interval)
        var out: [AssetRef] = []
        out.reserveCapacity(r.count)
        r.enumerateObjects { a, _, _ in out.append(AssetRef(id: a.localIdentifier, isVideo: a.mediaType == .video)) }
        return out
    }

    nonisolated static func fileSize(_ asset: PHAsset) -> Int64 {
        // "fileSize" no es API pública documentada pero es de uso muy extendido; si falla, devuelve 0.
        guard let res = PHAssetResource.assetResources(for: asset).first else { return 0 }
        return (res.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    func totalSize(of ids: [String]) async -> Int64 {
        guard !ids.isEmpty else { return 0 }
        return await Task.detached(priority: .utility) {
            let r = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var total: Int64 = 0
            r.enumerateObjects { a, _, _ in total += PhotoLibraryService.fileSize(a) }
            return total
        }.value
    }

    // MARK: Carga de medios (miniaturas bajo demanda, sin copias en disco)

    func image(for asset: PHAsset, size: CGSize) async -> UIImage? {
        let key = "\(asset.localIdentifier)-\(Int(size.width))" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let img: UIImage? = await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true   // fotos en iCloud
            PHImageManager.default().requestImage(for: asset, targetSize: size,
                                                  contentMode: .aspectFit, options: o) { image, _ in
                cont.resume(returning: image)
            }
        }
        if let img { imageCache.setObject(img, forKey: key) }
        return img
    }

    func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { cont in
            let o = PHVideoRequestOptions()
            o.isNetworkAccessAllowed = true
            o.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: o) { item, _ in
                cont.resume(returning: item)
            }
        }
    }

    func placeName(for asset: PHAsset) async -> String? {
        guard let loc = asset.location else { return nil }
        let marks = try? await geocoder.reverseGeocodeLocation(loc)
        guard let m = marks?.first else { return nil }
        let s = [m.locality, m.country].compactMap { $0 }.joined(separator: ", ")
        return s.isEmpty ? nil : s
    }

    // MARK: Borrado (solo tras confirmación explícita en la UI)

    /// iOS muestra su propio diálogo de autorización. Los elementos van a "Eliminados recientemente".
    func delete(assetIDs: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let r = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            PHAssetChangeRequest.deleteAssets(r)
        }
    }

    func presentLimitedPicker() {
        guard let vc = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: vc)
    }
}

import Photos
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import AVFoundation

/// Central PhotoKit gateway: shared `PHCachingImageManager`, in-memory `PHAsset`
/// cache, and concurrent image requests (metadata fetch stays serialized).
enum PhotoKitImageRequester {
    static let listThumbnailSize = CGSize(width: 240, height: 240)

    private static let metadataQueue = DispatchQueue(label: "com.atomapps.photokit.metadata", qos: .userInitiated)
    private static let cachingManager: PHCachingImageManager = {
        let manager = PHCachingImageManager()
        manager.allowsCachingHighQualityImages = false
        return manager
    }()
    private static let assetCache = PHAssetCache()

    static var imageManager: PHCachingImageManager { cachingManager }

    // MARK: - Asset fetch

    static func fetchAsset(identifier: String) async -> PHAsset? {
        await resolveAsset(identifier: identifier)
    }

    static func fetchAssets(identifiers: [String]) async -> [PHAsset] {
        await onMetadataQueue {
            let assets = fetchAssetsSync(identifiers: identifiers)
            assetCache.store(assets)
            return assets
        }
    }

    /// Batch-resolve identifiers into the in-memory asset cache (used by grid prefetch).
    static func warmAssetCache(identifiers: [String]) {
        let missing = identifiers.filter { assetCache.asset(for: $0) == nil }
        guard !missing.isEmpty else { return }
        metadataQueue.async {
            let assets = fetchAssetsSync(identifiers: missing)
            assetCache.store(assets)
        }
    }

    static func sortedAssetIdentifiers(
        _ identifiers: [String],
        mediaType: PHAssetMediaType? = .image
    ) async -> [String] {
        await onMetadataQueue {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var pairs: [(Date, String)] = []
            pairs.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                if let mediaType, asset.mediaType != mediaType { return }
                warmMetadata(for: asset)
                assetCache.store(asset)
                pairs.append((asset.creationDate ?? .distantPast, asset.localIdentifier))
            }
            return pairs.sorted { $0.0 > $1.0 }.map(\.1)
        }
    }

    // MARK: - Image requests

    /// Returns `true` if at least one image (degraded or final) was delivered.
    static func requestThumbnail(
        assetID: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        allowsNetworkAccess: Bool = false,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        onICloudProgress: (@Sendable (Double) -> Void)? = nil,
        onUpdate: @escaping @Sendable (PlatformImage, Bool) -> Void,
        registerRequestID: @escaping @Sendable (PHImageRequestID) -> Void = { _ in }
    ) async -> Bool {
        guard let asset = await resolveAsset(identifier: assetID) else { return false }

        let delivered = DeliveredFlag()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let completionBox = PhotoKitRequestCompletionBox {
                continuation.resume()
            }

            let options = thumbnailOptions(
                allowsNetworkAccess: allowsNetworkAccess,
                deliveryMode: deliveryMode
            )
            if let onICloudProgress {
                options.progressHandler = { progress, _, _, _ in
                    onICloudProgress(progress)
                }
            }

            let requestID = cachingManager.requestImage(
                for: asset,
                targetSize: normalizedSize(targetSize),
                contentMode: contentMode,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                    completionBox.complete()
                    return
                }
                guard let image else {
                    completionBox.complete()
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                delivered.markDelivered()
                onUpdate(image, isDegraded)
                if !isDegraded || deliveryMode != .opportunistic {
                    completionBox.complete()
                }
            }
            registerRequestID(requestID)
        }

        return delivered.wasDelivered
    }

    private final class DeliveredFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var wasDelivered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func markDelivered() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }
    }

    static func requestAVAsset(
        assetID: String,
        allowsNetworkAccess: Bool = true
    ) async -> AVAsset? {
        guard let asset = await resolveAsset(identifier: assetID), asset.mediaType == .video else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.version = .current
            options.isNetworkAccessAllowed = allowsNetworkAccess

            cachingManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: avAsset)
            }
        }
    }

    static func requestImage(
        assetID: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        allowsNetworkAccess: Bool = false,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat,
        resizeMode: PHImageRequestOptionsResizeMode = .fast
    ) async -> PlatformImage? {
        guard let asset = await resolveAsset(identifier: assetID) else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = deliveryMode
            options.resizeMode = resizeMode
            options.isNetworkAccessAllowed = allowsNetworkAccess
            options.isSynchronous = false

            let resumeBox = PhotoKitImageResumeBox(continuation: continuation)
            cachingManager.requestImage(
                for: asset,
                targetSize: normalizedSize(targetSize),
                contentMode: contentMode,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                    resumeBox.resume(nil)
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                if !isDegraded || deliveryMode != .opportunistic {
                    resumeBox.resume(image)
                }
            }
        }
    }

    static func requestFullSizeImage(
        assetID: String,
        allowsNetworkAccess: Bool = true,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat
    ) async -> PlatformImage? {
        guard let asset = await resolveAsset(identifier: assetID) else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = deliveryMode
            options.resizeMode = .none
            options.isNetworkAccessAllowed = allowsNetworkAccess
            options.isSynchronous = false

            let resumeBox = PhotoKitImageResumeBox(continuation: continuation)
            cachingManager.requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                    resumeBox.resume(nil)
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                if !isDegraded || deliveryMode != .opportunistic {
                    resumeBox.resume(image)
                }
            }
        }
    }

    static func startCaching(
        assetIDs: [String],
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        allowsNetworkAccess: Bool = false,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic
    ) {
        metadataQueue.async {
            let assets = fetchAssetsSync(identifiers: assetIDs)
            guard !assets.isEmpty else { return }
            assetCache.store(assets)
            let options = thumbnailOptions(
                allowsNetworkAccess: allowsNetworkAccess,
                deliveryMode: deliveryMode
            )
            cachingManager.startCachingImages(
                for: assets,
                targetSize: normalizedSize(targetSize),
                contentMode: contentMode,
                options: options
            )
        }
    }

    static func stopCaching(
        assetIDs: [String],
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        allowsNetworkAccess: Bool = false,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic
    ) {
        metadataQueue.async {
            let assets = fetchAssetsSync(identifiers: assetIDs)
            guard !assets.isEmpty else { return }
            let options = thumbnailOptions(
                allowsNetworkAccess: allowsNetworkAccess,
                deliveryMode: deliveryMode
            )
            cachingManager.stopCachingImages(
                for: assets,
                targetSize: normalizedSize(targetSize),
                contentMode: contentMode,
                options: options
            )
        }
    }

    static func cancelImageRequest(_ requestID: PHImageRequestID) {
        cachingManager.cancelImageRequest(requestID)
    }

    /// Drop cached `PHAsset` handles for assets edited in Photos and, when the
    /// pixels changed, clear the shared image manager's prefetch cache so the
    /// next request for those assets is not served the pre-edit bitmap.
    /// On-screen cells keep the image they already decoded until their own
    /// reload asks for a new one.
    static func adoptFreshAssets(for identifiers: [String], clearImageCache: Bool) async -> [PHAsset] {
        let unique = Array(Set(identifiers))
        guard !unique.isEmpty else { return [] }
        return await onMetadataQueue {
            if clearImageCache {
                cachingManager.stopCachingImagesForAllAssets()
            }
            assetCache.remove(unique)
            let assets = fetchAssetsSync(identifiers: unique)
            assetCache.store(assets)
            return assets
        }
    }

    /// Runs work on the dedicated metadata queue (asset fetch, resources).
    static func onPhotoKitQueue<T>(_ work: @escaping () -> T) async -> T {
        await onMetadataQueue(work)
    }

    // MARK: - Asset resolution

    private static func resolveAsset(identifier: String) async -> PHAsset? {
        if let cached = assetCache.asset(for: identifier) {
            return cached
        }
        return await onMetadataQueue {
            if let cached = assetCache.asset(for: identifier) {
                return cached
            }
            guard let asset = fetchAssetSync(identifier: identifier) else { return nil }
            assetCache.store(asset)
            return asset
        }
    }

    // MARK: - Sync helpers (metadata queue only)

    private static func fetchAssetSync(identifier: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else { return nil }
        warmMetadata(for: asset)
        return asset
    }

    private static func fetchAssetsSync(identifiers: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            warmMetadata(for: asset)
            assets.append(asset)
        }
        return assets
    }

    /// Touch common properties so PhotoKit prefetches metadata before image decode.
    private static func warmMetadata(for asset: PHAsset) {
        _ = asset.mediaType
        _ = asset.pixelWidth
        _ = asset.pixelHeight
        _ = asset.creationDate
        _ = asset.mediaSubtypes.rawValue
    }

    private static func thumbnailOptions(
        allowsNetworkAccess: Bool,
        deliveryMode: PHImageRequestOptionsDeliveryMode
    ) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowsNetworkAccess
        options.isSynchronous = false
        return options
    }

    private static func normalizedSize(_ targetSize: CGSize) -> CGSize {
        CGSize(
            width: max(1, targetSize.width.rounded()),
            height: max(1, targetSize.height.rounded())
        )
    }

    private static func onMetadataQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            metadataQueue.async {
                continuation.resume(returning: work())
            }
        }
    }
}

// MARK: - PHAsset cache

private final class PHAssetCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: PHAsset] = [:]
    /// Large libraries (10k+ assets) outgrow a small cap fast; every evicted
    /// asset forces a serialized per-identifier `PHAsset.fetchAssets` on the
    /// metadata queue before its thumbnail can even be requested, which is what
    /// makes preview filmstrip flings feel janky. PHAsset instances are cheap
    /// proxies, so keep the whole library resident.
    private let maxCount = 16_000

    func asset(for identifier: String) -> PHAsset? {
        lock.lock()
        defer { lock.unlock() }
        return storage[identifier]
    }

    func store(_ asset: PHAsset) {
        store(asset, for: asset.localIdentifier)
    }

    func store(_ asset: PHAsset, for identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        trimIfNeeded(excluding: identifier)
        storage[identifier] = asset
    }

    func store(_ assets: [PHAsset]) {
        lock.lock()
        defer { lock.unlock() }
        for asset in assets {
            storage[asset.localIdentifier] = asset
        }
        trimIfNeeded(excluding: nil)
    }

    func remove(_ identifiers: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for identifier in identifiers {
            storage.removeValue(forKey: identifier)
        }
    }

    private func trimIfNeeded(excluding: String?) {
        guard storage.count > maxCount else { return }
        let overflow = storage.count - maxCount
        var removed = 0
        for key in storage.keys {
            if key == excluding { continue }
            storage.removeValue(forKey: key)
            removed += 1
            if removed >= overflow { break }
        }
    }
}

private final class PhotoKitRequestCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    private let onComplete: () -> Void

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    func complete() {
        lock.lock()
        defer { lock.unlock() }
        guard !didComplete else { return }
        didComplete = true
        onComplete()
    }
}

private final class PhotoKitImageResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<PlatformImage?, Never>

    init(continuation: CheckedContinuation<PlatformImage?, Never>) {
        self.continuation = continuation
    }

    func resume(_ image: PlatformImage?) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: image)
    }
}

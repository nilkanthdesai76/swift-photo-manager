import Photos
import SwiftUI

/// Sliding-window prefetch state for `LazyVGrid` thumbnail lists.
struct ThumbnailGridPrefetchState {
    private(set) var prefetchedIDs: [String] = []
    private var windowStart = 0

    var windowSize: Int = 32
    var lead: Int = 8
    /// Warm request profile — must mirror the cells' own request profile, or the
    /// `PHCachingImageManager` cache keys never match and the warmup is wasted.
    /// `.opportunistic` so the warmed cache ends up holding the full-quality
    /// frame; cells still paint their first (fast) delivery instantly.
    var deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic
    var allowsNetworkAccess: Bool = true

    init(
        windowSize: Int = 32,
        lead: Int = 8,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        allowsNetworkAccess: Bool = true
    ) {
        self.windowSize = windowSize
        self.lead = lead
        self.deliveryMode = deliveryMode
        self.allowsNetworkAccess = allowsNetworkAccess
    }

    mutating func prefetchInitial(
        assetIDs: [String],
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) {
        prefetch(around: 0, assetIDs: assetIDs, targetSize: targetSize, contentMode: contentMode)
    }

    mutating func updateWindow(
        around index: Int,
        assetIDs: [String],
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) {
        guard !assetIDs.isEmpty else { return }

        let windowEnd = min(assetIDs.count, windowStart + windowSize)
        let needsSlide =
            index < windowStart + lead
            || index > windowEnd - lead
            || prefetchedIDs.isEmpty

        guard needsSlide else { return }
        prefetch(around: index, assetIDs: assetIDs, targetSize: targetSize, contentMode: contentMode)
    }

    mutating func stopAll(
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) {
        guard !prefetchedIDs.isEmpty else { return }
        AssetThumbnailImageLoader.shared.stopCachingThumbnails(
            for: prefetchedIDs,
            targetSize: targetSize,
            contentMode: contentMode,
            deliveryMode: deliveryMode,
            allowsNetworkAccess: allowsNetworkAccess
        )
        prefetchedIDs = []
        windowStart = 0
    }

    private mutating func prefetch(
        around index: Int,
        assetIDs: [String],
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) {
        guard !assetIDs.isEmpty else {
            stopAll(targetSize: targetSize, contentMode: contentMode)
            return
        }

        let clampedIndex = min(max(index, 0), assetIDs.count - 1)
        let start = max(0, clampedIndex - lead)
        let end = min(assetIDs.count, start + windowSize)
        let window = Array(assetIDs[start..<end])

        guard window != prefetchedIDs else {
            windowStart = start
            return
        }

        let oldSet = Set(prefetchedIDs)
        let newSet = Set(window)
        let toStop = prefetchedIDs.filter { !newSet.contains($0) }
        let toStart = window.filter { !oldSet.contains($0) }

        if !toStop.isEmpty {
            AssetThumbnailImageLoader.shared.stopCachingThumbnails(
                for: toStop,
                targetSize: targetSize,
                contentMode: contentMode,
                deliveryMode: deliveryMode,
                allowsNetworkAccess: allowsNetworkAccess
            )
        }
        if !toStart.isEmpty {
            PhotoKitImageRequester.warmAssetCache(identifiers: toStart)
            AssetThumbnailImageLoader.shared.startCachingThumbnails(
                for: toStart,
                targetSize: targetSize,
                contentMode: contentMode,
                deliveryMode: deliveryMode,
                allowsNetworkAccess: allowsNetworkAccess
            )
        }

        prefetchedIDs = window
        windowStart = start
    }
}

enum ThumbnailGridPrefetch {
    static func cacheTargetSize(
        cellSize: CGFloat,
        displayScale: CGFloat,
        maxPixelLength: CGFloat = 250
    ) -> CGSize {
        let pixelLength = min(max(cellSize * displayScale, 180), maxPixelLength)
        return CGSize(width: pixelLength, height: pixelLength)
    }
}


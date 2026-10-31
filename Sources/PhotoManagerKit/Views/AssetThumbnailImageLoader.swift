
private extension PlatformImage {
    var platformScale: CGFloat {
        #if canImport(UIKit)
        return self.scale
        #else
        return 2.0
        #endif
    }
}
import Foundation
import Photos
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Shared thumbnail loader

final class AssetThumbnailImageLoader {
    static let shared = AssetThumbnailImageLoader()

    private let cache = NSCache<NSString, PlatformImage>()
    private let revisionLock = NSLock()
    private var revisionByAssetID: [String: Int] = [:]
    /// Keys that already received a non-degraded PhotoKit frame.
    private let finalQualityKeys = NSCache<NSString, NSNumber>()
    /// Last decoded frame per asset — seeds large cards from filmstrip/grid hits
    /// when the exact size/contentMode key is cold (rapid swipe settle).
    private let lastImageByAssetID = NSCache<NSString, PlatformImage>()
    /// Caps in-flight PhotoKit thumbnail requests so fast filmstrip flings
    /// cannot queue thousands of decodes that stall the main thread.
    /// Home cards + grids share this gate (keep low for warm-launch scroll).
    private let requestGate = ThumbnailRequestGate(limit: 4)

    /// Grid / card thumbs stay under this so previews still use PhotoPreviewImageLoader.
    /// 3x grids and month cards regularly exceed 512px (old limit), so nothing was
    /// cached and scroll/re-entry re-fetched blurry degraded frames.
    private static let maxCachedPixelLength: CGFloat = 1_024

    private init() {
        // Larger libraries scroll through many thumbnails; keep a generous
        // in-memory cache so revisiting a list doesn't re-decode everything.
        // Cost-cap is mandatory: without it, screen-sized preview decode
        // accidentally stored here can retain hundreds of MB until jetsam.
        // Conservative enough for older devices to avoid memory-pressure jetsam.
        cache.countLimit = 1_500
        cache.totalCostLimit = 48 * 1024 * 1024 // 48 MB of decoded bitmaps
        finalQualityKeys.countLimit = 1_500
        lastImageByAssetID.countLimit = 800
    }

    func clearCache() {
        cache.removeAllObjects()
        finalQualityKeys.removeAllObjects()
        lastImageByAssetID.removeAllObjects()
    }

    /// Drop decoded frames for assets whose pixels changed in Photos.
    /// Revision 0 keeps the existing cache key so unrelated thumbnails stay warm.
    func invalidateThumbnails(for assetIDs: [String]) {
        guard !assetIDs.isEmpty else { return }
        revisionLock.lock()
        for id in assetIDs {
            revisionByAssetID[id, default: 0] &+= 1
        }
        revisionLock.unlock()
        for id in assetIDs {
            lastImageByAssetID.removeObject(forKey: id as NSString)
        }
    }

    private func contentRevision(for assetID: String) -> Int {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        return revisionByAssetID[assetID] ?? 0
    }

    func cachedThumbnail(
        for assetID: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) -> PlatformImage? {
        let normalizedSize = normalizedTargetSize(targetSize)
        let key = cacheKey(assetID: assetID, targetSize: normalizedSize, contentMode: contentMode)
        return cache.object(forKey: key)
    }

    /// Any recently decoded frame for this asset (any size). Used to avoid a
    /// blank large swipe card when the filmstrip already showed the thumb.
    func anyCachedThumbnail(for assetID: String) -> PlatformImage? {
        lastImageByAssetID.object(forKey: assetID as NSString)
    }

    func hasFinalQualityThumbnail(
        for assetID: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) -> Bool {
        let normalizedSize = normalizedTargetSize(targetSize)
        let key = cacheKey(assetID: assetID, targetSize: normalizedSize, contentMode: contentMode)
        return finalQualityKeys.object(forKey: key) != nil
    }

    func startCachingThumbnails(
        for assetIDs: [String],
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        allowsNetworkAccess: Bool = false
    ) {
        PhotoKitImageRequester.startCaching(
            assetIDs: assetIDs,
            targetSize: normalizedTargetSize(targetSize),
            contentMode: contentMode,
            allowsNetworkAccess: allowsNetworkAccess,
            deliveryMode: deliveryMode
        )
    }

    func stopCachingThumbnails(
        for assetIDs: [String],
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        allowsNetworkAccess: Bool = false
    ) {
        PhotoKitImageRequester.stopCaching(
            assetIDs: assetIDs,
            targetSize: normalizedTargetSize(targetSize),
            contentMode: contentMode,
            allowsNetworkAccess: allowsNetworkAccess,
            deliveryMode: deliveryMode
        )
    }

    /// A tiny gray placeholder used when PhotoKit cannot deliver a thumbnail
    /// (deleted asset, missing iCloud original, etc.) so the grid never gets
    /// stuck on a shimmer.
    static let fallbackImage: PlatformImage = {
        #if canImport(UIKit)
        UIGraphicsBeginImageContextWithOptions(CGSize(width: 1, height: 1), false, 1)
        defer { UIGraphicsEndImageContext() }
        UIColor.systemGray.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIGraphicsGetImageFromCurrentImageContext() ?? PlatformImage()
        #elseif canImport(AppKit)
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor.systemGray.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        img.unlockFocus()
        return img
        #endif
    }()
    func loadThumbnail(
        for assetID: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        allowsNetworkAccess: Bool = false,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        bypassRequestGate: Bool = false,
        releaseGateAfterFirstFrame: Bool = false,
        onICloudProgress: (@Sendable (Double) -> Void)? = nil,
        onUpdate: @escaping @Sendable (PlatformImage) -> Void
    ) async {
        let normalizedSize = normalizedTargetSize(targetSize)
        let key = cacheKey(assetID: assetID, targetSize: normalizedSize, contentMode: contentMode)

        if let cached = cache.object(forKey: key) {
            lastImageByAssetID.setObject(cached, forKey: assetID as NSString)
            onUpdate(cached)
            // Soft (degraded) frames are fine for instant paint, but still
            // continue into PhotoKit so clear quality can replace them.
            if finalQualityKeys.object(forKey: key) != nil {
                return
            }
        }

        // Preview / iCloud loads must not wait behind filmstrip thumbnails —
        // awaiting the gate on the MainActor makes the large card feel stalled.
        let holdsGate = !bypassRequestGate
        if holdsGate {
            // `false` = cancelled while waiting; no slot held, nothing to release.
            guard await requestGate.acquire() else { return }
        }
        let gateRelease = ThumbnailGateReleaseBox(shouldRelease: holdsGate) {
            self.requestGate.release()
        }
        defer { gateRelease.releaseOnce() }

        guard !Task.isCancelled else { return }

        // Another concurrent load may have finished while we waited for a slot.
        if let cached = cache.object(forKey: key),
           finalQualityKeys.object(forKey: key) != nil {
            onUpdate(cached)
            return
        }

        let handle = ThumbnailRequestHandle()
        let delivered = await withTaskCancellationHandler {
            await PhotoKitImageRequester.requestThumbnail(
                assetID: assetID,
                targetSize: normalizedSize,
                contentMode: contentMode,
                allowsNetworkAccess: allowsNetworkAccess,
                deliveryMode: deliveryMode,
                onICloudProgress: onICloudProgress,
                onUpdate: { [cache, finalQualityKeys, lastImageByAssetID] image, isDegraded in
                    // `.highQualityFormat` / `.fastFormat` deliver a single frame —
                    // treat it as final even when PhotoKit still tags it degraded.
                    let markFinal = !isDegraded || deliveryMode != .opportunistic
                    Self.storeThumbnailInCacheIfNeeded(
                        image,
                        isDegraded: !markFinal,
                        key: key,
                        assetID: assetID,
                        cache: cache,
                        finalQualityKeys: finalQualityKeys,
                        lastImageByAssetID: lastImageByAssetID
                    )
                    onUpdate(image)
                    // Cover rails: free the slot after first usable frame so other
                    // month cards are not stuck behind opportunistic HQ upgrades.
                    if releaseGateAfterFirstFrame {
                        gateRelease.releaseOnce()
                    }
                },
                registerRequestID: { requestID in
                    handle.register(requestID)
                }
            )
        } onCancel: {
            handle.cancel()
        }

        if !delivered && !Task.isCancelled {
            onUpdate(Self.fallbackImage)
        }
    }

    private func normalizedTargetSize(_ targetSize: CGSize) -> CGSize {
        CGSize(
            width: max(1, targetSize.width.rounded()),
            height: max(1, targetSize.height.rounded())
        )
    }

    private func cacheKey(
        assetID: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) -> NSString {
        let sizeKey = "\(Int(targetSize.width))x\(Int(targetSize.height))|\(contentMode.rawValue)"
        let revision = contentRevision(for: assetID)
        if revision == 0 {
            return "\(assetID)|\(sizeKey)" as NSString
        }
        return "\(assetID)|\(revision)|\(sizeKey)" as NSString
    }

    private static func imageCost(_ image: PlatformImage) -> Int {
        let width = Int(image.size.width * image.platformScale)
        let height = Int(image.size.height * image.platformScale)
        return max(width * height * 4, 1)
    }

    private static func storeThumbnailInCacheIfNeeded(
        _ image: PlatformImage,
        isDegraded: Bool,
        key: NSString,
        assetID: String,
        cache: NSCache<NSString, PlatformImage>,
        finalQualityKeys: NSCache<NSString, NSNumber>,
        lastImageByAssetID: NSCache<NSString, PlatformImage>
    ) {
        // Always seed per-asset paint so a filmstrip hit can unblock a large card.
        lastImageByAssetID.setObject(image, forKey: assetID as NSString)

        let maxPixel = max(image.size.width, image.size.height) * image.platformScale
        guard maxPixel <= maxCachedPixelLength else { return }

        if !isDegraded {
            cache.setObject(image, forKey: key, cost: imageCost(image))
            finalQualityKeys.setObject(1, forKey: key)
            return
        }

        // Soft frame only if nothing better is stored yet.
        if finalQualityKeys.object(forKey: key) == nil {
            cache.setObject(image, forKey: key, cost: imageCost(image))
        }
    }
}

/// Limits concurrent PhotoKit thumbnail work so UI stays responsive while scrolling.
/// One-shot gate release so cover loads can free the slot after first paint
/// while opportunistic HQ still finishes in the background.
private final class ThumbnailGateReleaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let shouldRelease: Bool
    private let onRelease: () -> Void

    init(shouldRelease: Bool, onRelease: @escaping () -> Void) {
        self.shouldRelease = shouldRelease
        self.onRelease = onRelease
    }

    func releaseOnce() {
        guard shouldRelease else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        onRelease()
    }
}

private final class ThumbnailGateWaiter: @unchecked Sendable {
    var continuation: CheckedContinuation<Bool, Never>?
    var isCancelled = false
}

private final class ThumbnailRequestGate: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var running = 0
    private var waiters: [ThumbnailGateWaiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// `true` when a slot was acquired — the caller MUST `release()` exactly
    /// once. `false` when the task was cancelled while waiting: no slot was
    /// taken, so no release is needed. Without this, a long filmstrip fling
    /// parks cancelled tasks in the waiter array and freshly-visible cells
    /// queue up behind them.
    func acquire() async -> Bool {
        lock.lock()
        if running < limit {
            running += 1
            lock.unlock()
            return true
        }
        lock.unlock()

        let waiter = ThumbnailGateWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                waiter.continuation = continuation
                if waiter.isCancelled {
                    // Cancellation raced the enqueue — never park this task.
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                if running < limit {
                    running += 1
                    lock.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiters.append(waiter)
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancelWaiter(waiter)
        }
    }

    private func cancelWaiter(_ waiter: ThumbnailGateWaiter) {
        lock.lock()
        waiter.isCancelled = true
        if let index = waiters.firstIndex(where: { $0 === waiter }) {
            waiters.remove(at: index)
            lock.unlock()
            waiter.continuation?.resume(returning: false)
        } else {
            // Not yet enqueued (the enqueue path re-checks `isCancelled`) or
            // already granted a slot (the caller's release handles it).
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        while let next = waiters.first {
            waiters.removeFirst()
            guard !next.isCancelled else { continue }
            lock.unlock()
            next.continuation?.resume(returning: true)
            return
        }
        running = max(0, running - 1)
        lock.unlock()
    }
}

/// Bridges Swift task cancellation to PHImageManager request cancellation,
/// tolerating cancel() arriving before the request ID is known.
private final class ThumbnailRequestHandle {
    private let lock = NSLock()
    private var requestID: PHImageRequestID?
    private var cancelled = false

    func register(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            PhotoKitImageRequester.cancelImageRequest(id)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        lock.unlock()
        if let id {
            PhotoKitImageRequester.cancelImageRequest(id)
        }
    }
}

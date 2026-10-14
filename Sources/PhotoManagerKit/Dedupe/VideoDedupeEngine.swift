import Foundation
import CoreGraphics

#if canImport(Photos)
import Photos
#endif

#if canImport(UIKit)
import UIKit
#endif

/// High-throughput perceptual hashing & duplicate clustering engine for videos.
/// Emits live progress directly to video cards and caches fingerprints to disk.
/// Optimized for large libraries with memory-bounded clustering and fast duration pruning.
public enum VideoDedupeEngine {
    
    #if canImport(Photos)
    /// Scans an array of video assets, checks cached fingerprints, hashes keyframes, and clusters into duplicate/similar groups.
    public static func scanVideoDedupe(
        videos: [PHAsset],
        cache: PhotoManagerCache = .shared,
        sizeRecords: [String: AssetSizeRecord] = [:],
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> (duplicates: [DedupeGroup], similars: [DedupeGroup]) {
        guard !videos.isEmpty else {
            progressHandler?(.done)
            return ([], [])
        }
        
        let totalCount = videos.count
        let fingerprintMap = await fingerprintAndCacheVideos(videos: videos, cache: cache, progressHandler: progressHandler)
        
        var videoRecords: [(asset: PHAsset, fingerprint: VideoFingerprintRecord)] = []
        videoRecords.reserveCapacity(totalCount)
        for video in videos {
            if let fp = fingerprintMap[video.localIdentifier] {
                videoRecords.append((video, fp))
            }
        }
        
        // Cluster into Duplicate & Similar Groups
        // Keep the card in "scanning" state while grouping so it never flips to "Clean" between fingerprinting and results.
        progressHandler?(
            ScanProgress(
                processed: totalCount,
                total: totalCount,
                isScanning: true
            )
        )
        let clustered = await clusterVideos(videoRecords, sizeRecords: sizeRecords, progressHandler: progressHandler)
        await cache.putVideoGroups(duplicates: clustered.duplicates, similars: clustered.similars)
        progressHandler?(ScanProgress(processed: totalCount, total: totalCount, isScanning: false))
        return clustered
    }
    
    /// Warms the video fingerprint cache for all videos without clustering. Safe to run concurrently
    /// with size fetching so that video fingerprinting wall-clock time overlaps the size index build.
    public static func warmVideoFingerprintCache(
        videos: [PHAsset],
        cache: PhotoManagerCache = .shared,
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) async {
        guard !videos.isEmpty else { return }
        _ = await fingerprintAndCacheVideos(videos: videos, cache: cache, progressHandler: progressHandler)
    }
    
    /// Fingerprints every video that isn't already cached, persists the fingerprints, and returns a
    /// complete ID→fingerprint map including previously cached entries.
    private static func fingerprintAndCacheVideos(
        videos: [PHAsset],
        cache: PhotoManagerCache,
        progressHandler: (@Sendable (ScanProgress) -> Void)?
    ) async -> [String: VideoFingerprintRecord] {
        let totalCount = videos.count
        let cachedFingerprints = await cache.getAllVideoFingerprints()
        var resultFingerprints = cachedFingerprints
        resultFingerprints.reserveCapacity(totalCount)
        
        var uncachedVideos: [PHAsset] = []
        uncachedVideos.reserveCapacity(min(totalCount, 2000))
        
        // Step 1: Check in-memory fingerprint cache (< 2ms)
        for video in videos {
            if cachedFingerprints[video.localIdentifier] == nil {
                uncachedVideos.append(video)
            }
        }
        
        let alreadyProcessed = totalCount - uncachedVideos.count
        // Scan is underway (clustering will follow in scanVideoDedupe).
        progressHandler?(
            ScanProgress(
                processed: alreadyProcessed,
                total: totalCount,
                isScanning: true
            )
        )
        
        // Step 2: Fingerprint uncached videos
        if !uncachedVideos.isEmpty {
            let imageManager = PHImageManager.default()
            let requestOptions = PHImageRequestOptions()
            requestOptions.isSynchronous = true
            requestOptions.resizeMode = .fast
            requestOptions.deliveryMode = .fastFormat
            requestOptions.isNetworkAccessAllowed = false
            
            var batch: [String: VideoFingerprintRecord] = [:]
            batch.reserveCapacity(100)
            
            var currentProcessed = alreadyProcessed
            let targetSize = CGSize(width: 32, height: 32)
            
            for video in uncachedVideos {
                if Task.isCancelled { break }
                
                let fp = await computeVideoFingerprint(for: video, manager: imageManager, options: requestOptions, targetSize: targetSize)
                resultFingerprints[video.localIdentifier] = fp
                batch[video.localIdentifier] = fp
                currentProcessed += 1
                
                if batch.count >= 50 {
                    await cache.putVideoFingerprints(batch)
                    batch.removeAll(keepingCapacity: true)
                    await Task.yield()
                }
                
                if currentProcessed % 10 == 0 || currentProcessed == totalCount {
                    progressHandler?(
                        ScanProgress(
                            processed: currentProcessed,
                            total: totalCount,
                            isScanning: currentProcessed < totalCount
                        )
                    )
                }
            }
            
            if !batch.isEmpty {
                await cache.putVideoFingerprints(batch)
            }
        }
        
        return resultFingerprints
    }
    
    private static func computeVideoFingerprint(
        for asset: PHAsset,
        manager: PHImageManager,
        options: PHImageRequestOptions,
        targetSize: CGSize
    ) async -> VideoFingerprintRecord {
        return await withCheckedContinuation { continuation in
            _ = autoreleasepool {
                manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: options
                ) { image, _ in
                    var hash: UInt64 = 0
                    #if canImport(UIKit)
                    if let cgImage = image?.cgImage {
                        hash = PhotoDedupeEngine.computeDHash64(from: cgImage)
                    }
                    #endif
                    if hash == 0 {
                        hash = UInt64(asset.pixelWidth ^ asset.pixelHeight ^ Int(asset.duration * 100))
                    }
                    
                    let fp = VideoFingerprintRecord(
                        duration: asset.duration,
                        keyframeHash: hash,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight
                    )
                    continuation.resume(returning: fp)
                }
            }
        }
    }
    
    private struct CompactVideoItem: Sendable {
        let originalIndex: Int
        let duration: TimeInterval
        let keyframeHash: UInt64
    }
    
    private static func clusterVideos(
        _ list: [(asset: PHAsset, fingerprint: VideoFingerprintRecord)],
        sizeRecords: [String: AssetSizeRecord],
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> (duplicates: [DedupeGroup], similars: [DedupeGroup]) {
        let totalCount = list.count
        guard totalCount > 1 else { return ([], []) }
        
        // Map to lightweight primitive structs
        var compactList: [CompactVideoItem] = []
        compactList.reserveCapacity(totalCount)
        for (i, entry) in list.enumerated() {
            compactList.append(
                CompactVideoItem(
                    originalIndex: i,
                    duration: entry.fingerprint.duration,
                    keyframeHash: entry.fingerprint.keyframeHash
                )
            )
        }
        
        // Sort by duration for fast candidate pruning
        let sorted = compactList.sorted { $0.duration < $1.duration }
        
        var visited = [Bool](repeating: false, count: totalCount)
        var duplicates: [DedupeGroup] = []
        var similars: [DedupeGroup] = []
        
        for i in 0..<sorted.count {
            let current = sorted[i]
            if visited[current.originalIndex] { continue }
            
            var exactIndices: [Int] = [current.originalIndex]
            var similarIndices: [Int] = [current.originalIndex]
            
            for j in (i + 1)..<sorted.count {
                let candidate = sorted[j]
                if visited[candidate.originalIndex] { continue }
                
                let durationDiff = candidate.duration - current.duration
                if durationDiff > 3.0 {
                    // Videos differ by more than 3s; skip further comparisons in sorted array
                    break
                }
                
                let dist = (current.keyframeHash ^ candidate.keyframeHash).nonzeroBitCount
                
                if durationDiff <= 0.2 && dist == 0 {
                    exactIndices.append(candidate.originalIndex)
                } else if durationDiff <= 2.0 && dist <= 8 {
                    similarIndices.append(candidate.originalIndex)
                }
            }
            
            if exactIndices.count > 1 {
                for idx in exactIndices { visited[idx] = true }
                let groupAssets = exactIndices.map { list[$0].asset }
                let group = makeVideoGroup(from: groupAssets, kind: .exactDuplicate, sizeRecords: sizeRecords)
                duplicates.append(group)
            } else if similarIndices.count > 1 {
                for idx in similarIndices { visited[idx] = true }
                let groupAssets = similarIndices.map { list[$0].asset }
                let group = makeVideoGroup(from: groupAssets, kind: .similar, sizeRecords: sizeRecords)
                similars.append(group)
            }
            
            if i % 500 == 0 {
                await Task.yield()
            }
            
            if i % 250 == 0 {
                progressHandler?(
                    ScanProgress(
                        processed: list.count,
                        total: list.count,
                        isScanning: true
                    )
                )
            }
        }
        
        return (duplicates, similars)
    }
    
    private static func makeVideoGroup(
        from videos: [PHAsset],
        kind: DedupeMatchKind,
        sizeRecords: [String: AssetSizeRecord]
    ) -> DedupeGroup {
        let sortedByQuality = videos.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            let resA = a.pixelWidth * a.pixelHeight
            let resB = b.pixelWidth * b.pixelHeight
            return resA > resB
        }
        let bestID = sortedByQuality.first?.localIdentifier ?? videos[0].localIdentifier
        
        let items: [DedupeAssetItem] = videos.map { asset in
            let record = sizeRecords[asset.localIdentifier] ?? StorageCalculator.resolveExactSize(for: asset)
            let total = record.totalBytes
            let isBest = asset.localIdentifier == bestID
            
            return DedupeAssetItem(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.duration,
                totalBytes: total,
                stillBytes: 0,
                videoBytes: total,
                isLivePhoto: false,
                isVideo: true,
                isFavorite: asset.isFavorite,
                isSelectedForDeletion: !isBest
            )
        }
        
        return DedupeGroup(
            id: UUID().uuidString,
            matchKind: kind,
            items: items,
            bestAssetID: bestID
        )
    }
    #endif
}

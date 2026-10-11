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
        let cachedFingerprints = await cache.getAllVideoFingerprints()
        var videoRecords: [(asset: PHAsset, fingerprint: VideoFingerprintRecord)] = []
        videoRecords.reserveCapacity(totalCount)
        
        var uncachedVideos: [PHAsset] = []
        uncachedVideos.reserveCapacity(totalCount)
        
        // Step 1: Check in-memory fingerprint cache (< 2ms)
        for video in videos {
            if let fp = cachedFingerprints[video.localIdentifier] {
                videoRecords.append((video, fp))
            } else {
                uncachedVideos.append(video)
            }
        }
        
        let alreadyProcessed = videoRecords.count
        progressHandler?(
            ScanProgress(
                processed: alreadyProcessed,
                total: totalCount,
                isScanning: !uncachedVideos.isEmpty
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
                videoRecords.append((video, fp))
                batch[video.localIdentifier] = fp
                currentProcessed += 1
                
                if batch.count >= 50 {
                    await cache.putVideoFingerprints(batch)
                    batch.removeAll(keepingCapacity: true)
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
        
        progressHandler?(ScanProgress(processed: totalCount, total: totalCount, isScanning: false))
        
        // Step 3: Cluster into Duplicate & Similar Groups
        let clustered = clusterVideos(videoRecords, sizeRecords: sizeRecords)
        await cache.putVideoGroups(duplicates: clustered.duplicates, similars: clustered.similars)
        return clustered
    }
    
    private static func computeVideoFingerprint(
        for asset: PHAsset,
        manager: PHImageManager,
        options: PHImageRequestOptions,
        targetSize: CGSize
    ) async -> VideoFingerprintRecord {
        return await withCheckedContinuation { continuation in
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
    
    private static func clusterVideos(
        _ list: [(asset: PHAsset, fingerprint: VideoFingerprintRecord)],
        sizeRecords: [String: AssetSizeRecord]
    ) -> (duplicates: [DedupeGroup], similars: [DedupeGroup]) {
        // Sort by duration for fast candidate pruning
        let sorted = list.sorted { $0.fingerprint.duration < $1.fingerprint.duration }
        
        var visited = Set<String>()
        var duplicates: [DedupeGroup] = []
        var similars: [DedupeGroup] = []
        
        for i in 0..<sorted.count {
            let current = sorted[i]
            let currentID = current.asset.localIdentifier
            if visited.contains(currentID) { continue }
            
            var exactMatches: [PHAsset] = [current.asset]
            var similarMatches: [PHAsset] = [current.asset]
            
            for j in (i + 1)..<sorted.count {
                let candidate = sorted[j]
                let candID = candidate.asset.localIdentifier
                if visited.contains(candID) { continue }
                
                let durationDiff = abs(candidate.fingerprint.duration - current.fingerprint.duration)
                if durationDiff > 3.0 {
                    // Videos differ by more than 3s; skip further comparisons in sorted array
                    break
                }
                
                let dist = PhotoDedupeEngine.hammingDistance(current.fingerprint.keyframeHash, candidate.fingerprint.keyframeHash)
                
                if durationDiff <= 0.2 && dist == 0 {
                    exactMatches.append(candidate.asset)
                    visited.insert(candID)
                } else if durationDiff <= 2.0 && dist <= 8 {
                    similarMatches.append(candidate.asset)
                    visited.insert(candID)
                }
            }
            
            if exactMatches.count > 1 {
                visited.insert(currentID)
                let group = makeVideoGroup(from: exactMatches, kind: .exactDuplicate, sizeRecords: sizeRecords)
                duplicates.append(group)
            } else if similarMatches.count > 1 {
                visited.insert(currentID)
                let group = makeVideoGroup(from: similarMatches, kind: .similar, sizeRecords: sizeRecords)
                similars.append(group)
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
            let record = sizeRecords[asset.localIdentifier]
            let total = record?.totalBytes ?? Int64(asset.duration * 2_500_000)
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

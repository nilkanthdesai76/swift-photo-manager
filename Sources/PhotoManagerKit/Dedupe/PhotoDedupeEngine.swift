import Foundation
import CoreGraphics

#if canImport(Photos)
import Photos
#endif

#if canImport(UIKit)
import UIKit
#endif

/// High-throughput perceptual hashing & duplicate clustering engine for photos.
/// Emits live progress directly to UI cards and persists hashes to disk cache.
public enum PhotoDedupeEngine {
    
    #if canImport(Photos)
    /// Scans an array of photos, checking cache first, hashing uncached photos, and clustering into duplicate/similar groups.
    public static func scanPhotoDedupe(
        assets: [PHAsset],
        cache: PhotoManagerCache = .shared,
        sizeRecords: [String: AssetSizeRecord] = [:],
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> (duplicates: [DedupeGroup], similars: [DedupeGroup]) {
        guard !assets.isEmpty else {
            progressHandler?(.done)
            return ([], [])
        }
        
        let totalCount = assets.count
        let cachedHashes = await cache.getAllPhotoHashes()
        var assetHashes: [(asset: PHAsset, hash: UInt64)] = []
        assetHashes.reserveCapacity(totalCount)
        
        var uncachedAssets: [PHAsset] = []
        uncachedAssets.reserveCapacity(totalCount)
        
        // Step 1: Check in-memory hash cache (< 2ms)
        for asset in assets {
            if let h = cachedHashes[asset.localIdentifier] {
                assetHashes.append((asset, h))
            } else {
                uncachedAssets.append(asset)
            }
        }
        
        let alreadyProcessed = assetHashes.count
        progressHandler?(
            ScanProgress(
                processed: alreadyProcessed,
                total: totalCount,
                isScanning: !uncachedAssets.isEmpty
            )
        )
        
        // Step 2: Compute hashes for uncached assets using bounded background workers
        if !uncachedAssets.isEmpty {
            let imageManager = PHImageManager.default()
            let requestOptions = PHImageRequestOptions()
            requestOptions.isSynchronous = true
            requestOptions.resizeMode = .fast
            requestOptions.deliveryMode = .fastFormat
            requestOptions.isNetworkAccessAllowed = false
            
            var batchHashes: [String: UInt64] = [:]
            batchHashes.reserveCapacity(500)
            
            var currentProcessed = alreadyProcessed
            let targetSize = CGSize(width: 32, height: 32) // Ultra-fast thumbnail
            
            for asset in uncachedAssets {
                if Task.isCancelled { break }
                
                let hash = await computeHash(for: asset, manager: imageManager, options: requestOptions, targetSize: targetSize)
                assetHashes.append((asset, hash))
                batchHashes[asset.localIdentifier] = hash
                currentProcessed += 1
                
                if batchHashes.count >= 250 {
                    await cache.putPhotoHashes(batchHashes)
                    batchHashes.removeAll(keepingCapacity: true)
                }
                
                if currentProcessed % 25 == 0 || currentProcessed == totalCount {
                    progressHandler?(
                        ScanProgress(
                            processed: currentProcessed,
                            total: totalCount,
                            isScanning: currentProcessed < totalCount
                        )
                    )
                }
            }
            
            if !batchHashes.isEmpty {
                await cache.putPhotoHashes(batchHashes)
            }
        }
        
        progressHandler?(ScanProgress(processed: totalCount, total: totalCount, isScanning: false))
        
        // Step 3: Cluster into Duplicate & Similar Groups
        let clustered = clusterAssets(assetHashes, sizeRecords: sizeRecords)
        await cache.putPhotoGroups(duplicates: clustered.duplicates, similars: clustered.similars)
        return clustered
    }
    
    // MARK: - Perceptual Difference Hashing (dHash)
    
    private static func computeHash(
        for asset: PHAsset,
        manager: PHImageManager,
        options: PHImageRequestOptions,
        targetSize: CGSize
    ) async -> UInt64 {
        return await withCheckedContinuation { continuation in
            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                #if canImport(UIKit)
                if let cgImage = image?.cgImage {
                    let h = computeDHash64(from: cgImage)
                    continuation.resume(returning: h)
                    return
                }
                #endif
                // Fallback deterministic hash from aspect ratio + date if image unavailable
                let fallback = UInt64(asset.pixelWidth ^ asset.pixelHeight ^ Int(asset.creationDate?.timeIntervalSince1970 ?? 0))
                continuation.resume(returning: fallback)
            }
        }
    }
    
    /// Computes 64-bit gradient difference hash (dHash) from a CGImage.
    public static func computeDHash64(from image: CGImage) -> UInt64 {
        let width = 9
        let height = 8
        let bytesPerPixel = 1
        let bytesPerRow = width * bytesPerPixel
        var rawData = [UInt8](repeating: 0, count: width * height)
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var hash: UInt64 = 0
        for y in 0..<height {
            let rowOffset = y * width
            for x in 0..<8 {
                let left = rawData[rowOffset + x]
                let right = rawData[rowOffset + x + 1]
                if left > right {
                    hash |= (1 << (y * 8 + x))
                }
            }
        }
        return hash
    }
    
    /// Computes Hamming distance between two 64-bit hashes.
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
    
    // MARK: - Clustering
    
    private static func clusterAssets(
        _ list: [(asset: PHAsset, hash: UInt64)],
        sizeRecords: [String: AssetSizeRecord]
    ) -> (duplicates: [DedupeGroup], similars: [DedupeGroup]) {
        // Sort chronologically for sliding-window evaluation
        let sorted = list.sorted { ($0.asset.creationDate ?? .distantPast) < ($1.asset.creationDate ?? .distantPast) }
        
        var visited = Set<String>()
        var duplicates: [DedupeGroup] = []
        var similars: [DedupeGroup] = []
        
        let timeWindow: TimeInterval = 86400 // 24-hour temporal gating
        
        for i in 0..<sorted.count {
            let current = sorted[i]
            let currentID = current.asset.localIdentifier
            if visited.contains(currentID) { continue }
            
            var exactMatches: [PHAsset] = [current.asset]
            var similarMatches: [PHAsset] = [current.asset]
            
            let currentDate = current.asset.creationDate ?? Date()
            
            for j in (i + 1)..<sorted.count {
                let candidate = sorted[j]
                let candID = candidate.asset.localIdentifier
                if visited.contains(candID) { continue }
                
                let candDate = candidate.asset.creationDate ?? Date()
                if abs(candDate.timeIntervalSince(currentDate)) > timeWindow {
                    break // Exceeded temporal window
                }
                
                let dist = hammingDistance(current.hash, candidate.hash)
                if dist == 0 {
                    exactMatches.append(candidate.asset)
                    visited.insert(candID)
                } else if dist <= 8 {
                    similarMatches.append(candidate.asset)
                    visited.insert(candID)
                }
            }
            
            if exactMatches.count > 1 {
                visited.insert(currentID)
                let group = makeGroup(from: exactMatches, kind: .exactDuplicate, sizeRecords: sizeRecords)
                duplicates.append(group)
            } else if similarMatches.count > 1 {
                visited.insert(currentID)
                let group = makeGroup(from: similarMatches, kind: .similar, sizeRecords: sizeRecords)
                similars.append(group)
            }
        }
        
        return (duplicates, similars)
    }
    
    private static func makeGroup(
        from assets: [PHAsset],
        kind: DedupeMatchKind,
        sizeRecords: [String: AssetSizeRecord]
    ) -> DedupeGroup {
        // Determine "Best" asset (favorites first, then largest pixel resolution)
        let sortedByQuality = assets.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            let resA = a.pixelWidth * a.pixelHeight
            let resB = b.pixelWidth * b.pixelHeight
            return resA > resB
        }
        let bestID = sortedByQuality.first?.localIdentifier ?? assets[0].localIdentifier
        
        let items: [DedupeAssetItem] = assets.map { asset in
            let record = sizeRecords[asset.localIdentifier]
            let total = record?.totalBytes ?? 2_500_000
            let still = record?.stillBytes ?? total
            let video = record?.videoBytes ?? 0
            let isBest = asset.localIdentifier == bestID
            
            return DedupeAssetItem(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.duration,
                totalBytes: total,
                stillBytes: still,
                videoBytes: video,
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                isVideo: false,
                isFavorite: asset.isFavorite,
                isSelectedForDeletion: !isBest // Auto-select redundant copies for deletion
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

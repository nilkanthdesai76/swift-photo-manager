import Foundation

#if canImport(Photos)
import Photos
#endif

/// Two-tier storage calculator:
/// Tier 1: Instant zero-IPC estimate in < 50ms for immediate storage bar rendering.
/// Tier 2: Background exact KVC refinement (3 workers, autoreleasepool, persistent cache).
public enum StorageCalculator {
    
    #if canImport(Photos)
    /// Computes instant storage overview from in-memory PHAsset metadata in < 50ms.
    public static func computeInstantEstimate(
        photos: [PHAsset],
        videos: [PHAsset]
    ) -> LibraryStorageOverview {
        var pBytes: Int64 = 0
        var lpStillBytes: Int64 = 0
        var lpVideoBytes: Int64 = 0
        var lpCount = 0
        var regularPhotoCount = 0
        
        for asset in photos {
            let isLive = asset.mediaSubtypes.contains(.photoLive)
            let still = estimateImageBytes(
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                isPanorama: asset.mediaSubtypes.contains(.photoPanorama),
                isHDR: asset.mediaSubtypes.contains(.photoHDR)
            )
            
            if isLive {
                lpCount += 1
                lpStillBytes += still
                lpVideoBytes += 3_200_000 // Apple Live Photo paired 1080p HEVC video
            } else {
                regularPhotoCount += 1
                pBytes += still
            }
        }
        
        var vBytes: Int64 = 0
        for asset in videos {
            let bytes = estimateVideoBytes(
                duration: asset.duration,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                isSlowMo: asset.mediaSubtypes.contains(.videoHighFrameRate),
                isTimelapse: asset.mediaSubtypes.contains(.videoTimelapse)
            )
            vBytes += bytes
        }
        
        let total = pBytes + lpStillBytes + lpVideoBytes + vBytes
        let count = photos.count + videos.count
        
        return LibraryStorageOverview(
            totalBytes: total,
            totalCount: count,
            photosBytes: pBytes,
            photosCount: regularPhotoCount,
            livePhotosTotalBytes: lpStillBytes + lpVideoBytes,
            livePhotosStillBytes: lpStillBytes,
            livePhotosVideoBytes: lpVideoBytes,
            livePhotosCount: lpCount,
            videosBytes: vBytes,
            videosCount: videos.count,
            otherBytes: 0,
            otherCount: 0,
            isEstimated: true
        )
    }
    
    /// Resolves exact byte size breakdown for a single PHAsset using PhotoKit KVC.
    public static func resolveExactSize(for asset: PHAsset) -> AssetSizeRecord {
        return autoreleasepool {
            let resources = PHAssetResource.assetResources(for: asset)
            let isLive = asset.mediaSubtypes.contains(.photoLive)
            
            var resourceMap: [PHAssetResourceType: Int64] = [:]
            resourceMap.reserveCapacity(resources.count)
            var maxFallback: Int64 = 0
            
            for res in resources {
                if let size = res.value(forKey: "fileSize") as? Int64, size > 0 {
                    if resourceMap[res.type] == nil {
                        resourceMap[res.type] = size
                    }
                    if size > maxFallback {
                        maxFallback = size
                    }
                }
            }
            
            switch asset.mediaType {
            case .video:
                let v = resourceMap[.fullSizeVideo] ?? resourceMap[.video] ?? maxFallback
                return AssetSizeRecord(
                    totalBytes: v,
                    stillBytes: 0,
                    videoBytes: v,
                    isLivePhoto: false,
                    modificationDate: asset.modificationDate ?? asset.creationDate
                )
            case .image:
                let still = resourceMap[.fullSizePhoto] ?? resourceMap[.photo] ?? 0
                let paired = isLive ? (resourceMap[.fullSizePairedVideo] ?? resourceMap[.pairedVideo] ?? 0) : 0
                var total = still + paired
                if total == 0 { total = maxFallback }
                let resolvedStill = isLive ? (still > 0 ? still : total) : total
                
                return AssetSizeRecord(
                    totalBytes: total,
                    stillBytes: resolvedStill,
                    videoBytes: paired,
                    isLivePhoto: isLive,
                    modificationDate: asset.modificationDate ?? asset.creationDate
                )
            default:
                return AssetSizeRecord(
                    totalBytes: maxFallback,
                    stillBytes: maxFallback,
                    videoBytes: 0,
                    isLivePhoto: false,
                    modificationDate: asset.modificationDate ?? asset.creationDate
                )
            }
        }
    }
    
    // MARK: - Codec Estimation Profiles
    
    private static func estimateImageBytes(
        width: Int,
        height: Int,
        isPanorama: Bool,
        isHDR: Bool
    ) -> Int64 {
        let pixels = max(1, width * height)
        if isPanorama {
            return Int64(Double(pixels) * 0.35)
        }
        if pixels >= 45_000_000 {
            return 6_800_000 // 48MP
        } else if pixels >= 20_000_000 {
            return 3_800_000 // 24MP
        } else if pixels >= 10_000_000 {
            return isHDR ? 2_800_000 : 2_400_000 // 12MP
        } else if pixels >= 2_000_000 {
            return 1_200_000 // 1080p
        } else {
            return max(150_000, Int64(Double(pixels) * 0.25))
        }
    }
    
    private static func estimateVideoBytes(
        duration: TimeInterval,
        width: Int,
        height: Int,
        isSlowMo: Bool,
        isTimelapse: Bool
    ) -> Int64 {
        guard duration > 0 else { return 5_000_000 }
        if isTimelapse { return Int64(duration * 1_600_000) }
        if isSlowMo { return Int64(duration * 8_500_000) }
        
        let maxDim = max(width, height)
        let bytesPerSec: Double = (maxDim >= 3800) ? 14_500_000 : (maxDim >= 1900 ? 2_400_000 : 1_200_000)
        return max(500_000, Int64(duration * bytesPerSec))
    }
    #endif
}

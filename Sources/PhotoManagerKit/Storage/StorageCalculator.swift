import Foundation

#if canImport(Photos)
import Photos
#endif

/// KVC-only storage calculator for Apple Photo Library.
///
/// Strictly uses Key-Value Coding (`value(forKey: "fileSize")`) on `PHAssetResource`
/// metadata without downloading asset bytes or relying on heuristic approximations.
public enum StorageCalculator {
    
    #if canImport(Photos)
    /// Computes the library storage overview strictly from resolved KVC size records.
    public static func computeOverview(
        photos: [PHAsset],
        videos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord]
    ) -> LibraryStorageOverview {
        var pBytes: Int64 = 0
        var lpStillBytes: Int64 = 0
        var lpVideoBytes: Int64 = 0
        var lpCount = 0
        var regularPhotoCount = 0
        
        for asset in photos {
            let isLive = asset.mediaSubtypes.contains(.photoLive)
            let record = sizeRecords[asset.localIdentifier]
            
            if isLive {
                lpCount += 1
                if let rec = record {
                    lpStillBytes += rec.stillBytes
                    lpVideoBytes += rec.videoBytes
                }
            } else {
                regularPhotoCount += 1
                if let rec = record {
                    pBytes += rec.totalBytes
                }
            }
        }
        
        var vBytes: Int64 = 0
        for asset in videos {
            if let rec = sizeRecords[asset.localIdentifier] {
                vBytes += rec.totalBytes
            }
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
            isEstimated: false
        )
    }
    
    /// Resolves exact byte size breakdown for a single PHAsset using PhotoKit KVC only.
    public static func resolveExactSize(for asset: PHAsset) -> AssetSizeRecord {
        return autoreleasepool {
            let resources = PHAssetResource.assetResources(for: asset)
            let isLive = asset.mediaSubtypes.contains(.photoLive)
            
            var resourceMap: [PHAssetResourceType: Int64] = [:]
            resourceMap.reserveCapacity(resources.count)
            var maxKvcSize: Int64 = 0
            
            for res in resources {
                let size = res.kvcFileSize
                if size > 0 {
                    if resourceMap[res.type] == nil {
                        resourceMap[res.type] = size
                    }
                    if size > maxKvcSize {
                        maxKvcSize = size
                    }
                }
            }
            
            switch asset.mediaType {
            case .video:
                let v = resourceMap[.fullSizeVideo] ?? resourceMap[.video] ?? maxKvcSize
                return AssetSizeRecord(
                    totalBytes: v,
                    stillBytes: 0,
                    videoBytes: v,
                    isLivePhoto: false,
                    modificationDate: asset.modificationDate ?? asset.creationDate
                )
                
            case .image:
                var still = resourceMap[.fullSizePhoto] ?? resourceMap[.photo] ?? 0
                if #available(macOS 14, iOS 17, *) {
                    if still == 0, let proxy = resourceMap[.photoProxy] {
                        still = proxy
                    }
                }
                let paired = isLive ? (resourceMap[.fullSizePairedVideo] ?? resourceMap[.pairedVideo] ?? 0) : 0
                
                var total = still + paired
                if total == 0 { total = maxKvcSize }
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
                    totalBytes: maxKvcSize,
                    stillBytes: maxKvcSize,
                    videoBytes: 0,
                    isLivePhoto: false,
                    modificationDate: asset.modificationDate ?? asset.creationDate
                )
            }
        }
    }
    
    /// Resolves KVC sizes for a batch of assets with autoreleasepool management.
    public static func resolveBatch(assets: [PHAsset]) -> [String: AssetSizeRecord] {
        var results: [String: AssetSizeRecord] = [:]
        results.reserveCapacity(assets.count)
        for asset in assets {
            results[asset.localIdentifier] = resolveExactSize(for: asset)
        }
        return results
    }
    #endif
}

#if canImport(Photos)
extension PHAssetResource {
    /// Safe KVC extraction for `fileSize` supporting Int64, Int, UInt64, and NSNumber.
    /// Never downloads bytes from iCloud or disk.
    public var kvcFileSize: Int64 {
        // Int64 / Int / UInt / NSNumber all show up across iOS and macOS versions
        if let size = self.value(forKey: "fileSize") as? Int64, size > 0 {
            return size
        }
        if let size = self.value(forKey: "fileSize") as? Int, size > 0 {
            return Int64(size)
        }
        if let size = self.value(forKey: "fileSize") as? UInt64, size > 0 {
            return Int64(size)
        }
        if let number = self.value(forKey: "fileSize") as? NSNumber {
            let size = number.int64Value
            if size > 0 { return size }
        }
        return 0
    }
}
#endif

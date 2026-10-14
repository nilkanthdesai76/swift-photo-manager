import Foundation

#if canImport(Photos)
import Photos
#endif

/// Scanner for system smart albums, screen recordings, and threshold-based collections (large, old media).
public enum SmartAlbumScanner {
    
    #if canImport(Photos)
    /// Fetches all system smart albums applicable to photos.
    public static func fetchPhotoSmartAlbums(
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> [SmartAlbumItem] {
        var items: [SmartAlbumItem] = []
        
        let subtypes: [(PHAssetCollectionSubtype, String, String, String)] = [
            (.smartAlbumScreenshots, "Screenshots", "camera.viewfinder", "indigo"),
            (.smartAlbumSelfPortraits, "Selfies", "person.crop.square", "teal"),
            (.smartAlbumLivePhotos, "Live Photos", "livephoto", "purple"),
            (.smartAlbumPanoramas, "Panoramas", "pano", "blue"),
            (.smartAlbumFavorites, "Favorites", "heart.fill", "pink"),
            (.smartAlbumBursts, "Bursts", "square.stack.3d.down.right", "orange")
        ]
        
        for (subtype, title, icon, color) in subtypes {
            autoreleasepool {
                let collections = PHAssetCollection.fetchAssetCollections(
                    with: .smartAlbum,
                    subtype: subtype,
                    options: nil
                )
                
                if let col = collections.firstObject {
                    let assets = PHAsset.fetchAssets(in: col, options: nil)
                    guard assets.count > 0 else { return }
                    
                    var assetIDs: [String] = []
                    assetIDs.reserveCapacity(assets.count)
                    var totalBytes: Int64 = 0
                    
                    assets.enumerateObjects { asset, _, _ in
                        assetIDs.append(asset.localIdentifier)
                        let size = sizeRecords[asset.localIdentifier]?.totalBytes ?? 2_500_000
                        totalBytes += size
                    }
                    
                    items.append(
                        SmartAlbumItem(
                            id: col.localIdentifier,
                            title: title,
                            count: assets.count,
                            totalBytes: totalBytes,
                            sfSymbol: icon,
                            accentColorName: color,
                            assetIDs: assetIDs,
                            newestAssetID: assetIDs.first
                        )
                    )
                }
            }
        }
        
        return items
    }
    
    /// Fetches Video system groups: All Videos and Screen Recordings.
    public static func fetchVideoSmartAlbums(
        videos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> [SmartAlbumItem] {
        var items: [SmartAlbumItem] = []
        guard !videos.isEmpty else { return [] }
        
        // 1. All Videos Card
        var allIDs: [String] = []
        allIDs.reserveCapacity(videos.count)
        var allBytes: Int64 = 0
        
        var screenRecordingIDs: [String] = []
        var screenRecordingBytes: Int64 = 0
        
        for v in videos {
            allIDs.append(v.localIdentifier)
            let b = sizeRecords[v.localIdentifier]?.totalBytes ?? Int64(v.duration * 2_500_000)
            allBytes += b
            
            // Check for Screen Recording indicator
            let isScreenRecording = v.mediaSubtypes.contains(.videoStreamed) ||
                                    v.mediaSubtypes.contains(.videoHighFrameRate) == false && (v.pixelWidth == 1170 || v.pixelWidth == 1179 || v.pixelWidth == 1284 || v.pixelWidth == 1290 || v.pixelWidth == 828 || v.pixelWidth == 750)
            if isScreenRecording {
                screenRecordingIDs.append(v.localIdentifier)
                screenRecordingBytes += b
            }
        }
        
        items.append(
            SmartAlbumItem(
                id: "all_videos",
                title: "All Videos",
                count: videos.count,
                totalBytes: allBytes,
                sfSymbol: "video.fill",
                accentColorName: "orange",
                assetIDs: allIDs,
                newestAssetID: allIDs.first
            )
        )
        
        if !screenRecordingIDs.isEmpty {
            items.append(
                SmartAlbumItem(
                    id: "screen_recordings",
                    title: "Screen Recordings",
                    count: screenRecordingIDs.count,
                    totalBytes: screenRecordingBytes,
                    sfSymbol: "record.circle",
                    accentColorName: "red",
                    assetIDs: screenRecordingIDs,
                    newestAssetID: screenRecordingIDs.first
                )
            )
        }
        
        return items
    }
    
    /// Filters photos for "Large Photos" (> 10 MB).
    public static func filterLargePhotos(
        photos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> SmartAlbumItem? {
        let thresholdBytes: Int64 = 10 * 1024 * 1024 // 10 MB
        var matchedIDs: [String] = []
        var matchedBytes: Int64 = 0
        
        for p in photos {
            let bytes = sizeRecords[p.localIdentifier]?.totalBytes ?? 0
            if bytes >= thresholdBytes {
                matchedIDs.append(p.localIdentifier)
                matchedBytes += bytes
            }
        }
        
        guard !matchedIDs.isEmpty else { return nil }
        return SmartAlbumItem(
            id: "large_photos",
            title: "Large Photos (> 10 MB)",
            count: matchedIDs.count,
            totalBytes: matchedBytes,
            sfSymbol: "arrow.up.left.and.arrow.down.right",
            accentColorName: "blue",
            assetIDs: matchedIDs,
            newestAssetID: matchedIDs.first
        )
    }
    
    /// Filters photos for "Old Photos" (older than 3 years).
    public static func filterOldPhotos(
        photos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> SmartAlbumItem? {
        let threeYearsAgo = Date().addingTimeInterval(-3 * 365.25 * 86400)
        var matchedIDs: [String] = []
        var matchedBytes: Int64 = 0
        
        for p in photos {
            if let date = p.creationDate, date < threeYearsAgo {
                matchedIDs.append(p.localIdentifier)
                let bytes = sizeRecords[p.localIdentifier]?.totalBytes ?? 2_500_000
                matchedBytes += bytes
            }
        }
        
        guard !matchedIDs.isEmpty else { return nil }
        return SmartAlbumItem(
            id: "old_photos",
            title: "Old Photos (> 3 Years)",
            count: matchedIDs.count,
            totalBytes: matchedBytes,
            sfSymbol: "clock.arrow.circlepath",
            accentColorName: "purple",
            assetIDs: matchedIDs,
            newestAssetID: matchedIDs.first
        )
    }
    
    /// Filters videos for "Large Videos" (> 200 MB).
    public static func filterLargeVideos(
        videos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> SmartAlbumItem? {
        let thresholdBytes: Int64 = 200 * 1024 * 1024 // 200 MB
        var matchedIDs: [String] = []
        var matchedBytes: Int64 = 0
        
        for v in videos {
            let bytes = sizeRecords[v.localIdentifier]?.totalBytes ?? Int64(v.duration * 2_500_000)
            if bytes >= thresholdBytes {
                matchedIDs.append(v.localIdentifier)
                matchedBytes += bytes
            }
        }
        
        guard !matchedIDs.isEmpty else { return nil }
        return SmartAlbumItem(
            id: "large_videos",
            title: "Large Videos (> 200 MB)",
            count: matchedIDs.count,
            totalBytes: matchedBytes,
            sfSymbol: "film.stack",
            accentColorName: "red",
            assetIDs: matchedIDs,
            newestAssetID: matchedIDs.first
        )
    }
    #endif
}

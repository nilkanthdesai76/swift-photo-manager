import Foundation

#if canImport(Photos)
import Photos
#endif

/// Scanner for system smart albums, screen recordings, and threshold-based collections (large, old media).
public enum SmartAlbumScanner {
    
    #if canImport(Photos)
    /// Fetches all system smart albums applicable to photos.
    /// Live Photos uses the system Live Photos album so the count matches
    /// the Photos app (including shared-library items). Limited access can
    /// omit that album — then fall back to `.photoLive` on the fetched list.
    public static func fetchPhotoSmartAlbums(
        photos: [PHAsset] = [],
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> [SmartAlbumItem] {
        var items: [SmartAlbumItem] = []
        // Pruned library IDs (includes Shared Library when the fetch does).
        // System albums can briefly still list just-deleted assets — keep only
        // IDs still in this live set so Home does not reseed ghost cards.
        let livePhotoIDs = Set(photos.map(\.localIdentifier))

        let subtypes: [(PHAssetCollectionSubtype, String, String, String)] = [
            (.smartAlbumScreenshots, "Screenshots", "camera.viewfinder", "indigo"),
            (.smartAlbumSelfPortraits, "Selfies", "person.crop.square", "teal"),
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
                    // Newest-first so the album cover (`assetIDs.first`) and
                    // default presentation match the group's Latest filter.
                    let options = PHFetchOptions()
                    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
                    let assets = PHAsset.fetchAssets(in: col, options: options)
                    guard assets.count > 0 else { return }

                    var assetIDs: [String] = []
                    assetIDs.reserveCapacity(assets.count)
                    var totalBytes: Int64 = 0

                    assets.enumerateObjects { asset, _, _ in
                        let id = asset.localIdentifier
                        guard livePhotoIDs.contains(id) else { return }
                        assetIDs.append(id)
                        let size = sizeRecords[id]?.totalBytes ?? 2_500_000
                        totalBytes += size
                    }
                    guard !assetIDs.isEmpty else { return }

                    items.append(
                        SmartAlbumItem(
                            id: col.localIdentifier,
                            title: title,
                            count: assetIDs.count,
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

        if let live = Self.livePhotosAlbum(
            photos: photos,
            livePhotoIDs: livePhotoIDs,
            sizeRecords: sizeRecords
        ) {
            items.append(live)
        }

        return items
    }

    /// System Live Photos album, newest-first. Shared-library lives are included
    /// so the count matches the Photos app. When that album is missing (limited
    /// access), use `.photoLive` on the already-fetched photo list.
    /// IDs are filtered to `livePhotoIDs` so a post-delete PhotoKit lag cannot
    /// republish emptied Live Photos shells on Home.
    private static func livePhotosAlbum(
        photos: [PHAsset],
        livePhotoIDs: Set<String>,
        sizeRecords: [String: AssetSizeRecord]
    ) -> SmartAlbumItem? {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumLivePhotos,
            options: nil
        )
        if let collection = collections.firstObject {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
            let assets = PHAsset.fetchAssets(in: collection, options: options)
            if assets.count > 0 {
                var assetIDs: [String] = []
                assetIDs.reserveCapacity(assets.count)
                var totalBytes: Int64 = 0
                assets.enumerateObjects { asset, _, _ in
                    let id = asset.localIdentifier
                    guard livePhotoIDs.contains(id) else { return }
                    assetIDs.append(id)
                    totalBytes += sizeRecords[id]?.totalBytes ?? 2_500_000
                }
                if !assetIDs.isEmpty {
                    return SmartAlbumItem(
                        id: "live_photos",
                        title: "Live Photos",
                        count: assetIDs.count,
                        totalBytes: totalBytes,
                        sfSymbol: "livephoto",
                        accentColorName: "purple",
                        assetIDs: assetIDs,
                        newestAssetID: assetIDs.first
                    )
                }
            }
        }

        let livePhotos = photos.filter { $0.mediaSubtypes.contains(.photoLive) }
        guard !livePhotos.isEmpty else { return nil }
        var assetIDs: [String] = []
        assetIDs.reserveCapacity(livePhotos.count)
        var totalBytes: Int64 = 0
        for asset in livePhotos {
            assetIDs.append(asset.localIdentifier)
            totalBytes += sizeRecords[asset.localIdentifier]?.totalBytes ?? 2_500_000
        }
        return SmartAlbumItem(
            id: "live_photos",
            title: "Live Photos",
            count: livePhotos.count,
            totalBytes: totalBytes,
            sfSymbol: "livephoto",
            accentColorName: "purple",
            assetIDs: assetIDs,
            newestAssetID: assetIDs.first
        )
    }
    
    /// Fetches Video system groups: All Videos and Screen Recordings.
    /// Screen Recordings prefer the system smart album so the count matches Photos.
    public static func fetchVideoSmartAlbums(
        videos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> [SmartAlbumItem] {
        var items: [SmartAlbumItem] = []
        guard !videos.isEmpty else { return [] }
        
        var allIDs: [String] = []
        allIDs.reserveCapacity(videos.count)
        var allBytes: Int64 = 0
        for v in videos {
            allIDs.append(v.localIdentifier)
            allBytes += sizeRecords[v.localIdentifier]?.totalBytes ?? Int64(v.duration * 2_500_000)
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

        if let screenRecordings = Self.screenRecordingsAlbum(
            videos: videos,
            sizeRecords: sizeRecords
        ) {
            items.append(screenRecordings)
        }
        
        return items
    }

    /// System Screen Recordings album, newest-first. Falls back to subtype /
    /// filename heuristics only when that album is missing (limited library).
    /// Filtered to the pruned `videos` list so deleted recordings cannot linger.
    private static func screenRecordingsAlbum(
        videos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord]
    ) -> SmartAlbumItem? {
        let liveVideoIDs = Set(videos.map(\.localIdentifier))
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumScreenRecordings,
            options: nil
        )
        if let collection = collections.firstObject {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
            let assets = PHAsset.fetchAssets(in: collection, options: options)
            if assets.count > 0 {
                var assetIDs: [String] = []
                assetIDs.reserveCapacity(assets.count)
                var totalBytes: Int64 = 0
                assets.enumerateObjects { asset, _, _ in
                    let id = asset.localIdentifier
                    guard liveVideoIDs.contains(id) else { return }
                    assetIDs.append(id)
                    totalBytes += sizeRecords[id]?.totalBytes
                        ?? Int64(asset.duration * 2_500_000)
                }
                if !assetIDs.isEmpty {
                    return SmartAlbumItem(
                        id: "screen_recordings",
                        title: collection.localizedTitle ?? "Screen Recordings",
                        count: assetIDs.count,
                        totalBytes: totalBytes,
                        sfSymbol: "record.circle",
                        accentColorName: "red",
                        assetIDs: assetIDs,
                        newestAssetID: assetIDs.first
                    )
                }
            }
        }

        var screenRecordingIDs: [String] = []
        var screenRecordingBytes: Int64 = 0
        for v in videos {
            guard Self.isHeuristicScreenRecording(v) else { continue }
            screenRecordingIDs.append(v.localIdentifier)
            screenRecordingBytes += sizeRecords[v.localIdentifier]?.totalBytes
                ?? Int64(v.duration * 2_500_000)
        }
        guard !screenRecordingIDs.isEmpty else { return nil }
        return SmartAlbumItem(
            id: "screen_recordings",
            title: "Screen Recordings",
            count: screenRecordingIDs.count,
            totalBytes: screenRecordingBytes,
            sfSymbol: "record.circle",
            accentColorName: "red",
            assetIDs: screenRecordingIDs,
            newestAssetID: screenRecordingIDs.first
        )
    }

    private static func isHeuristicScreenRecording(_ asset: PHAsset) -> Bool {
        if asset.mediaSubtypes.contains(.videoScreenRecording) { return true }
        guard asset.duration > 0,
              let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename.lowercased()
        else { return false }
        return (filename.contains("screen") && filename.contains("record"))
            || (filename.contains("screen") && filename.contains("replay"))
            || filename.contains("rpreplay")
            || (filename.contains("rp_replay") && filename.contains("screen"))
    }
    
    /// Filters photos for "Large Photos" (≥ 5 MB, main `ScanThresholds`).
    /// Largest-first, matching the list screen's default `.largest` sort.
    public static func filterLargePhotos(
        photos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> SmartAlbumItem? {
        let thresholdBytes = ScanThresholds.largePhotoMinBytes
        var matched: [(id: String, bytes: Int64)] = []
        var matchedBytes: Int64 = 0

        for p in photos {
            let bytes = sizeRecords[p.localIdentifier]?.totalBytes ?? 0
            if bytes >= thresholdBytes {
                matched.append((p.localIdentifier, bytes))
                matchedBytes += bytes
            }
        }

        guard !matched.isEmpty else { return nil }
        let matchedIDs = matched.sorted { $0.bytes > $1.bytes }.map(\.id)
        return SmartAlbumItem(
            id: "large_photos",
            title: "Large Photos (> 5 MB)",
            count: matchedIDs.count,
            totalBytes: matchedBytes,
            sfSymbol: "arrow.up.left.and.arrow.down.right",
            accentColorName: "blue",
            assetIDs: matchedIDs,
            newestAssetID: matchedIDs.first
        )
    }

    /// Filters photos for "Old Photos" (older than 2 years, main `ScanThresholds`).
    /// Oldest-first, matching the list screen's default `.oldest` sort.
    public static func filterOldPhotos(
        photos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> SmartAlbumItem? {
        let oldCutoff = Calendar.current.date(
            byAdding: .year,
            value: -ScanThresholds.oldPhotoYears,
            to: Date()
        ) ?? Date()
        var matched: [(id: String, date: Date)] = []
        var matchedBytes: Int64 = 0

        for p in photos {
            if let date = p.creationDate, date < oldCutoff {
                matched.append((p.localIdentifier, date))
                matchedBytes += sizeRecords[p.localIdentifier]?.totalBytes ?? 2_500_000
            }
        }

        guard !matched.isEmpty else { return nil }
        let matchedIDs = matched.sorted { $0.date < $1.date }.map(\.id)
        return SmartAlbumItem(
            id: "old_photos",
            title: "Old Photos (> 2 Years)",
            count: matchedIDs.count,
            totalBytes: matchedBytes,
            sfSymbol: "clock.arrow.circlepath",
            accentColorName: "purple",
            assetIDs: matchedIDs,
            newestAssetID: matchedIDs.first
        )
    }

    /// Filters videos for "Large Videos" (≥ 100 MB, main `ScanThresholds`).
    /// Largest-first, matching the list screen's default `.largest` sort.
    public static func filterLargeVideos(
        videos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> SmartAlbumItem? {
        let thresholdBytes = ScanThresholds.largeVideoMinBytes
        var matched: [(id: String, bytes: Int64)] = []
        var matchedBytes: Int64 = 0

        for v in videos {
            let bytes = sizeRecords[v.localIdentifier]?.totalBytes ?? Int64(v.duration * 2_500_000)
            if bytes >= thresholdBytes {
                matched.append((v.localIdentifier, bytes))
                matchedBytes += bytes
            }
        }

        guard !matched.isEmpty else { return nil }
        let matchedIDs = matched.sorted { $0.bytes > $1.bytes }.map(\.id)
        return SmartAlbumItem(
            id: "large_videos",
            title: "Large Videos (> 100 MB)",
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

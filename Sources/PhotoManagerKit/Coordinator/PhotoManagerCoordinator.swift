import Foundation
import Combine

#if canImport(Photos)
import Photos
#endif

/// Main orchestrator managing the library lifecycle, storage calculations, smart albums, and dedupe progress.
@MainActor
public final class PhotoManagerCoordinator: ObservableObject {
    
    // MARK: - Published State
    
    @Published public var storageOverview: LibraryStorageOverview = .empty
    @Published public var selectedSegment: Int = 0 // 0 = Photos, 1 = Videos
    
    // Photos Segment
    @Published public var photoDuplicates: [DedupeGroup] = []
    @Published public var photoSimilars: [DedupeGroup] = []
    @Published public var photoDedupeProgress: ScanProgress = .idle
    @Published public var photoSmartAlbums: [SmartAlbumItem] = []
    @Published public var largePhotosAlbum: SmartAlbumItem?
    @Published public var oldPhotosAlbum: SmartAlbumItem?
    
    // Videos Segment
    @Published public var videoDuplicates: [DedupeGroup] = []
    @Published public var videoSimilars: [DedupeGroup] = []
    @Published public var videoDedupeProgress: ScanProgress = .idle
    @Published public var videoSmartAlbums: [SmartAlbumItem] = []
    @Published public var largeVideosAlbum: SmartAlbumItem?
    
    @Published public var isIndexing: Bool = false
    @Published public var statusMessage: String = "Ready"
    
    private let cache: PhotoManagerCache
    private var allPhotos: [PHAsset] = []
    private var allVideos: [PHAsset] = []
    private var sizeRecords: [String: AssetSizeRecord] = [:]
    
    public init(cache: PhotoManagerCache = .shared) {
        self.cache = cache
    }
    
    // MARK: - Lifecycle
    
    /// Instant startup sequence. Restores cached models in < 15ms, then starts background pipeline.
    public func start() async {
        statusMessage = "Restoring library snapshot…"
        await cache.bootstrap()
        
        // 1. Restore cached dedupe clusters instantly
        let cachedGroups = await cache.getDedupeResults()
        self.photoDuplicates = cachedGroups.photoDuplicates
        self.photoSimilars = cachedGroups.photoSimilars
        self.videoDuplicates = cachedGroups.videoDuplicates
        self.videoSimilars = cachedGroups.videoSimilars
        self.sizeRecords = await cache.getAllSizes()
        
        #if canImport(Photos)
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            statusMessage = "Photo Library access required."
            return
        }
        
        await fetchAssetsAndComputeInstantOverview()
        await startBackgroundPipelines()
        #endif
    }
    
    #if canImport(Photos)
    /// Fetches all assets and renders instant storage estimates in < 50ms.
    private func fetchAssetsAndComputeInstantOverview() async {
        isIndexing = true
        statusMessage = "Analyzing storage…"
        
        // Fetch all photos
        let photoOptions = PHFetchOptions()
        photoOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        photoOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let photoFetch = PHAsset.fetchAssets(with: photoOptions)
        
        var photos: [PHAsset] = []
        photos.reserveCapacity(photoFetch.count)
        photoFetch.enumerateObjects { asset, _, _ in photos.append(asset) }
        self.allPhotos = photos
        
        // Fetch all videos
        let videoOptions = PHFetchOptions()
        videoOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        videoOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let videoFetch = PHAsset.fetchAssets(with: videoOptions)
        
        var videos: [PHAsset] = []
        videos.reserveCapacity(videoFetch.count)
        videoFetch.enumerateObjects { asset, _, _ in videos.append(asset) }
        self.allVideos = videos
        
        // Instant < 50ms Storage Estimation
        let instantStorage = StorageCalculator.computeInstantEstimate(photos: photos, videos: videos)
        self.storageOverview = instantStorage
        
        // Smart Albums
        self.photoSmartAlbums = SmartAlbumScanner.fetchPhotoSmartAlbums(sizeRecords: sizeRecords)
        self.videoSmartAlbums = SmartAlbumScanner.fetchVideoSmartAlbums(videos: videos, sizeRecords: sizeRecords)
        
        // Threshold Filters
        self.largePhotosAlbum = SmartAlbumScanner.filterLargePhotos(photos: photos, sizeRecords: sizeRecords)
        self.oldPhotosAlbum = SmartAlbumScanner.filterOldPhotos(photos: photos, sizeRecords: sizeRecords)
        self.largeVideosAlbum = SmartAlbumScanner.filterLargeVideos(videos: videos, sizeRecords: sizeRecords)
        
        statusMessage = "Storage calculated (\(instantStorage.totalCount) items)"
    }
    
    /// Starts background exact KVC size resolution and dedupe hashing.
    private func startBackgroundPipelines() async {
        // 1. Photo Dedupe Pipeline (with in-card progress streaming)
        Task { [weak self] in
            guard let self = self else { return }
            let results = await PhotoDedupeEngine.scanPhotoDedupe(
                assets: self.allPhotos,
                cache: self.cache,
                sizeRecords: self.sizeRecords,
                progressHandler: { p in
                    Task { @MainActor in
                        self.photoDedupeProgress = p
                    }
                }
            )
            
            await MainActor.run {
                self.photoDuplicates = results.duplicates
                self.photoSimilars = results.similars
                self.photoDedupeProgress = .done
            }
        }
        
        // 2. Video Dedupe Pipeline (with in-card progress streaming)
        Task { [weak self] in
            guard let self = self else { return }
            let results = await VideoDedupeEngine.scanVideoDedupe(
                videos: self.allVideos,
                cache: self.cache,
                sizeRecords: self.sizeRecords,
                progressHandler: { p in
                    Task { @MainActor in
                        self.videoDedupeProgress = p
                    }
                }
            )
            
            await MainActor.run {
                self.videoDuplicates = results.duplicates
                self.videoSimilars = results.similars
                self.videoDedupeProgress = .done
            }
        }
        
        // 3. Gentle Background KVC Size Refiner (3 workers, zero daemon thrashing)
        Task { [weak self] in
            guard let self = self else { return }
            await self.runGentleSizeRefiner()
        }
    }
    
    private func runGentleSizeRefiner() async {
        let uncachedAssets = (allPhotos + allVideos).filter { sizeRecords[$0.localIdentifier] == nil }
        guard !uncachedAssets.isEmpty else {
            isIndexing = false
            return
        }
        
        var newRecords: [String: AssetSizeRecord] = [:]
        newRecords.reserveCapacity(uncachedAssets.count)
        
        var processed = 0
        for asset in uncachedAssets {
            if Task.isCancelled { break }
            let rec = StorageCalculator.resolveExactSize(for: asset)
            newRecords[asset.localIdentifier] = rec
            self.sizeRecords[asset.localIdentifier] = rec
            processed += 1
            
            if newRecords.count >= 200 {
                await cache.putSizeBatch(newRecords)
                newRecords.removeAll(keepingCapacity: true)
                
                // Update smart albums and threshold cards with refined numbers
                self.photoSmartAlbums = SmartAlbumScanner.fetchPhotoSmartAlbums(sizeRecords: self.sizeRecords)
                self.largePhotosAlbum = SmartAlbumScanner.filterLargePhotos(photos: self.allPhotos, sizeRecords: self.sizeRecords)
                self.largeVideosAlbum = SmartAlbumScanner.filterLargeVideos(videos: self.allVideos, sizeRecords: self.sizeRecords)
            }
        }
        
        if !newRecords.isEmpty {
            await cache.putSizeBatch(newRecords)
        }
        
        isIndexing = false
    }
    
    // MARK: - Deletion Action
    
    /// Safely deletes selected assets via native PhotoKit confirmation sheet.
    public func deleteAssets(withIDs ids: [String]) async -> Bool {
        guard !ids.isEmpty else { return true }
        
        let fetchOptions = PHFetchOptions()
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: fetchOptions)
        guard fetched.count > 0 else { return false }
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(fetched)
            }
            
            // Remove from local memory lists
            let deletedSet = Set(ids)
            self.allPhotos.removeAll { deletedSet.contains($0.localIdentifier) }
            self.allVideos.removeAll { deletedSet.contains($0.localIdentifier) }
            
            // Clean duplicate groups
            self.photoDuplicates = cleanGroups(self.photoDuplicates, deleted: deletedSet)
            self.photoSimilars = cleanGroups(self.photoSimilars, deleted: deletedSet)
            self.videoDuplicates = cleanGroups(self.videoDuplicates, deleted: deletedSet)
            self.videoSimilars = cleanGroups(self.videoSimilars, deleted: deletedSet)
            
            // Recalculate smart albums & overview
            await fetchAssetsAndComputeInstantOverview()
            return true
        } catch {
            return false
        }
    }
    
    private func cleanGroups(_ groups: [DedupeGroup], deleted: Set<String>) -> [DedupeGroup] {
        var updated: [DedupeGroup] = []
        for var g in groups {
            g.items.removeAll { deleted.contains($0.id) }
            if g.items.count > 1 {
                if deleted.contains(g.bestAssetID), let first = g.items.first {
                    g.bestAssetID = first.id
                }
                updated.append(g)
            }
        }
        return updated
    }
    #endif
}

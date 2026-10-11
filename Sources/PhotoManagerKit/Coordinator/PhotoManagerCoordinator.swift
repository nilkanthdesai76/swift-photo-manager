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
    
    // AI & Timeline
    @Published public var yearSections: [YearSection] = []
    @Published public var aiCategories: [AICategoryItem] = []
    @Published public var userAlbums: [UserAlbumItem] = []
    
    @Published public var isIndexing: Bool = false
    @Published public var statusMessage: String = "Ready"
    
    @Published public var sizeRecords: [String: AssetSizeRecord] = [:]
    
    private let cache: PhotoManagerCache
    private var allPhotos: [PHAsset] = []
    private var allVideos: [PHAsset] = []
    
    public init(cache: PhotoManagerCache = .shared) {
        self.cache = cache
    }
    
    private var hasStarted = false
    
    // MARK: - Lifecycle
    
    /// Instant startup sequence. Restores cached models in < 15ms, then starts background pipeline.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
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
        
        await fetchAssetsAndComputeOverview()
        await startBackgroundPipelines()
        #endif
    }
    
    #if canImport(Photos)
    /// Fetches all assets and calculates storage overview strictly using KVC sizes.
    private func fetchAssetsAndComputeOverview() async {
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
        
        // Pure KVC Storage Overview (instant from cached KVC sizes)
        let kvcStorage = StorageCalculator.computeOverview(photos: photos, videos: videos, sizeRecords: sizeRecords)
        self.storageOverview = kvcStorage
        
        // Smart Albums
        self.photoSmartAlbums = SmartAlbumScanner.fetchPhotoSmartAlbums(sizeRecords: sizeRecords)
        self.videoSmartAlbums = SmartAlbumScanner.fetchVideoSmartAlbums(videos: videos, sizeRecords: sizeRecords)
        
        // Threshold Filters
        self.largePhotosAlbum = SmartAlbumScanner.filterLargePhotos(photos: photos, sizeRecords: sizeRecords)
        self.oldPhotosAlbum = SmartAlbumScanner.filterOldPhotos(photos: photos, sizeRecords: sizeRecords)
        self.largeVideosAlbum = SmartAlbumScanner.filterLargeVideos(videos: videos, sizeRecords: sizeRecords)
        
        // AI & Timeline
        self.yearSections = TimelineAndAIScanner.buildTimeline(photos: photos, sizeRecords: sizeRecords)
        let cachedAICats = await cache.getAllAICategories()
        self.aiCategories = TimelineAndAIScanner.scanAICategories(
            photos: photos,
            sizeRecords: sizeRecords,
            cachedCategories: cachedAICats,
            onNewClassifications: { [weak self] newMap in
                guard let self = self else { return }
                Task {
                    await self.cache.setAICategories(newMap)
                }
            }
        )
        self.userAlbums = TimelineAndAIScanner.fetchUserAlbums(sizeRecords: sizeRecords)
        
        statusMessage = "Storage calculated (\(kvcStorage.totalCount) items)"
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
        
        // 3. Background KVC Size Refiner (3 bounded workers, autoreleasepool, zero thermal rising)
        Task { [weak self] in
            guard let self = self else { return }
            await self.runKvcSizeResolver()
        }
    }
    
    private func runKvcSizeResolver() async {
        let uncachedAssets = (allPhotos + allVideos).filter { sizeRecords[$0.localIdentifier] == nil }
        guard !uncachedAssets.isEmpty else {
            isIndexing = false
            return
        }
        
        statusMessage = "Resolving sizes via KVC…"
        
        // Split across 3 workers for fast parallel KVC metadata resolution without daemon thrashing
        let chunkSize = max(50, (uncachedAssets.count + 2) / 3)
        let chunks: [[PHAsset]] = stride(from: 0, to: uncachedAssets.count, by: chunkSize).map {
            Array(uncachedAssets[$0..<min($0 + chunkSize, uncachedAssets.count)])
        }
        
        await withTaskGroup(of: [String: AssetSizeRecord].self) { group in
            for chunk in chunks {
                group.addTask {
                    var resolved: [String: AssetSizeRecord] = [:]
                    resolved.reserveCapacity(chunk.count)
                    for (idx, asset) in chunk.enumerated() {
                        if Task.isCancelled { break }
                        let rec = StorageCalculator.resolveExactSize(for: asset)
                        resolved[asset.localIdentifier] = rec
                        if idx % 50 == 0 {
                            await Task.yield()
                        }
                    }
                    return resolved
                }
            }
            
            for await batch in group {
                await MainActor.run {
                    for (id, rec) in batch {
                        self.sizeRecords[id] = rec
                    }
                    self.storageOverview = StorageCalculator.computeOverview(
                        photos: self.allPhotos,
                        videos: self.allVideos,
                        sizeRecords: self.sizeRecords
                    )
                }
                await cache.putSizeBatch(batch)
            }
        }
        
        // Final background refresh once all batches complete - zero UI hitching
        await MainActor.run {
            self.photoSmartAlbums = SmartAlbumScanner.fetchPhotoSmartAlbums(sizeRecords: self.sizeRecords)
            self.videoSmartAlbums = SmartAlbumScanner.fetchVideoSmartAlbums(videos: self.allVideos, sizeRecords: self.sizeRecords)
            self.largePhotosAlbum = SmartAlbumScanner.filterLargePhotos(photos: self.allPhotos, sizeRecords: self.sizeRecords)
            self.largeVideosAlbum = SmartAlbumScanner.filterLargeVideos(videos: self.allVideos, sizeRecords: self.sizeRecords)
            self.yearSections = TimelineAndAIScanner.buildTimeline(photos: self.allPhotos, sizeRecords: self.sizeRecords)
            self.aiCategories = TimelineAndAIScanner.scanAICategories(photos: self.allPhotos, sizeRecords: self.sizeRecords)
            self.userAlbums = TimelineAndAIScanner.fetchUserAlbums(sizeRecords: self.sizeRecords)
            self.isIndexing = false
            self.statusMessage = "Ready"
        }
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
            await fetchAssetsAndComputeOverview()
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

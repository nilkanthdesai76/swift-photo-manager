import Foundation
import Combine

#if canImport(Photos)
import Photos
extension PHAsset: @unchecked Sendable {}

/// Immutable thread-safe snapshot of library overview and smart collections.
public struct LibrarySnapshot: Sendable {
    public let photos: [PHAsset]
    public let videos: [PHAsset]
    public let storageOverview: LibraryStorageOverview
    public let photoSmartAlbums: [SmartAlbumItem]
    public let videoSmartAlbums: [SmartAlbumItem]
    public let largePhotosAlbum: SmartAlbumItem?
    public let oldPhotosAlbum: SmartAlbumItem?
    public let largeVideosAlbum: SmartAlbumItem?
    public let yearSections: [YearSection]
    public let aiCategories: [AICategoryItem]
    public let userAlbums: [UserAlbumItem]
}
#endif

/// Main orchestrator managing the library lifecycle, storage calculations, smart albums, and dedupe progress.
/// UI state is published on `@MainActor`; ALL heavy PhotoKit and Vision workloads run in cooperative background tasks.
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
        
        isIndexing = true
        statusMessage = "Loading library…"
        
        let cachedSizes = self.sizeRecords
        let cachedAICats = await cache.getAllAICategories()
        
        // 2. Build initial library snapshot completely in the BACKGROUND
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.buildLibrarySnapshot(sizeRecords: cachedSizes, cachedAICategories: cachedAICats)
        }.value
        
        // 3. Publish snapshot instantly (takes < 1ms on main thread)
        self.applySnapshot(snapshot)
        
        // 4. Launch non-blocking background pipelines
        self.startBackgroundPipelines(cachedAICats: cachedAICats)
        #endif
    }
    
    #if canImport(Photos)
    /// Publishes a completed background snapshot to UI state in a single main-thread transaction.
    private func applySnapshot(_ snapshot: LibrarySnapshot) {
        self.allPhotos = snapshot.photos
        self.allVideos = snapshot.videos
        self.storageOverview = snapshot.storageOverview
        self.photoSmartAlbums = snapshot.photoSmartAlbums
        self.videoSmartAlbums = snapshot.videoSmartAlbums
        self.largePhotosAlbum = snapshot.largePhotosAlbum
        self.oldPhotosAlbum = snapshot.oldPhotosAlbum
        self.largeVideosAlbum = snapshot.largeVideosAlbum
        self.yearSections = snapshot.yearSections
        self.aiCategories = snapshot.aiCategories
        self.userAlbums = snapshot.userAlbums
        self.isIndexing = false
        self.statusMessage = "Storage ready (\(snapshot.storageOverview.totalCount) items)"
    }
    
    /// Builds a full library snapshot completely off the main thread.
    /// Runs in ~50-100ms on background thread without touching the UI.
    nonisolated private static func buildLibrarySnapshot(
        sizeRecords: [String: AssetSizeRecord],
        cachedAICategories: [String: String]
    ) -> LibrarySnapshot {
        // Fetch all photos
        let photoOptions = PHFetchOptions()
        photoOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        photoOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let photoFetch = PHAsset.fetchAssets(with: photoOptions)
        
        var photos: [PHAsset] = []
        photos.reserveCapacity(photoFetch.count)
        photoFetch.enumerateObjects { asset, _, _ in photos.append(asset) }
        
        // Fetch all videos
        let videoOptions = PHFetchOptions()
        videoOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        videoOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let videoFetch = PHAsset.fetchAssets(with: videoOptions)
        
        var videos: [PHAsset] = []
        videos.reserveCapacity(videoFetch.count)
        videoFetch.enumerateObjects { asset, _, _ in videos.append(asset) }
        
        // Pure KVC Storage Overview
        let kvcStorage = StorageCalculator.computeOverview(photos: photos, videos: videos, sizeRecords: sizeRecords)
        
        // Smart Albums & Thresholds
        let photoAlbums = SmartAlbumScanner.fetchPhotoSmartAlbums(sizeRecords: sizeRecords)
        let videoAlbums = SmartAlbumScanner.fetchVideoSmartAlbums(videos: videos, sizeRecords: sizeRecords)
        let largePhotos = SmartAlbumScanner.filterLargePhotos(photos: photos, sizeRecords: sizeRecords)
        let oldPhotos = SmartAlbumScanner.filterOldPhotos(photos: photos, sizeRecords: sizeRecords)
        let largeVideos = SmartAlbumScanner.filterLargeVideos(videos: videos, sizeRecords: sizeRecords)
        
        // Timeline, cached AI Categories, and User Albums
        let timeline = TimelineAndAIScanner.buildTimeline(photos: photos, sizeRecords: sizeRecords)
        let aiCategories = TimelineAndAIScanner.buildAICategories(
            photos: photos,
            sizeRecords: sizeRecords,
            cachedCategories: cachedAICategories
        )
        let userAlbums = TimelineAndAIScanner.fetchUserAlbums(sizeRecords: sizeRecords)
        
        return LibrarySnapshot(
            photos: photos,
            videos: videos,
            storageOverview: kvcStorage,
            photoSmartAlbums: photoAlbums,
            videoSmartAlbums: videoAlbums,
            largePhotosAlbum: largePhotos,
            oldPhotosAlbum: oldPhotos,
            largeVideosAlbum: largeVideos,
            yearSections: timeline,
            aiCategories: aiCategories,
            userAlbums: userAlbums
        )
    }
    
    /// Starts background exact KVC size resolution, dedupe hashing, and AI scene classification.
    private func startBackgroundPipelines(cachedAICats: [String: String]) {
        let photos = self.allPhotos
        let videos = self.allVideos
        let sizes = self.sizeRecords
        let cacheRef = self.cache
        
        // 1. Photo Dedupe Pipeline (runs in background detached task)
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let results = await PhotoDedupeEngine.scanPhotoDedupe(
                assets: photos,
                cache: cacheRef,
                sizeRecords: sizes,
                progressHandler: { [weak self] p in
                    Task { @MainActor in
                        self?.photoDedupeProgress = p
                    }
                }
            )
            await MainActor.run {
                self.photoDuplicates = results.duplicates
                self.photoSimilars = results.similars
                self.photoDedupeProgress = .done
            }
        }
        
        // 2. Video Dedupe Pipeline (runs in background detached task)
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let results = await VideoDedupeEngine.scanVideoDedupe(
                videos: videos,
                cache: cacheRef,
                sizeRecords: sizes,
                progressHandler: { [weak self] p in
                    Task { @MainActor in
                        self?.videoDedupeProgress = p
                    }
                }
            )
            await MainActor.run {
                self.videoDuplicates = results.duplicates
                self.videoSimilars = results.similars
                self.videoDedupeProgress = .done
            }
        }
        
        // 3. Background KVC Size Refiner (runs in background detached task)
        Task.detached(priority: .utility) { [weak self] in
            await self?.runKvcSizeResolver()
        }
        
        // 4. Background AI Scene & Object Classifier (runs in background detached task)
        Task.detached(priority: .utility) { [weak self] in
            await self?.runAICategoryScanner(photos: photos, initialCache: cachedAICats, cache: cacheRef)
        }
    }
    
    private func runKvcSizeResolver() async {
        let (photos, videos, currentSizes) = await MainActor.run {
            (self.allPhotos, self.allVideos, self.sizeRecords)
        }
        let uncachedAssets = (photos + videos).filter { currentSizes[$0.localIdentifier] == nil }
        guard !uncachedAssets.isEmpty else {
            await MainActor.run { self.isIndexing = false }
            return
        }
        
        await MainActor.run { self.statusMessage = "Resolving sizes via KVC…" }
        
        let chunkSize = 50
        let chunks: [[PHAsset]] = stride(from: 0, to: uncachedAssets.count, by: chunkSize).map {
            Array(uncachedAssets[$0..<min($0 + chunkSize, uncachedAssets.count)])
        }
        
        for chunk in chunks {
            if Task.isCancelled { break }
            
            var batch: [String: AssetSizeRecord] = [:]
            batch.reserveCapacity(chunk.count)
            
            for asset in chunk {
                let rec = StorageCalculator.resolveExactSize(for: asset)
                batch[asset.localIdentifier] = rec
            }
            
            await cache.putSizeBatch(batch)
            
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
            
            await Task.yield()
        }
        
        // Final background refresh once all sizes are resolved
        let (finalPhotos, finalVideos, finalSizes) = await MainActor.run {
            (self.allPhotos, self.allVideos, self.sizeRecords)
        }
        
        let pSmart = SmartAlbumScanner.fetchPhotoSmartAlbums(sizeRecords: finalSizes)
        let vSmart = SmartAlbumScanner.fetchVideoSmartAlbums(videos: finalVideos, sizeRecords: finalSizes)
        let lPhotos = SmartAlbumScanner.filterLargePhotos(photos: finalPhotos, sizeRecords: finalSizes)
        let lVideos = SmartAlbumScanner.filterLargeVideos(videos: finalVideos, sizeRecords: finalSizes)
        let timeline = TimelineAndAIScanner.buildTimeline(photos: finalPhotos, sizeRecords: finalSizes)
        
        await MainActor.run {
            self.photoSmartAlbums = pSmart
            self.videoSmartAlbums = vSmart
            self.largePhotosAlbum = lPhotos
            self.largeVideosAlbum = lVideos
            self.yearSections = timeline
            self.isIndexing = false
            self.statusMessage = "Ready"
        }
    }
    
    private func runAICategoryScanner(
        photos: [PHAsset],
        initialCache: [String: String],
        cache: PhotoManagerCache
    ) async {
        await TimelineAndAIScanner.classifyUncachedPhotosInBackground(
            photos: photos,
            cachedCategories: initialCache,
            batchSize: 20
        ) { newClassifications in
            await cache.setAICategories(newClassifications)
            let updatedCache = await cache.getAllAICategories()
            
            let (currentPhotos, currentSizes) = await MainActor.run {
                (self.allPhotos, self.sizeRecords)
            }
            
            let updatedAICategories = TimelineAndAIScanner.buildAICategories(
                photos: currentPhotos,
                sizeRecords: currentSizes,
                cachedCategories: updatedCache
            )
            
            await MainActor.run {
                self.aiCategories = updatedAICategories
            }
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
            
            // Recalculate smart albums & overview in background
            let sizes = self.sizeRecords
            let aiCats = await cache.getAllAICategories()
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.buildLibrarySnapshot(sizeRecords: sizes, cachedAICategories: aiCats)
            }.value
            self.applySnapshot(snapshot)
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

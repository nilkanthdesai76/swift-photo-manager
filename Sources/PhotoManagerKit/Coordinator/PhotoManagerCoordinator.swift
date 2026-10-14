import Foundation
import Observation

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

/// Sequential pipeline stage enum for targeted granular UI status updates.
public enum PipelineStep: String, Sendable, Equatable {
    case idle = "Idle"
    case fetchingSizes = "Calculating file sizes…"
    case photoDedupe = "Scanning photo duplicates…"
    case videoDedupe = "Scanning video duplicates…"
    case aiSorting = "Sorting photos with AI…"
    case completed = "Ready"
}

/// Main orchestrator managing the library lifecycle, storage calculations, smart albums, and dedupe progress.
/// Uses the Swift `@Observable` macro for fine-grained, targeted UI invalidation without halting user interaction.
/// Pipelines execute strictly sequentially one-by-one: Sizes -> Photo Dedupe -> Video Dedupe -> AI Sorting.
@Observable
@MainActor
public final class PhotoManagerCoordinator {
    
    // MARK: - Observable State (Granular per-property observation)
    
    public var storageOverview: LibraryStorageOverview = .empty
    public var selectedSegment: Int = 0 // 0 = Photos, 1 = Videos
    
    // Photos Segment
    public var photoDuplicates: [DedupeGroup] = []
    public var photoSimilars: [DedupeGroup] = []
    public var photoDedupeProgress: ScanProgress = .idle
    public var photoSmartAlbums: [SmartAlbumItem] = []
    public var largePhotosAlbum: SmartAlbumItem?
    public var oldPhotosAlbum: SmartAlbumItem?
    
    // Videos Segment
    public var videoDuplicates: [DedupeGroup] = []
    public var videoSimilars: [DedupeGroup] = []
    public var videoDedupeProgress: ScanProgress = .idle
    public var videoSmartAlbums: [SmartAlbumItem] = []
    public var largeVideosAlbum: SmartAlbumItem?
    
    // Blur detection (populated from the photo hashing pass)
    public var blurryPhotosAlbum: SmartAlbumItem?
    
    // AI & Timeline
    public var yearSections: [YearSection] = []
    public var aiCategories: [AICategoryItem] = []
    public var userAlbums: [UserAlbumItem] = []
    
    public var isIndexing: Bool = false
    public var currentStep: PipelineStep = .idle
    public var statusMessage: String = "Ready"
    
    public var sizeRecords: [String: AssetSizeRecord] = [:]
    
    // MARK: - Size Index Scan (Phase 0) Granular Progress
    public var sizeScanProgress: ScanProgress = .idle
    public var sizeScanResolvedBytes: Int64 = 0
    
    @ObservationIgnored
    private let cache: PhotoManagerCache
    @ObservationIgnored
    private var allPhotos: [PHAsset] = []
    @ObservationIgnored
    private var allVideos: [PHAsset] = []
    @ObservationIgnored
    private var hasStarted = false
    
    public init(cache: PhotoManagerCache = .shared) {
        self.cache = cache
    }
    
    // MARK: - Lifecycle
    
    /// Instant startup sequence. Restores cached models in < 15ms, then starts background pipeline.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        statusMessage = "Restoring library snapshot…"
        await cache.bootstrap()
        
        // 1. Restore cached dedupe clusters & sizes instantly
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
        
        // 4. Launch background pipelines (KVC sizes & photo dedupe run alongside on utility threads)
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
        return autoreleasepool {
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
    }
    
    /// Starts the prioritized background pipeline.
    ///
    /// Strategy: hashing (photo + video) is the FIRST priority. Size fetching only trickles in the
    /// leftover capacity (2 workers, background QoS) while hashing/clustering runs. Once both photo
    /// and video grouping are done, the size fetch escalates to full worker count at utility QoS to
    /// finish the remaining assets as fast as possible.
    ///
    /// Phase 1: Photo hashing (+ video fingerprinting + size trickle run concurrently).
    /// Phase 2: Photo grouping as soon as photo hashing finishes.
    /// Phase 3: Video grouping as soon as video fingerprinting finishes.
    /// Phase 4: Full-speed size fetch for the remaining uncached assets.
    /// Phase 5: Blur album + AI sorting.
    private func startBackgroundPipelines(cachedAICats: [String: String]) {
        let photos = self.allPhotos
        let videos = self.allVideos
        let cacheRef = self.cache
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            await MainActor.run {
                self.currentStep = .fetchingSizes
                self.isIndexing = true
                self.statusMessage = "Scanning library…"
            }
            
            let initialSizes = await MainActor.run { self.sizeRecords }
            
            // Size fetch TRICKLE: low priority + few workers so hashing gets the CPU first.
            let sizeTrickleTask = Task.detached(priority: .background) {
                await self.runKvcSizeResolver(
                    photos: photos,
                    videos: videos,
                    initialSizes: initialSizes,
                    cache: cacheRef,
                    maxConcurrent: 2,
                    qos: .background
                )
            }
            
            // ==========================================
            // PHASE 1: PHOTO HASH + VIDEO FINGERPRINT (top priority, all cores)
            // ==========================================
            async let photoHashWarmTask: Void = PhotoDedupeEngine.warmPhotoHashCache(
                assets: photos,
                cache: cacheRef,
                progressHandler: { [weak self] p in
                    Task { @MainActor in
                        self?.photoDedupeProgress = p
                        if p.isScanning {
                            self?.statusMessage = "Scanning photos (\(p.processed)/\(p.total))…"
                        }
                    }
                }
            )
            
            async let videoFingerprintWarmTask: Void = VideoDedupeEngine.warmVideoFingerprintCache(
                videos: videos,
                cache: cacheRef,
                progressHandler: { [weak self] p in
                    Task { @MainActor in
                        self?.videoDedupeProgress = p
                        if p.isScanning {
                            self?.statusMessage = "Scanning videos (\(p.processed)/\(p.total))…"
                        }
                    }
                }
            )
            
            // ==========================================
            // PHASE 2: PHOTO GROUPING (starts as soon as photo hashing finishes)
            // ==========================================
            await photoHashWarmTask
            if Task.isCancelled { return }
            
            let partialSizes = await MainActor.run { self.sizeRecords }
            
            await MainActor.run {
                self.currentStep = .photoDedupe
                self.statusMessage = "Scanning photo duplicates…"
            }
            
            let photoResults = await PhotoDedupeEngine.scanPhotoDedupe(
                assets: photos,
                cache: cacheRef,
                sizeRecords: partialSizes,
                progressHandler: { [weak self] p in
                    Task { @MainActor in
                        self?.photoDedupeProgress = p
                        if p.isScanning {
                            self?.statusMessage = "Scanning photos (\(p.processed)/\(p.total))…"
                        }
                    }
                }
            )
            
            await MainActor.run {
                self.photoDuplicates = photoResults.duplicates
                self.photoSimilars = photoResults.similars
                self.photoDedupeProgress = .done
            }
            
            // ==========================================
            // PHASE 3: VIDEO GROUPING (starts as soon as video fingerprinting finishes)
            // ==========================================
            await videoFingerprintWarmTask
            if Task.isCancelled { return }
            
            await MainActor.run {
                self.currentStep = .videoDedupe
                self.statusMessage = "Scanning for duplicate videos…"
            }
            
            let sizesForVideo = await MainActor.run { self.sizeRecords }
            
            let videoResults = await VideoDedupeEngine.scanVideoDedupe(
                videos: videos,
                cache: cacheRef,
                sizeRecords: sizesForVideo,
                progressHandler: { [weak self] p in
                    Task { @MainActor in
                        self?.videoDedupeProgress = p
                    }
                }
            )
            
            await MainActor.run {
                self.videoDuplicates = videoResults.duplicates
                self.videoSimilars = videoResults.similars
                self.videoDedupeProgress = .done
            }
            
            // ==========================================
            // PHASE 4: FULL-SPEED SIZE FETCH for the remaining uncached assets.
            // Hashing + clustering are done, so the size fetch now gets full workers + utility QoS.
            // ==========================================
            await sizeTrickleTask.value
            if Task.isCancelled { return }
            
            let trickleProgress = await cacheRef.getAllSizes()
            
            await MainActor.run {
                self.currentStep = .fetchingSizes
                self.statusMessage = "Indexing asset sizes…"
            }
            
            await self.runKvcSizeResolver(
                photos: photos,
                videos: videos,
                initialSizes: trickleProgress,
                cache: cacheRef,
                maxConcurrent: max(8, min(16, ProcessInfo.processInfo.processorCount)),
                qos: .utility
            )
            
            if Task.isCancelled { return }
            
            let sizeIndex = await MainActor.run { self.sizeRecords }
            
            // Build the Blurry Photos album with the complete size index for accurate totals.
            await self.buildBlurryPhotosAlbum(photos: photos, sizeIndex: sizeIndex, cache: cacheRef)
            
            // ==========================================
            // PHASE 5: AI SORTING
            // ==========================================
            await MainActor.run {
                self.currentStep = .aiSorting
                self.statusMessage = "Categorizing photos with AI Vision…"
            }
            await self.runAICategoryScanner(
                photos: photos,
                initialCache: cachedAICats,
                cache: cacheRef
            )
            
            // ==========================================
            // PIPELINE COMPLETE
            // ==========================================
            await MainActor.run {
                self.currentStep = .completed
                self.isIndexing = false
                self.statusMessage = "Ready"
            }
        }
    }
    
    /// Resolves KVC file sizes completely off the main actor (nonisolated) so PhotoKit property
    /// faults never stack on the main queue. Publishes granular per-chunk progress so only the
    /// targeted progress views re-render. Accumulates byte sums in O(1) arithmetic.
    nonisolated private func runKvcSizeResolver(
        photos: [PHAsset],
        videos: [PHAsset],
        initialSizes: [String: AssetSizeRecord],
        cache: PhotoManagerCache,
        maxConcurrent: Int = 8,
        qos: DispatchQoS.QoSClass = .utility
    ) async {
        let uncachedAssets = (photos + videos).filter { initialSizes[$0.localIdentifier] == nil }
        guard !uncachedAssets.isEmpty else { return }
        
        let scanTotal = uncachedAssets.count
        await MainActor.run {
            self.sizeScanProgress = ScanProgress(processed: 0, total: scanTotal, isScanning: true)
        }
        
        let chunkSize = 50
        let chunks: [[PHAsset]] = stride(from: 0, to: uncachedAssets.count, by: chunkSize).map {
            Array(uncachedAssets[$0..<min($0 + chunkSize, uncachedAssets.count)])
        }
        
        // Calculate initial baseline on utility background thread
        let baseline = StorageCalculator.computeOverview(
            photos: photos,
            videos: videos,
            sizeRecords: initialSizes
        )
        var runningPhotosBytes = baseline.photosBytes
        var runningLPStillBytes = baseline.livePhotosStillBytes
        var runningLPVideoBytes = baseline.livePhotosVideoBytes
        var runningVideosBytes = baseline.videosBytes
        let regularPhotoCount = baseline.photosCount
        let lpCount = baseline.livePhotosCount
        let totalCount = baseline.totalCount
        let videoCount = baseline.videosCount
        
        var accumulatedBatch: [String: AssetSizeRecord] = [:]
        accumulatedBatch.reserveCapacity(250)
        var processedCount = 0
        
        // Bounded pipeline: keep a fixed number of chunk tasks in flight at all times.
        // The per-asset size resolution is offloaded to GCD (`resolveExactSizeAsync`), so these
        // tasks are lightweight suspended continuations that never block a Swift executor thread.
        // Callers choose the width/QoS: a narrow trickle while hashing runs, full width afterwards.
        let maxConcurrent = max(1, maxConcurrent)
        let chunkStream = AsyncStream<[PHAsset]> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        
        typealias ChunkResult = (
            batch: [String: AssetSizeRecord],
            bytes: Int64,
            photosBytes: Int64,
            lpStill: Int64,
            lpVideo: Int64,
            videosBytes: Int64
        )
        
        @Sendable func processChunk(_ chunk: [PHAsset]) async -> ChunkResult {
            var batch: [String: AssetSizeRecord] = [:]
            batch.reserveCapacity(chunk.count)
            var photosBytes: Int64 = 0
            var lpStill: Int64 = 0
            var lpVideo: Int64 = 0
            var videosBytes: Int64 = 0
            
            for asset in chunk {
                if Task.isCancelled { break }
                // Non-blocking: the Photos I/O happens on a GCD worker thread.
                let rec = await StorageCalculator.resolveExactSizeAsync(for: asset, qos: qos)
                batch[asset.localIdentifier] = rec
                
                if asset.mediaType == .video {
                    videosBytes += rec.totalBytes
                } else if asset.mediaSubtypes.contains(.photoLive) {
                    lpStill += rec.stillBytes
                    lpVideo += rec.videoBytes
                } else {
                    photosBytes += rec.totalBytes
                }
            }
            
            let bytes = batch.values.reduce(Int64(0)) { $0 + $1.totalBytes }
            return (batch, bytes, photosBytes, lpStill, lpVideo, videosBytes)
        }
        
        await withTaskGroup(of: ChunkResult.self) { group in
            var iterator = chunkStream.makeAsyncIterator()
            var inFlight = 0
            var streamExhausted = false
            
            func spawnNext() async {
                guard !streamExhausted, let chunk = await iterator.next() else {
                    streamExhausted = true
                    return
                }
                group.addTask { await processChunk(chunk) }
                inFlight += 1
            }
            
            // Prime the pipeline
            while inFlight < maxConcurrent {
                await spawnNext()
                if streamExhausted { break }
            }
            
            // Drain results and keep the pipe full until no work remains
            while inFlight > 0 {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                
                guard let result = await group.next() else { break }
                inFlight -= 1
                
                if result.batch.isEmpty { continue }
                
                await cache.putSizeBatch(result.batch)
                accumulatedBatch.merge(result.batch) { _, new in new }
                runningPhotosBytes += result.photosBytes
                runningLPStillBytes += result.lpStill
                runningLPVideoBytes += result.lpVideo
                runningVideosBytes += result.videosBytes
                processedCount += result.batch.count
                
                // Publish progress every completed chunk — 50k assets ≈ 500 tiny MainActor hops.
                let snapshot = ScanProgress(processed: processedCount, total: scanTotal, isScanning: true)
                let chunkBytes = result.bytes
                await MainActor.run {
                    self.sizeScanProgress = snapshot
                    self.sizeScanResolvedBytes += chunkBytes
                }
                
                // Dispatch storage overview / sizeRecords batch every ~200 items or when pipeline dries up
                if accumulatedBatch.count >= 200 || (streamExhausted && inFlight == 0) {
                    let updatedOverview = LibraryStorageOverview(
                        totalBytes: runningPhotosBytes + runningLPStillBytes + runningLPVideoBytes + runningVideosBytes,
                        totalCount: totalCount,
                        photosBytes: runningPhotosBytes,
                        photosCount: regularPhotoCount,
                        livePhotosTotalBytes: runningLPStillBytes + runningLPVideoBytes,
                        livePhotosStillBytes: runningLPStillBytes,
                        livePhotosVideoBytes: runningLPVideoBytes,
                        livePhotosCount: lpCount,
                        videosBytes: runningVideosBytes,
                        videosCount: videoCount,
                        otherBytes: 0,
                        otherCount: 0,
                        isEstimated: false
                    )
                    
                    let dispatchBatch = accumulatedBatch
                    
                    await MainActor.run {
                        self.sizeRecords.merge(dispatchBatch) { _, new in new }
                        self.storageOverview = updatedOverview
                    }
                    accumulatedBatch.removeAll(keepingCapacity: true)
                }
                
                // Keep the pipe full
                while inFlight < maxConcurrent, !streamExhausted {
                    await spawnNext()
                }
                
                await Task.yield()
            }
        }
        
        await MainActor.run {
            self.sizeScanProgress = .idle
        }
        
        // Final background refresh of size-dependent collections once all sizes are resolved
        let allCurrentSizes = await cache.getAllSizes()
        let pSmart = SmartAlbumScanner.fetchPhotoSmartAlbums(sizeRecords: allCurrentSizes)
        let vSmart = SmartAlbumScanner.fetchVideoSmartAlbums(videos: videos, sizeRecords: allCurrentSizes)
        let lPhotos = SmartAlbumScanner.filterLargePhotos(photos: photos, sizeRecords: allCurrentSizes)
        let lVideos = SmartAlbumScanner.filterLargeVideos(videos: videos, sizeRecords: allCurrentSizes)
        let timeline = TimelineAndAIScanner.buildTimeline(photos: photos, sizeRecords: allCurrentSizes)
        
        await MainActor.run {
            self.photoSmartAlbums = pSmart
            self.videoSmartAlbums = vSmart
            self.largePhotosAlbum = lPhotos
            self.largeVideosAlbum = lVideos
            self.yearSections = timeline
        }
    }
    
    /// Builds the Blurry Photos smart album from blur flags persisted during the hashing pass.
    nonisolated private func buildBlurryPhotosAlbum(
        photos: [PHAsset],
        sizeIndex: [String: AssetSizeRecord],
        cache: PhotoManagerCache
    ) async {
        let blurryIDs = await cache.getBlurryPhotoIDs()
        guard !blurryIDs.isEmpty else {
            await MainActor.run { self.blurryPhotosAlbum = nil }
            return
        }
        
        // Preserve library order and drop stale IDs for assets no longer in the library.
        let orderedIDs = photos.compactMap { blurryIDs.contains($0.localIdentifier) ? $0.localIdentifier : nil }
        guard !orderedIDs.isEmpty else {
            await MainActor.run { self.blurryPhotosAlbum = nil }
            return
        }
        
        let totalBytes = orderedIDs.reduce(Int64(0)) { $0 + (sizeIndex[$1]?.totalBytes ?? 0) }
        let album = SmartAlbumItem(
            id: "blurry_photos",
            title: "Blurry Photos",
            count: orderedIDs.count,
            totalBytes: totalBytes,
            sfSymbol: "drop.triangle",
            accentColorName: "teal",
            assetIDs: orderedIDs,
            newestAssetID: orderedIDs.first
        )
        await MainActor.run {
            self.blurryPhotosAlbum = album
        }
    }
    
    nonisolated private func runAICategoryScanner(
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
            
            // Prune deleted assets from the blur album
            if var blur = self.blurryPhotosAlbum {
                blur.assetIDs.removeAll { deletedSet.contains($0) }
                blur.count = blur.assetIDs.count
                blur.totalBytes = blur.assetIDs.reduce(Int64(0)) { $0 + (self.sizeRecords[$1]?.totalBytes ?? 0) }
                self.blurryPhotosAlbum = blur.assetIDs.isEmpty ? nil : blur
            }
            
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

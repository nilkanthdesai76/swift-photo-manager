import Foundation
import Observation
import AlgorithmKit

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
    public let topHeaviestAlbum: SmartAlbumItem?
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

/// Result of a photo or video dedupe scan.
public typealias DedupeScanResult = (duplicates: [DedupeGroup], similars: [DedupeGroup])

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
    public var topHeaviestAlbum: SmartAlbumItem?
    
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
    
    // MARK: - Similarity Settings (Process Dashboard)
    /// Clustering strictness; persisted across launches, used by every photo/video scan.
    public var similarityPreset: SimilarityPreset = SimilarityPreset(
        rawValue: UserDefaults.standard.string(forKey: "pmk.similarityPreset") ?? ""
    ) ?? .balanced {
        didSet {
            UserDefaults.standard.set(similarityPreset.rawValue, forKey: "pmk.similarityPreset")
        }
    }
    
    // MARK: - Running Process Registry (for cancellation from the process dashboard)
    @ObservationIgnored
    private var processTasks: [String: Task<Void, Never>] = [:]
    
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
        self.topHeaviestAlbum = snapshot.topHeaviestAlbum
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
            let topHeaviest = SmartAlbumScanner.fetchTopHeaviestMedia(
                photos: photos,
                videos: videos,
                sizeRecords: sizeRecords,
                limit: 50
            )
            
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
                topHeaviestAlbum: topHeaviest,
                yearSections: timeline,
                aiCategories: aiCategories,
                userAlbums: userAlbums
            )
        }
    }
    
    /// Starts the background pipeline in two waves:
    ///
    /// Wave 1 (top priority): photo hashing + grouping AND video fingerprinting + grouping run
    /// concurrently and complete FIRST — nothing else competes with them.
    ///
    /// Wave 2: once both dedupe scans finish, size fetching (full speed) and AI categorization
    /// start TOGETHER and run concurrently. The blur album builds after the size index completes.
    private func startBackgroundPipelines(cachedAICats: [String: String]) {
        let photos = self.allPhotos
        let videos = self.allVideos
        let cacheRef = self.cache
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            await MainActor.run {
                self.currentStep = .photoDedupe
                self.isIndexing = true
                self.statusMessage = "Scanning photo duplicates…"
            }
            
            // Skip re-grouping on relaunch: if a full scan completed previously and every current
            // asset is hashed, restored groups are already valid — no need to cluster again.
            let photoScanComplete = await cacheRef.isPhotoScanComplete()
            let photoHashCount = await cacheRef.getAllPhotoHashes().count
            let videoScanComplete = await cacheRef.isVideoScanComplete()
            let videoFingerprintCount = await cacheRef.getAllVideoFingerprints().count
            let photoScanDone = photos.isEmpty || (photoScanComplete && photoHashCount >= photos.count)
            let videoScanDone = videos.isEmpty || (videoScanComplete && videoFingerprintCount >= videos.count)
            
            await MainActor.run {
                // Show both cards hashing from the very first moment so video starts visibly with photo.
                self.photoDedupeProgress = photoScanDone
                    ? .done
                    : ScanProgress(processed: 0, total: photos.count, isScanning: true, label: "Hashing")
                self.videoDedupeProgress = videoScanDone
                    ? .done
                    : ScanProgress(processed: 0, total: videos.count, isScanning: true, label: "Hashing")
            }
            
            // Independent photo scan task: hashes + clusters (skipped when already complete).
            let photoScanTask: Task<DedupeScanResult, Never>? = photoScanDone ? nil : Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return DedupeScanResult(duplicates: [], similars: []) }
                return await self.runPhotoScan(assets: photos, cache: cacheRef)
            }
            
            // Independent video scan task: fingerprints + clusters (skipped when already complete).
            let videoScanTask: Task<DedupeScanResult, Never>? = videoScanDone ? nil : Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return DedupeScanResult(duplicates: [], similars: []) }
                return await self.runVideoScan(videos: videos, cache: cacheRef)
            }
            
            // Publish photo groups the moment the photo scan finishes.
            if let photoScanTask = photoScanTask {
                let photoResults = await photoScanTask.value
                if Task.isCancelled { return }
                await MainActor.run {
                    self.photoDuplicates = photoResults.duplicates
                    self.photoSimilars = photoResults.similars
                    self.photoDedupeProgress = .done
                }
            }
            
            // Publish video groups the moment the video scan finishes.
            if let videoScanTask = videoScanTask {
                let videoResults = await videoScanTask.value
                if Task.isCancelled { return }
                await MainActor.run {
                    self.videoDuplicates = videoResults.duplicates
                    self.videoSimilars = videoResults.similars
                    self.videoDedupeProgress = .done
                }
            }
            
            // ==========================================
            // WAVE 2: SIZE FETCH + AI SORTING + BLUR BACKFILL (concurrent, full speed)
            // BLUR BACKFILL: libraries hashed before blur detection existed have hash caches but
            // no blur flags (their scan is now skipped) — run the one-time backfill alongside.
            // ==========================================
            if Task.isCancelled { return }
            
            let blurScanComplete = await cacheRef.isBlurScanComplete()
            let blurBackfillNeeded = !photos.isEmpty && (blurScanComplete == false)
            async let blurBackfillTask: Void = blurBackfillNeeded ? self.runBlurBackfill(photos: photos, cache: cacheRef) : ()
            
            let currentSizes = await MainActor.run { self.sizeRecords }
            
            await MainActor.run {
                self.currentStep = .fetchingSizes
                self.statusMessage = "Indexing asset sizes…"
            }
            
            async let sizeFetchTask: Void = self.runKvcSizeResolver(
                photos: photos,
                videos: videos,
                initialSizes: currentSizes,
                cache: cacheRef,
                maxConcurrent: max(8, min(16, ProcessInfo.processInfo.processorCount)),
                qos: .utility
            )
            
            await MainActor.run {
                self.currentStep = .aiSorting
                self.statusMessage = "Categorizing photos with AI Vision…"
            }
            async let aiTask: Void = self.runAICategoryScanner(
                photos: photos,
                initialCache: cachedAICats,
                cache: cacheRef
            )
            
            // Blur album needs the complete size index — build it as soon as sizes finish.
            await sizeFetchTask
            if Task.isCancelled { return }
            
            let completedSizes = await cacheRef.getAllSizes()
            await MainActor.run {
                self.sizeRecords = completedSizes
                self.refreshGroupSizes()
            }
            
            // Build the Blurry Photos album with the complete size index for accurate totals.
            await self.buildBlurryPhotosAlbum(photos: photos, sizeIndex: completedSizes, cache: cacheRef)
            
            // Wait for AI sorting and the blur backfill before declaring the pipeline complete.
            await aiTask
            if Task.isCancelled { return }
            await blurBackfillTask
            
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
    
    /// Independent photo scan (hash + cluster) used by the detached pipeline task.
    nonisolated private func runPhotoScan(
        assets: [PHAsset],
        cache: PhotoManagerCache
    ) async -> DedupeScanResult {
        let sizes = await MainActor.run { self.sizeRecords }
        let preset = await MainActor.run { self.similarityPreset }
        return await PhotoDedupeEngine.scanPhotoDedupe(
            assets: assets,
            cache: cache,
            sizeRecords: sizes,
            preset: preset,
            progressHandler: { [weak self] p in
                Task { @MainActor in
                    self?.photoDedupeProgress = p
                    if p.isScanning {
                        self?.statusMessage = p.label == "Resolving sizes"
                            ? "Resolving group sizes (\(p.processed)/\(p.total))…"
                            : "\(p.label ?? "Scanning") photos (\(p.processed)/\(p.total))…"
                    }
                }
            }
        )
    }
    
    /// Independent video scan (fingerprint + cluster) used by the detached pipeline task.
    nonisolated private func runVideoScan(
        videos: [PHAsset],
        cache: PhotoManagerCache
    ) async -> DedupeScanResult {
        let sizes = await MainActor.run { self.sizeRecords }
        let preset = await MainActor.run { self.similarityPreset }
        return await VideoDedupeEngine.scanVideoDedupe(
            videos: videos,
            cache: cache,
            sizeRecords: sizes,
            preset: preset,
            progressHandler: { [weak self] p in
                Task { @MainActor in
                    self?.videoDedupeProgress = p
                    if p.isScanning {
                        self?.statusMessage = p.label == "Resolving sizes"
                            ? "Resolving group sizes (\(p.processed)/\(p.total))…"
                            : "\(p.label ?? "Scanning") videos (\(p.processed)/\(p.total))…"
                    }
                }
            }
        )
    }
    
    /// One-time blur backfill for pre-existing hash caches; marks completion and builds the album.
    nonisolated private func runBlurBackfill(
        photos: [PHAsset],
        cache: PhotoManagerCache
    ) async {
        await PhotoDedupeEngine.backfillBlurFlags(assets: photos, cache: cache)
        await cache.markBlurScanComplete()
        let sizes = await MainActor.run { self.sizeRecords }
        await self.buildBlurryPhotosAlbum(photos: photos, sizeIndex: sizes, cache: cache)
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
    
    // MARK: - Process Dashboard Actions
    
    /// Backfills byte totals on published dedupe groups from the completed size index.
    /// Grouping itself never waits on sizes; this runs once sizes are available.
    public func refreshGroupSizes() {
        let sizes = self.sizeRecords
        func refreshed(_ groups: [DedupeGroup]) -> [DedupeGroup] {
            groups.map { group in
                var g = group
                g.items = group.items.map { item in
                    var it = item
                    if let rec = sizes[item.id] {
                        it.totalBytes = rec.totalBytes
                        it.stillBytes = rec.stillBytes
                        it.videoBytes = rec.videoBytes
                    }
                    return it
                }
                return g
            }
        }
        photoDuplicates = refreshed(photoDuplicates)
        photoSimilars = refreshed(photoSimilars)
        videoDuplicates = refreshed(videoDuplicates)
        videoSimilars = refreshed(videoSimilars)
    }
    
    /// True while a dashboard-triggered process is running under the given key.
    public func isProcessRunning(_ key: String) -> Bool {
        processTasks[key] != nil
    }
    
    /// Cancels a running dashboard-triggered process (hashing/grouping loops check Task.isCancelled).
    public func cancelProcess(_ key: String) {
        processTasks[key]?.cancel()
        processTasks[key] = nil
    }
    
    private func register(_ key: String, _ task: Task<Void, Never>) {
        processTasks[key] = task
    }
    
    private func unregister(_ key: String) {
        processTasks[key] = nil
    }
    
    /// Clears every cache (this session and all previous sessions) and resets published state.
    public func clearAllCaches() async {
        await cache.clear()
        photoDuplicates = []
        photoSimilars = []
        videoDuplicates = []
        videoSimilars = []
        sizeRecords = [:]
        aiCategories = []
        blurryPhotosAlbum = nil
        photoDedupeProgress = .idle
        videoDedupeProgress = .idle
        sizeScanProgress = .idle
        sizeScanResolvedBytes = 0
    }
    
    /// Cache contents snapshot for the process dashboard.
    public func cacheStats() async -> (
        sizes: Int,
        photoHashes: Int,
        videoFingerprints: Int,
        aiCategories: Int,
        blurryPhotos: Int,
        groups: Int
    ) {
        await cache.stats()
    }
    
    /// Re-runs photo hashing + duplicate/similar clustering from scratch (clears photo hash & blur caches).
    /// Runs as a cancellable background process (key "photo").
    public func rerunPhotoDedupe() {
        guard processTasks["photo"] == nil, !allPhotos.isEmpty else { return }
        let photos = self.allPhotos
        let cacheRef = self.cache
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await cacheRef.clearPhotoHashesAndBlur()
            await MainActor.run {
                self.photoDedupeProgress = ScanProgress(processed: 0, total: photos.count, isScanning: true, label: "Hashing")
                self.blurryPhotosAlbum = nil
            }
            let result = await self.runPhotoScan(assets: photos, cache: cacheRef)
            await MainActor.run {
                self.photoDuplicates = result.duplicates
                self.photoSimilars = result.similars
                self.photoDedupeProgress = .done
            }
            await self.buildBlurryPhotosAlbum(photos: photos, sizeIndex: self.sizeRecords, cache: cacheRef)
            await MainActor.run { self.unregister("photo") }
        }
        register("photo", task)
    }
    
    /// Re-runs video fingerprinting + duplicate/similar clustering from scratch.
    /// Runs as a cancellable background process (key "video").
    public func rerunVideoDedupe() {
        guard processTasks["video"] == nil, !allVideos.isEmpty else { return }
        let videos = self.allVideos
        let cacheRef = self.cache
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await cacheRef.clearVideoFingerprints()
            await MainActor.run {
                self.videoDedupeProgress = ScanProgress(processed: 0, total: videos.count, isScanning: true, label: "Hashing")
            }
            let result = await self.runVideoScan(videos: videos, cache: cacheRef)
            await MainActor.run {
                self.videoDuplicates = result.duplicates
                self.videoSimilars = result.similars
                self.videoDedupeProgress = .done
            }
            await MainActor.run { self.unregister("video") }
        }
        register("video", task)
    }
    
    /// Re-groups duplicates for BOTH photos and videos while KEEPING hashes/fingerprints,
    /// so only the (comparatively fast) clustering phase re-runs.
    /// Runs as a cancellable background process (key "regroup").
    public func regroupDuplicates() {
        guard processTasks["regroup"] == nil, !allPhotos.isEmpty || !allVideos.isEmpty else { return }
        let photos = self.allPhotos
        let videos = self.allVideos
        let cacheRef = self.cache
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await cacheRef.clearGroups()
            await MainActor.run {
                self.photoDedupeProgress = ScanProgress(processed: 0, total: photos.count, isScanning: true, label: "Grouping")
                self.videoDedupeProgress = ScanProgress(processed: 0, total: videos.count, isScanning: true, label: "Grouping")
            }
            async let photoResult = self.runPhotoScan(assets: photos, cache: cacheRef)
            async let videoResult = self.runVideoScan(videos: videos, cache: cacheRef)
            let (p, v) = await (photoResult, videoResult)
            await MainActor.run {
                self.photoDuplicates = p.duplicates
                self.photoSimilars = p.similars
                self.photoDedupeProgress = .done
                self.videoDuplicates = v.duplicates
                self.videoSimilars = v.similars
                self.videoDedupeProgress = .done
            }
            await MainActor.run { self.unregister("regroup") }
        }
        register("regroup", task)
    }
    
    /// Re-runs the exact size fetch for all assets (clears the size index first).
    /// Runs as a cancellable background process (key "sizes").
    public func rerunSizeFetch() {
        guard processTasks["sizes"] == nil, !allPhotos.isEmpty || !allVideos.isEmpty else { return }
        let photos = self.allPhotos
        let videos = self.allVideos
        let cacheRef = self.cache
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await cacheRef.clearSizes()
            await MainActor.run { self.sizeScanResolvedBytes = 0 }
            await self.runKvcSizeResolver(
                photos: photos,
                videos: videos,
                initialSizes: [:],
                cache: cacheRef,
                maxConcurrent: max(8, min(16, ProcessInfo.processInfo.processorCount)),
                qos: .utility
            )
            let sizes = await cacheRef.getAllSizes()
            await MainActor.run {
                self.sizeRecords = sizes
                self.refreshGroupSizes()
            }
            await self.buildBlurryPhotosAlbum(photos: photos, sizeIndex: sizes, cache: cacheRef)
            await MainActor.run { self.unregister("sizes") }
        }
        register("sizes", task)
    }
    
    /// Re-runs AI categorization from scratch (clears AI category cache first).
    /// Runs as a cancellable background process (key "ai").
    public func rerunAICategories() {
        guard processTasks["ai"] == nil, !allPhotos.isEmpty else { return }
        let photos = self.allPhotos
        let cacheRef = self.cache
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await cacheRef.clearAICategories()
            await self.runAICategoryScanner(photos: photos, initialCache: [:], cache: cacheRef)
            await MainActor.run { self.unregister("ai") }
        }
        register("ai", task)
    }
    
    // MARK: - Deletion Action
    
    /// Safely deletes selected assets via native PhotoKit confirmation sheet.
    public func deleteAssets(withIDs ids: [String]) async -> Bool {
        let uniqueIDs = ids.uniqued()
        guard !uniqueIDs.isEmpty else { return true }
        
        let fetchOptions = PHFetchOptions()
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIDs, options: fetchOptions)
        guard fetched.count > 0 else { return false }
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(fetched)
            }
            
            // Remove from local memory lists
            let deletedSet = Set(uniqueIDs)
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
            
            // Prune deleted assets from the top heaviest album
            if var heaviest = self.topHeaviestAlbum {
                heaviest.assetIDs.removeAll { deletedSet.contains($0) }
                heaviest.count = heaviest.assetIDs.count
                heaviest.totalBytes = heaviest.assetIDs.reduce(Int64(0)) { $0 + (self.sizeRecords[$1]?.totalBytes ?? 0) }
                self.topHeaviestAlbum = heaviest.assetIDs.isEmpty ? nil : heaviest
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

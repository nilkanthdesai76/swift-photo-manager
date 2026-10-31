
enum PhotoLibraryChangeNotifier {
    static func postAssetsRemoved(_ assetIDs: [String]) {
        guard !assetIDs.isEmpty else { return }
        NotificationCenter.default.post(
            name: Notification.Name("photoLibraryAssetsDidRemove"),
            object: nil,
            userInfo: ["deletedAssetIDs": assetIDs]
        )
    }

    static func postAssetsInserted(_ assetIDs: [String]) {
        guard !assetIDs.isEmpty else { return }
        NotificationCenter.default.post(
            name: Notification.Name("photoLibraryAssetsDidInsert"),
            object: nil,
            userInfo: ["insertedAssetIDs": assetIDs]
        )
    }

    static func postAssetsUpdated(_ assetIDs: [String], mediaChangedAssetIDs: [String] = []) {
        guard !assetIDs.isEmpty else { return }
        NotificationCenter.default.post(
            name: Notification.Name("photoLibraryAssetsDidUpdate"),
            object: nil,
            userInfo: [
                "updatedAssetIDs": assetIDs,
                "mediaChangedAssetIDs": mediaChangedAssetIDs
            ]
        )
    }
}

enum CleanupGroupsCache {
    static func saveBlurIDs(_ blurIDs: [String]) {}
}

enum LibraryScanAnalytics {
    enum ScanType: String {
        case initial
        case incremental
        case resumed
        case fullRescan = "full_rescan"
    }

    enum FailureReason: String {
        case photoLibraryAccessDenied = "photo_library_access_denied"
        case photoLibraryAccessRestricted = "photo_library_access_restricted"
        case photoLibraryUnavailable = "photo_library_unavailable"
        case scanInitializationFailed = "scan_initialization_failed"
        case assetFetchFailed = "asset_fetch_failed"
        case localIndexReadFailed = "local_index_read_failed"
        case localIndexWriteFailed = "local_index_write_failed"
        case processingTimeout = "processing_timeout"
        case insufficientStorage = "insufficient_storage"
        case unknown
    }

    @MainActor
    static func trackCompleted(
        scanType: ScanType,
        photos: [PHAsset],
        videos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord],
        scanStartedAt: Date,
        addedCount: Int? = nil,
        removedCount: Int? = nil,
        modifiedCount: Int? = nil
    ) {}

    @MainActor
    static func trackFailed(scanType: ScanType, reason: FailureReason) {}

    @MainActor
    static func failureReason(for status: PHAuthorizationStatus) -> FailureReason {
        switch status {
        case .denied: return .photoLibraryAccessDenied
        case .restricted: return .photoLibraryAccessRestricted
        default: return .photoLibraryUnavailable
        }
    }
}
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

/// Result of a photo or video dedupe scan.
public typealias DedupeScanResult = (duplicates: [DedupeGroup], similars: [DedupeGroup])

/// Deferred `library_scan_completed` payload held until size-fetch finishes.
private struct PendingLibraryScanAnalytics {
    let scanType: LibraryScanAnalytics.ScanType
    let startedAt: Date
    let addedCount: Int?
    let removedCount: Int?
    let modifiedCount: Int?
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

    /// Bumped when an AI harvest publishes a non-empty blur album. Home clears
    /// a surgically emptied blur latch only on this signal — not on stale
    /// membership / snapshot restore alone.
    public private(set) var blurHarvestGeneration: UInt64 = 0
    
    // AI & Timeline
    public var yearSections: [YearSection] = []
    public var aiCategories: [AICategoryItem] = []
    public var userAlbums: [UserAlbumItem] = []
    
    public var isIndexing: Bool = false
    public var currentStep: PipelineStep = .idle
    public var statusMessage: String = "Ready"

    /// True once the launch snapshot has published asset lists — processes
    /// require it before they can run.
    public private(set) var isLibrarySnapshotReady: Bool = false

    /// Default chain is past wave 1 and about to start AI sort (or still waiting
    /// on wave 1). Home keeps the Blur loading card up across the brief idle
    /// gap between size-fetch completion and `startProcess(.aiSort)`.
    public private(set) var isAwaitingPostSizeAISort: Bool = false

    /// Per-process execution state for Pipeline Control. Absent key == `.idle`.
    public var processStates: [PhotoManagerProcess: PhotoManagerProcessState] = [:]
    
    public var sizeRecords: [String: AssetSizeRecord] = [:] {
        didSet {
            // Lists open deep in navigation never see the Home-bridge size
            // notification; they observe `sizeRecordsRevision` instead to
            // backfill file sizes as batches land.
            sizeRecordsRevision &+= 1
        }
    }

    /// Bumped on every `sizeRecords` mutation (assignment or in-place merge).
    public var sizeRecordsRevision: UInt64 = 0
    
    // MARK: - Size Index Scan (Phase 0) Granular Progress
    public var sizeScanProgress: ScanProgress = .idle
    public var sizeScanResolvedBytes: Int64 = 0

    // MARK: - AI Sort Granular Progress
    public var aiSortProgress: ScanProgress = .idle
    
    // MARK: - Similarity Settings (Process Dashboard)
    /// Clustering strictness; persisted across launches, used by every photo/video scan.
    public var similarityPreset: SimilarityPreset = SimilarityPreset(
        rawValue: UserDefaults.standard.string(forKey: "pmk.similarityPreset") ?? ""
    ) ?? .strict {
        didSet {
            UserDefaults.standard.set(similarityPreset.rawValue, forKey: "pmk.similarityPreset")
        }
    }
    
    // MARK: - Running Process Registry (for cancellation from the process dashboard)
    @ObservationIgnored
    private var processTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Manual Process Pause Gates (Pipeline Control)
    @ObservationIgnored
    private var pauseGates: [PhotoManagerProcess: ProcessPauseGate] = [:]

    /// Debounces PhotoKit change bursts (delete/restore batches fire many).
    @ObservationIgnored
    private var libraryChangeTask: Task<Void, Never>?

    // MARK: - Batch Save Hold
    /// >0 while a multi-item write (Keep Both / compressed video / Live Photo
    /// save) is in flight — PHChange deliveries only set the pending flag and
    /// are coalesced into one sync when the last hold ends.
    @ObservationIgnored
    private var batchOperationHoldCount = 0
    @ObservationIgnored
    private var hasPendingLibraryChangeWhileHeld = false

    #if canImport(Photos)
    /// Baseline fetch results the current snapshot was built from. PhotoKit
    /// change notifications are resolved incrementally against these, so a
    /// backgrounded add/delete/edit only re-applies the delta instead of
    /// re-fetching the whole library.
    @ObservationIgnored
    private var photosFetchResult: PHFetchResult<PHAsset>?
    @ObservationIgnored
    private var videosFetchResult: PHFetchResult<PHAsset>?
    #endif

    /// Bumped whenever a sync observes content edits (changed assets) so
    /// visible thumbnails re-request fresh renditions.
    public var assetContentRevision: UInt64 = 0

    /// True while a PhotoKit-change rebuild is scheduled but not yet applied —
    /// the background execution controller uses this (plus running processes)
    /// to decide whether to hold a background assertion.
    public var hasPendingLibrarySync = false

    /// Any pipeline process currently running or paused (Pipeline Control).
    public var hasActiveProcesses: Bool {
        processStates.values.contains { $0 == .running || $0 == .paused }
    }

    /// Keeps the PHPhotoLibrary observer alive for the coordinator's lifetime.
    @ObservationIgnored
    private var libraryObserver: AnyObject?
    
    @ObservationIgnored
    private let cache: PhotoManagerCache
    @ObservationIgnored
    private var allPhotos: [PHAsset] = []
    @ObservationIgnored
    private var allVideos: [PHAsset] = []
    @ObservationIgnored
    private var hasStarted = false

    /// Inventory analytics waiting for size-fetch so `total_item_size` /
    /// photo/video sizes are not logged against an empty `sizeRecords` map
    /// (cold start publishes the snapshot before the size process runs).
    @ObservationIgnored
    private var pendingLibraryScanAnalytics: [PendingLibraryScanAnalytics] = []
    
    public init(cache: PhotoManagerCache = .shared) {
        self.cache = cache
    }

    public static let shared = PhotoManagerCoordinator()
    
    // MARK: - Lifecycle
    
    /// Instant startup sequence. Restores cached models in < 15ms, then starts background pipeline.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        statusMessage = "Restoring library snapshot…"
        await cache.bootstrap()

        // Similarity preset tightening (2026-10): Strict is the plain default
        // for fresh installs — no migration, no forced override of a stored
        // choice. The tightened ladder lives in SimilarityPreset itself.

        // Grouping upgrades (whole-bucket exact groups + union-find chaining,
        // then the Vision bridge with main-calibrated distance): clusters
        // cached by older grouping stay split until re-clustered. Drop the
        // groups once — hashes stay cached, so the re-cluster is
        // grouping-only and cheap.
        if UserDefaults.standard.integer(forKey: "pmk.groupingVersion") < 9 {
            UserDefaults.standard.set(9, forKey: "pmk.groupingVersion")
            await cache.clearGroups()
        }

        // Video dedupe rules v2: the old engine fabricated keyframe hashes
        // from metadata (width^height^duration) when pixel bytes were
        // unavailable, grouping unrelated same-resolution clips as "similar",
        // and borrowed the photo preset's 14/20/26-of-64 bit budget for a
        // single 32×32 poster. Purge fabricated fingerprints + cached groups
        // once — clean videos keep real hashes (re-cluster only), fabricated
        // ones re-fingerprint with the new no-fabrication rules.
        if UserDefaults.standard.integer(forKey: "pmk.groupingVersion") < 10 {
            UserDefaults.standard.set(10, forKey: "pmk.groupingVersion")
            await cache.purgeFabricatedVideoFingerprints()
            await cache.clearGroups()
        }

        // Video dedupe rules v3: identical posters inside the 1s window were
        // filed as similar, and a shorter near-match could swallow an exact
        // pair before it was claimed as a duplicate. Drop video clusters once
        // — fingerprints stay, so the next video scan only re-groups.
        // Version is stored after the empty clusters hit disk, so a kill
        // during the write runs this again instead of keeping the old groups.
        if UserDefaults.standard.integer(forKey: "pmk.groupingVersion") < 11 {
            await cache.clearVideoGroups()
            await cache.flush()
            UserDefaults.standard.set(11, forKey: "pmk.groupingVersion")
        }

        // Video dedupe rules v4: re-encoded copies of the same recording
        // (same pixel dimensions + ~1s duration + poster distance ≤ 6)
        // promote to exact duplicates again. Under v3 rules those pairs
        // clustered as "similar", so duplicate videos showed up under
        // Similar Videos. Re-group video clusters once — fingerprints
        // stay, so the next video scan only re-clusters.
        if UserDefaults.standard.integer(forKey: "pmk.groupingVersion") < 12 {
            await cache.clearVideoGroups()
            await cache.flush()
            UserDefaults.standard.set(12, forKey: "pmk.groupingVersion")
        }

        // Video dedupe rules v5: the same-dimension promotion distance moves
        // 6 → 12 bits (the similar cap), so no same-resolution copy pair can
        // remain filed as "similar". Re-group video clusters once —
        // fingerprints stay, so the next video scan only re-clusters.
        if UserDefaults.standard.integer(forKey: "pmk.groupingVersion") < 13 {
            await cache.clearVideoGroups()
            await cache.flush()
            UserDefaults.standard.set(13, forKey: "pmk.groupingVersion")
        }

        // Video dedupe rules v6: the similar-video bit budget moves 12 → 14
        // (the Similar Videos card thinned out once same-resolution copies
        // promoted to exact). The promotion distance tracks the same budget,
        // so same-dimension pairs still cannot straddle both cards. Re-group
        // video clusters once — fingerprints stay, re-cluster only.
        if UserDefaults.standard.integer(forKey: "pmk.groupingVersion") < 14 {
            await cache.clearVideoGroups()
            await cache.flush()
            UserDefaults.standard.set(14, forKey: "pmk.groupingVersion")
        }

        // Video dedupe rules v7: similar matching uses a ~4h creation-date
        // window plus relative duration slack (not the old 1s duration-only
        // gate). Re-group video clusters once — fingerprints stay.
        if UserDefaults.standard.integer(forKey: "pmk.groupingVersion") < 15 {
            await cache.clearVideoGroups()
            await cache.flush()
            UserDefaults.standard.set(15, forKey: "pmk.groupingVersion")
        }

        // Paint from the snapshot models persisted by the previous session
        // while the PhotoKit fetch + rebuild below validates them — on a
        // large library that build takes seconds, and the publish probe picks
        // these models up within a few hundred milliseconds. Load off-main:
        // the payload is several MB of asset IDs.
        let persistedSnapshot = await Task.detached(priority: .userInitiated) {
            LibrarySnapshotStore.load()
        }.value
        let hadPersistedSnapshot = persistedSnapshot != nil
        if let persistedSnapshot {
            applyRestoredSnapshot(persistedSnapshot)
        }

        // 1. Restore cached dedupe clusters & sizes instantly
        let cachedGroups = await cache.getDedupeResults()
        self.photoDuplicates = cachedGroups.photoDuplicates
        self.photoSimilars = cachedGroups.photoSimilars
        self.videoDuplicates = cachedGroups.videoDuplicates
        self.videoSimilars = cachedGroups.videoSimilars
        self.sizeRecords = await cache.getAllSizes()
        
        #if canImport(Photos)
        let launchScanType: LibraryScanAnalytics.ScanType =
            hadPersistedSnapshot ? .resumed : .initial
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            statusMessage = "Photo Library access required."
            LibraryScanAnalytics.trackFailed(
                scanType: launchScanType,
                reason: LibraryScanAnalytics.failureReason(for: status)
            )
            return
        }
        
        isIndexing = true
        statusMessage = "Loading library…"

        // Stay in sync with edits made in the Photos app (deletes, restores,
        // new captures/albums) without requiring a relaunch.
        let observer = PhotoLibraryChangeObserverBox(coordinator: self)
        libraryObserver = observer
        PHPhotoLibrary.shared().register(observer)

        let cachedSizes = self.sizeRecords
        let cachedAICats = await cache.getAllAICategories()
        let scanStartedAt = Date()

        // 2. Build initial library snapshot completely in the BACKGROUND
        let snapshot = await Task.detached(priority: .userInitiated) {
            let assets = Self.fetchLibraryAssets()
            let built = Self.buildLibrarySnapshot(
                photos: assets.photos,
                videos: assets.videos,
                sizeRecords: cachedSizes,
                cachedAICategories: cachedAICats
            )
            return (built, assets.photosFetch, assets.videosFetch)
        }.value

        // 3. Publish snapshot instantly (takes < 1ms on main thread) and keep
        // the fetch results as the change-sync baseline.
        self.photosFetchResult = snapshot.1
        self.videosFetchResult = snapshot.2
        self.applySnapshot(snapshot.0)
        // Defer until size-fetch finishes — cold start has empty sizeRecords
        // here, which would log total_item_size=0 for every asset.
        self.enqueueLibraryScanCompleted(
            scanType: launchScanType,
            scanStartedAt: scanStartedAt,
            photos: snapshot.0.photos,
            videos: snapshot.0.videos,
            waitForSizeFetch: true
        )

        // Restore the blur album from cached flags + restored sizes so the
        // group survives relaunch without waiting for a process rebuild.
        await self.buildBlurryPhotosAlbum(
            photos: snapshot.0.photos,
            sizeIndex: self.sizeRecords,
            cache: self.cache
        )
        // The launch applySnapshot ran before the blur album existed —
        // persist again so the next launch's early paint includes it.
        persistSnapshotModels()

        // 4. Default pipeline: photo + video dedupe and the size fetch run
        //    first (together — the storage card fills while hashing), then AI
        //    sort once the I/O-heavy processes finish. Every process stays
        //    controllable from Pipeline Control — cancelling any first-wave
        //    process stops the chain before AI sort starts.
        self.currentStep = .idle
        self.isIndexing = false
        self.statusMessage = "Starting library scan…"
        self.startDefaultProcessChain()
        #endif

    }

    /// Runs the default sequence through the manual process machinery: the
    /// dedupe pair + size fetch together, then AI sort (which also harvests
    /// blur flags from the same thumbnails) once all three finish — Vision
    /// must not compete with hashing or size I/O. Every process stays
    /// controllable from Pipeline Control — cancelling any first-wave process
    /// stops the chain before AI sort starts.
    private func startDefaultProcessChain() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.isAwaitingPostSizeAISort = true
                self.startProcess(.photoDedupe)
            }
            await MainActor.run { self.startProcess(.videoDedupe) }
            await MainActor.run { self.startProcess(.sizeFetch) }
            let photoOutcome = await self.waitForTerminalProcessState(.photoDedupe)
            let videoOutcome = await self.waitForTerminalProcessState(.videoDedupe)
            let sizeOutcome = await self.waitForTerminalProcessState(.sizeFetch)
            guard photoOutcome != .cancelled,
                  videoOutcome != .cancelled,
                  sizeOutcome != .cancelled else {
                // Cancelling a first-wave process stops this chain before AI.
                // Coverage repair (pause/kill/BG) is handled by
                // `ensureAISortCoverageIfNeeded` on foreground / BG tasks /
                // the next cold start.
                await MainActor.run { self.isAwaitingPostSizeAISort = false }
                return
            }
            await MainActor.run {
                self.isAwaitingPostSizeAISort = false
                self.startProcess(.aiSort)
            }
        }
    }

    /// Polls a process until it reaches `.completed` or `.cancelled`.
    private func waitForTerminalProcessState(
        _ process: PhotoManagerProcess
    ) async -> PhotoManagerProcessState {
        while true {
            let state = await MainActor.run { self.processState(process) }
            if state == .completed || state == .cancelled {
                return state
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - PhotoKit Change Sync

    /// Entry point from the PhotoKit observer. Resolves the notification
    /// against the baseline fetch results so only the delta (inserted /
    /// removed / changed assets) is re-applied — irrelevant notifications
    /// (album metadata we don't track) are dropped without touching the UI.
    @MainActor
    func handlePhotoLibraryChange(_ changeInstance: PHChange) {
        guard hasStarted else { return }
        guard batchOperationHoldCount == 0 else {
            // A multi-item save is in flight — remember the change and run one
            // coalesced sync when the matching `endBatchOperationHold` lands.
            hasPendingLibraryChangeWhileHeld = true
            return
        }
        let photoDetails = photosFetchResult.flatMap { changeInstance.changeDetails(for: $0) }
        let videoDetails = videosFetchResult.flatMap { changeInstance.changeDetails(for: $0) }
        guard photoDetails != nil || videoDetails != nil else { return }

        // Advance the baseline immediately so bursts coalesce against fresh
        // state.
        if let photoDetails { photosFetchResult = photoDetails.fetchResultAfterChanges }
        if let videoDetails { videosFetchResult = videoDetails.fetchResultAfterChanges }

        // Accumulate the delta across deliveries. Bursts (e.g. a camera
        // capture) arrive as SEVERAL notifications; keeping only the last
        // delivery's details silently dropped every earlier batch — those
        // photos got no sizes, no merge, no AI until the next relaunch.
        pendingInsertedPhotoIDs.formUnion(photoDetails?.insertedObjects.map(\.localIdentifier) ?? [])
        pendingInsertedVideoIDs.formUnion(videoDetails?.insertedObjects.map(\.localIdentifier) ?? [])
        pendingRemovedIDs.formUnion(photoDetails?.removedObjects.map(\.localIdentifier) ?? [])
        pendingRemovedIDs.formUnion(videoDetails?.removedObjects.map(\.localIdentifier) ?? [])
        pendingChangedIDs.formUnion(photoDetails?.changedObjects.map(\.localIdentifier) ?? [])
        pendingChangedIDs.formUnion(videoDetails?.changedObjects.map(\.localIdentifier) ?? [])

        hasPendingLibrarySync = true
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled, self.hasStarted else { return }
            await self.applyIncrementalLibrarySync()
        }
    }

    /// Running PhotoKit delta accumulated across change notifications. See
    /// `handlePhotoLibraryChange` — bursts arrive as multiple deliveries and
    /// the debounced flush consumes the union of all of them.
    @ObservationIgnored
    private var pendingInsertedPhotoIDs: Set<String> = []
    @ObservationIgnored
    private var pendingInsertedVideoIDs: Set<String> = []
    @ObservationIgnored
    private var pendingRemovedIDs: Set<String> = []
    @ObservationIgnored
    private var pendingChangedIDs: Set<String> = []

    /// Holds PhotoKit change processing while a multi-item write (e.g. Keep Both
    /// or compressed video saves) is active so intermediate commits do not
    /// trigger redundant full-library walks or thrash memory.
    @MainActor
    public func beginBatchOperationHold() {
        batchOperationHoldCount += 1
    }

    /// Releases the hold. When the last holder finishes and changes arrived
    /// while held, runs a single coalesced library sync for all of them.
    @MainActor
    public func endBatchOperationHold() {
        batchOperationHoldCount = max(0, batchOperationHoldCount - 1)
        guard batchOperationHoldCount == 0 else { return }
        guard hasPendingLibraryChangeWhileHeld else { return }
        hasPendingLibraryChangeWhileHeld = false
        hasPendingLibrarySync = true
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled, self.hasStarted else { return }
            await self.rebuildLibrarySnapshotAfterChange()
        }
    }

    /// Foreground hook — some backgrounded change deliveries are deferred, so
    /// an explicit revalidation on resume guarantees the library is current.
    /// This path does a full refetch (it has no PHChange to diff against);
    /// observer-driven syncs stay incremental. Also resumes AI sort + blur
    /// when a prior pass was paused/cancelled/incomplete.
    public func refreshAfterForeground() {
        Task { @MainActor in
            guard self.hasStarted else { return }
            self.ensureAISortCoverageIfNeeded()
            self.hasPendingLibrarySync = true
            self.libraryChangeTask?.cancel()
            self.libraryChangeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled, self.hasStarted else { return }
                await self.rebuildLibrarySnapshotAfterChange()
            }
        }
    }

    /// Entry point for background execution (background-task assertion window
    /// or a BGProcessingTask): keeps interrupted indexing going. Starts the
    /// size fetch / AI sort / blur scan when coverage is incomplete, resumes
    /// a paused AI/blur pass so a kill mid-pause does not strand work, and
    /// awaits anything already running.
    public func finishPendingIndexingIfNeeded() async {
        guard isLibrarySnapshotReady else { return }

        if processState(.sizeFetch) == .idle {
            let missingSizes = allPhotos.contains { sizeRecords[$0.localIdentifier] == nil }
                || allVideos.contains { sizeRecords[$0.localIdentifier] == nil }
            if missingSizes { startProcess(.sizeFetch) }
        }
        // Blur-incomplete is the durable "AI+blur pass unfinished" signal —
        // partial category caches are normal after a pause/kill and must resume.
        await ensureAISortCoverageIfNeededAsync()
        for process in PhotoManagerProcess.allCases where processState(process) == .running {
            await waitForTerminalProcessState(process)
        }
    }

    /// Foreground / coverage-repair hook: restart AI sort + blur when the last
    /// pass did not finish (`blurScanCompleted` still false), including after
    /// a pause + kill (in-memory pause is gone; disk flag stays incomplete).
    @MainActor
    public func ensureAISortCoverageIfNeeded() {
        Task { await self.ensureAISortCoverageIfNeededAsync() }
    }

    /// Starts or resumes AI sort when blur/AI coverage is incomplete.
    /// - Paused → resume (same session, or a BG window that inherited pause)
    /// - Idle / cancelled / completed → start (completed is reset when the
    ///   blur flag says the prior "done" was stale relative to coverage)
    private func ensureAISortCoverageIfNeededAsync() async {
        guard isLibrarySnapshotReady, !allPhotos.isEmpty else { return }
        let blurDone = await cache.isBlurScanComplete()
        guard !blurDone else { return }

        switch processState(.aiSort) {
        case .running:
            return
        case .paused:
            resumeProcess(.aiSort)
        case .idle, .cancelled, .completed:
            // Don't steal the default chain's post-size slot while wave 1 is
            // still supposed to lead into AI.
            guard !isAwaitingPostSizeAISort else { return }
            let wave1: [PhotoManagerProcess] = [.photoDedupe, .videoDedupe, .sizeFetch]
            let wave1Busy = wave1.contains {
                let s = processState($0)
                return s == .running || s == .paused
            }
            guard !wave1Busy else { return }
            if processState(.aiSort) == .completed {
                processStates[.aiSort] = .idle
            }
            startProcess(.aiSort)
        }
    }

    /// Applies the coalesced PhotoKit delta accumulated across deliveries:
    /// prunes removed assets from every published group + the size table,
    /// invalidates edited thumbnails, rebuilds the derived collections off
    /// the main thread from the current baseline fetch results (no
    /// full-library refetch), then folds inserted assets into dedupe groups,
    /// sizes, and AI categories. Publishes in one main-actor transaction.
    @MainActor
    private func applyIncrementalLibrarySync() async {
        // Snapshot and clear the accumulated delta up front so changes that
        // arrive while this flush runs start a fresh batch.
        let removedIDs = pendingRemovedIDs
        let changedIDs = pendingChangedIDs
        let insertedPhotoIDs = pendingInsertedPhotoIDs
        let insertedVideoIDs = pendingInsertedVideoIDs
        pendingRemovedIDs = []
        pendingChangedIDs = []
        pendingInsertedPhotoIDs = []
        pendingInsertedVideoIDs = []
        let scanStartedAt = Date()

        DLog("[Sync] flush start: +\(insertedPhotoIDs.count) photos, +\(insertedVideoIDs.count) videos, -\(removedIDs.count) removed, ~\(changedIDs.count) changed")

        // Metadata/content-only flushes skip the full rebuild. One "changed"
        // asset (Photos delivers these repeatedly for iCloud/metadata noise)
        // would otherwise re-enumerate the whole library, republish the
        // snapshot, and rebuild the blur album — re-rendering Home and any
        // pushed preview every few seconds. Purge the affected thumbnails and
        // let observers refresh in place instead.
        guard !removedIDs.isEmpty || !insertedPhotoIDs.isEmpty || !insertedVideoIDs.isEmpty else {
            if !changedIDs.isEmpty {
                ThumbnailCache.shared.remove(ids: changedIDs)
                AssetThumbnailImageLoader.shared.invalidateThumbnails(for: Array(changedIDs))
                assetContentRevision &+= 1
                PhotoLibraryChangeNotifier.postAssetsUpdated(Array(changedIDs), mediaChangedAssetIDs: [])
            }
            self.hasPendingLibrarySync = false
            DLog("[Sync] flush end (metadata-only, rebuild skipped)")
            return
        }

        // 1. Drop removed assets from caches and published groups immediately —
        //    deleted/trimmed items vanish from cards before the rebuild lands.
        if !removedIDs.isEmpty {
            sizeRecords = sizeRecords.filter { !removedIDs.contains($0.key) }
            photoDuplicates = cleanGroups(photoDuplicates, deleted: removedIDs)
            photoSimilars = cleanGroups(photoSimilars, deleted: removedIDs)
            videoDuplicates = cleanGroups(videoDuplicates, deleted: removedIDs)
            videoSimilars = cleanGroups(videoSimilars, deleted: removedIDs)
            if var blur = blurryPhotosAlbum {
                blur.assetIDs.removeAll { removedIDs.contains($0) }
                blur.count = blur.assetIDs.count
                blur.totalBytes = blur.assetIDs.reduce(Int64(0)) { $0 + (sizeRecords[$1]?.totalBytes ?? 0) }
                blurryPhotosAlbum = blur.assetIDs.isEmpty ? nil : blur
            }
            await cache.removeBlurryPhotoIDs(removedIDs)
            if blurryPhotosAlbum == nil {
                CleanupGroupsCache.saveBlurIDs([])
            }
            ThumbnailCache.shared.remove(ids: removedIDs)
            // Shared size-keyed cache serves PMK-backed cells; purge it too so
            // deleted/edited pixels cannot be re-decoded from a stale entry.
            AssetThumbnailImageLoader.shared.invalidateThumbnails(for: Array(removedIDs))
        }

        // 2. Rebuild the derived collections off-main from the already-updated
        //    baseline fetch results (enumeration only — no new fetch request).
        let currentSizes = self.sizeRecords
        let cachedAICats = await cache.getAllAICategories()
        let photosFR = self.photosFetchResult
        let videosFR = self.videosFetchResult
        let snapshot = await Task.detached(priority: .userInitiated) {
            var photos: [PHAsset] = []
            var videos: [PHAsset] = []
            if let photosFR {
                photos.reserveCapacity(photosFR.count)
                photosFR.enumerateObjects { asset, _, _ in photos.append(asset) }
            }
            if let videosFR {
                videos.reserveCapacity(videosFR.count)
                videosFR.enumerateObjects { asset, _, _ in videos.append(asset) }
            }
            return Self.buildLibrarySnapshot(
                photos: photos,
                videos: videos,
                sizeRecords: currentSizes,
                cachedAICategories: cachedAICats
            )
        }.value
        self.applySnapshot(snapshot, markReady: false)
        if !removedIDs.isEmpty {
            // Fetch-result enumeration can briefly still include deleted IDs;
            // strip every Home-facing surface so cards do not linger.
            self.allPhotos.removeAll { removedIDs.contains($0.localIdentifier) }
            self.allVideos.removeAll { removedIDs.contains($0.localIdentifier) }
            self.reconcilePublishedSurfacesAfterDeletion(removedIDs)
            await cache.putPhotoGroups(duplicates: photoDuplicates, similars: photoSimilars)
            await cache.putVideoGroups(duplicates: videoDuplicates, similars: videoSimilars)
            self.persistSnapshotModels()
        }
        LibraryScanAnalytics.trackCompleted(
            scanType: .incremental,
            photos: snapshot.photos,
            videos: snapshot.videos,
            sizeRecords: self.sizeRecords,
            scanStartedAt: scanStartedAt,
            addedCount: insertedPhotoIDs.count + insertedVideoIDs.count,
            removedCount: removedIDs.count,
            modifiedCount: changedIDs.count
        )
        await self.buildBlurryPhotosAlbum(
            photos: self.allPhotos,
            sizeIndex: self.sizeRecords,
            cache: self.cache
        )

        // 3. Edited assets (content/metadata): purge their cached thumbnails
        //    and bump the revision so visible cells re-request fresh renditions.
        if !changedIDs.isEmpty {
            ThumbnailCache.shared.remove(ids: changedIDs)
            AssetThumbnailImageLoader.shared.invalidateThumbnails(for: Array(changedIDs))
            assetContentRevision &+= 1
        }

        // Notify open screens once the rebuild has landed. Insert posts ride a
        // short delay: the Home-bridge membership reseed is debounced ~250ms
        // after the snapshot publish, and lists reload from that membership —
        // posting earlier would reload against stale membership.
        if !removedIDs.isEmpty {
            PhotoLibraryChangeNotifier.postAssetsRemoved(Array(removedIDs))
        }
        if !changedIDs.isEmpty {
            PhotoLibraryChangeNotifier.postAssetsUpdated(Array(changedIDs), mediaChangedAssetIDs: [])
        }
        let insertedAll = insertedPhotoIDs.union(insertedVideoIDs)
        if !insertedAll.isEmpty {
            let ids = Array(insertedAll)
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                PhotoLibraryChangeNotifier.postAssetsInserted(ids)
            }
        }

        // 4. Fold newly inserted assets into dedupe groups. Only when the
        //    matching scan completed before and isn't running — otherwise the
        //    next full scan covers them, and paused/cancelled stays untouched.
        let insertedPhotos = fetchAssets(for: insertedPhotoIDs)
        if !insertedPhotos.isEmpty {
            let state = self.processState(.photoDedupe)
            if state != .running, state != .paused, await cache.isPhotoScanComplete() {
                await self.incrementallyMergePhotos(insertedPhotos)
            }
        }
        let insertedVideos = fetchAssets(for: insertedVideoIDs)
        if !insertedVideos.isEmpty {
            let state = self.processState(.videoDedupe)
            if state != .running, state != .paused, await cache.isVideoScanComplete() {
                await self.incrementallyMergeVideos(insertedVideos)
            }
        }

        // 5. Coverage is the size-fetch process's job, not whichever screen is
        //    open: any unsized asset (new additions above, or gaps from an
        //    interrupted run) restarts the process so sizes land regardless
        //    of UI. The resolver filters to uncached assets only.
        self.ensureSizeFetchCoverageIfNeeded()

        // 6. Classify inserted photos into AI categories + blur flags so the
        //    rail and blur album cover newcomers without waiting for a relaunch.
        if !insertedPhotos.isEmpty {
            let aiState = self.processState(.aiSort)
            if aiState != .running, aiState != .paused {
                await self.incrementallyClassifyPhotos(insertedPhotos)
            }
        }

        self.hasPendingLibrarySync = false
        self.statusMessage = "Storage ready (\(snapshot.storageOverview.totalCount) items)"
        DLog("[Sync] flush end: \(snapshot.storageOverview.totalCount) items total")
    }

    /// Starts the size-fetch process whenever the published library has
    /// assets without size records and the process is not already working —
    /// including after it completed earlier this session, because "completed"
    /// only meant "no gaps at the time". New additions while the app runs must
    /// fetch their sizes with no list visit or relaunch required.
    @MainActor
    public func ensureSizeFetchCoverageIfNeeded() {
        guard isLibrarySnapshotReady else { return }
        let state = processState(.sizeFetch)
        guard state != .running, state != .paused else { return }
        let hasMissing = allPhotos.contains { sizeRecords[$0.localIdentifier] == nil }
            || allVideos.contains { sizeRecords[$0.localIdentifier] == nil }
        guard hasMissing else {
            // Nothing left to fetch — release any analytics waiting on sizes.
            flushPendingLibraryScanAnalytics()
            return
        }
        if state == .completed {
            // Allow a coverage re-run — `startProcess` only accepts idle/cancelled.
            processStates[.sizeFetch] = .idle
        }
        startProcess(.sizeFetch)
    }

    /// Queues or immediately fires `library_scan_completed`. When
    /// `waitForSizeFetch` is true and size records are still incomplete (or a
    /// size fetch is in flight), the event is held until size-fetch reaches a
    /// terminal state so size params are not all zeros on cold start.
    private func enqueueLibraryScanCompleted(
        scanType: LibraryScanAnalytics.ScanType,
        scanStartedAt: Date,
        photos: [PHAsset],
        videos: [PHAsset],
        addedCount: Int? = nil,
        removedCount: Int? = nil,
        modifiedCount: Int? = nil,
        waitForSizeFetch: Bool
    ) {
        let sizeState = processState(.sizeFetch)
        let sizeFetchInFlight = sizeState == .running || sizeState == .paused
        let hasMissingSizes = photos.contains { sizeRecords[$0.localIdentifier] == nil }
            || videos.contains { sizeRecords[$0.localIdentifier] == nil }

        if waitForSizeFetch && (hasMissingSizes || sizeFetchInFlight) {
            pendingLibraryScanAnalytics.append(
                PendingLibraryScanAnalytics(
                    scanType: scanType,
                    startedAt: scanStartedAt,
                    addedCount: addedCount,
                    removedCount: removedCount,
                    modifiedCount: modifiedCount
                )
            )
            return
        }

        LibraryScanAnalytics.trackCompleted(
            scanType: scanType,
            photos: photos,
            videos: videos,
            sizeRecords: sizeRecords,
            scanStartedAt: scanStartedAt,
            addedCount: addedCount,
            removedCount: removedCount,
            modifiedCount: modifiedCount
        )
    }

    /// Fires any deferred inventory analytics with the current asset lists and
    /// size records (after size-fetch completes, cancels, or finds no gaps).
    private func flushPendingLibraryScanAnalytics() {
        guard !pendingLibraryScanAnalytics.isEmpty else { return }
        let pending = pendingLibraryScanAnalytics
        pendingLibraryScanAnalytics = []
        for item in pending {
            LibraryScanAnalytics.trackCompleted(
                scanType: item.scanType,
                photos: allPhotos,
                videos: allVideos,
                sizeRecords: sizeRecords,
                scanStartedAt: item.startedAt,
                addedCount: item.addedCount,
                removedCount: item.removedCount,
                modifiedCount: item.modifiedCount
            )
        }
    }

    /// Fresh PHAssets for a set of local identifiers (inserted deltas).
    private func fetchAssets(for ids: Set<String>) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Incremental AI sort for photos added while the app runs: classifies
    /// just the newcomers (category + blur ride the same decode), merges the
    /// results into the cached categories, and republishes the rail + blur
    /// album so new photos land in their AI groups without a relaunch.
    nonisolated private func incrementallyClassifyPhotos(_ assets: [PHAsset]) async {
        let cacheRef = self.cache
        let existing = await cacheRef.getAllAICategories()
        var classified: [String: String] = [:]
        var blurry: [String] = []
        for asset in assets {
            if Task.isCancelled { return }
            guard existing[asset.localIdentifier] == nil,
                  classified[asset.localIdentifier] == nil else { continue }
            let result = await TimelineAndAIScanner.classifyOnUtilityWorker(asset: asset)
            if let result {
                classified[asset.localIdentifier] = result.category
                if result.isBlurry == true {
                    blurry.append(asset.localIdentifier)
                }
            }
        }
        guard !classified.isEmpty else { return }
        await cacheRef.setAICategories(classified)
        if !blurry.isEmpty {
            await cacheRef.putBlurryPhotoIDs(blurry)
        }
        let (photos, sizes, screenshotIDs) = await MainActor.run {
            (self.allPhotos, self.sizeRecords, Self.screenshotAlbumAssetIDs(from: self.photoSmartAlbums))
        }
        let updated = await cacheRef.getAllAICategories()
        let rebuilt = await Task.detached(priority: .utility) {
            TimelineAndAIScanner.buildAICategories(
                photos: photos,
                sizeRecords: sizes,
                cachedCategories: updated,
                screenshotAlbumIDs: screenshotIDs
            )
        }.value
        await MainActor.run {
            self.aiCategories = rebuilt
        }
        await self.buildBlurryPhotosAlbum(photos: photos, sizeIndex: sizes, cache: cacheRef)
        DLog("[Sync] incremental AI: \(classified.count) classified, \(blurry.count) blurry")
    }

    /// Incremental photo dedupe: hash + match only the newly inserted assets
    /// against the cached library hashes, then publish and persist the merged
    /// groups when the merge produced anything.
    nonisolated private func incrementallyMergePhotos(_ assets: [PHAsset]) async {
        let snapshot = await MainActor.run {
            (self.photoDuplicates, self.photoSimilars, self.sizeRecords, self.similarityPreset)
        }
        let merged = await PhotoDedupeEngine.mergeNewPhotos(
            assets,
            intoDuplicates: snapshot.0,
            similars: snapshot.1,
            cache: self.cache,
            sizeRecords: snapshot.2,
            preset: snapshot.3
        )
        guard merged.merged else {
            DLog("[Sync] incremental photo merge: no change (dups=\(merged.duplicates.count) sims=\(merged.similars.count))")
            return
        }
        DLog("[Sync] incremental photo merge: merged (dups=\(merged.duplicates.count) sims=\(merged.similars.count))")
        await MainActor.run {
            self.photoDuplicates = merged.duplicates
            self.photoSimilars = merged.similars
            self.refreshGroupSizes()
        }
        await self.cache.putPhotoGroups(duplicates: merged.duplicates, similars: merged.similars)
    }

    /// Incremental video dedupe counterpart — see `incrementallyMergePhotos`.
    nonisolated private func incrementallyMergeVideos(_ assets: [PHAsset]) async {
        let snapshot = await MainActor.run {
            (self.videoDuplicates, self.videoSimilars, self.sizeRecords, self.similarityPreset)
        }
        let merged = await VideoDedupeEngine.mergeNewVideos(
            assets,
            intoDuplicates: snapshot.0,
            similars: snapshot.1,
            cache: self.cache,
            sizeRecords: snapshot.2,
            preset: snapshot.3
        )
        guard merged.merged else { return }
        await MainActor.run {
            self.videoDuplicates = merged.duplicates
            self.videoSimilars = merged.similars
            self.refreshGroupSizes()
        }
        await self.cache.putVideoGroups(duplicates: merged.duplicates, similars: merged.similars)
    }

    /// Full-refetch rebuild used by the foreground safety net (no PHChange
    /// available there) and as the baseline-refresh path. Off the main thread
    /// except for the final publish.
    @MainActor
    private func rebuildLibrarySnapshotAfterChange() async {
        // The full rebuild revalidates everything — drop any incremental delta
        // accumulated in the meantime so a later flush doesn't reprocess it.
        pendingInsertedPhotoIDs = []
        pendingInsertedVideoIDs = []
        pendingRemovedIDs = []
        pendingChangedIDs = []
        let scanStartedAt = Date()
        let cachedAICats = await cache.getAllAICategories()
        let currentSizes = self.sizeRecords
        let snapshot = await Task.detached(priority: .userInitiated) {
            let assets = Self.fetchLibraryAssets()
            let built = Self.buildLibrarySnapshot(
                photos: assets.photos,
                videos: assets.videos,
                sizeRecords: currentSizes,
                cachedAICategories: cachedAICats
            )
            return (built, assets.photosFetch, assets.videosFetch)
        }.value

        self.photosFetchResult = snapshot.1
        self.videosFetchResult = snapshot.2
        let built = snapshot.0
        let validIDs = Set(built.photos.map(\.localIdentifier) + built.videos.map(\.localIdentifier))
        self.sizeRecords = currentSizes.filter { validIDs.contains($0.key) }
        self.applySnapshot(built, markReady: false)
        self.enqueueLibraryScanCompleted(
            scanType: .fullRescan,
            scanStartedAt: scanStartedAt,
            photos: built.photos,
            videos: built.videos,
            waitForSizeFetch: true
        )
        await self.buildBlurryPhotosAlbum(
            photos: built.photos,
            sizeIndex: self.sizeRecords,
            cache: self.cache
        )
        self.ensureSizeFetchCoverageIfNeeded()
        self.ensureAISortCoverageIfNeeded()
        self.hasPendingLibrarySync = false
        self.statusMessage = "Storage ready (\(built.storageOverview.totalCount) items)"
    }

    #if canImport(Photos)
    /// Publishes a completed background snapshot to UI state in a single main-thread transaction.
    /// `markReady` is false for change-driven rebuilds so an in-flight process
    /// keeps its step/status instead of being flipped to "ready".
    /// Publishes snapshot models persisted by a previous session so the UI
    /// paints real counts/cards before the PhotoKit validation build lands.
    /// Deliberately does not touch asset arrays, `isLibrarySnapshotReady`, or
    /// process state — processes wait for the verified snapshot.
    @MainActor
    private func applyRestoredSnapshot(_ persisted: PersistedLibrarySnapshot) {
        guard persisted.storageOverview.totalCount > 0 else { return }
        storageOverview = persisted.storageOverview
        photoSmartAlbums = persisted.photoSmartAlbums
        videoSmartAlbums = persisted.videoSmartAlbums
        largePhotosAlbum = persisted.largePhotosAlbum
        oldPhotosAlbum = persisted.oldPhotosAlbum
        largeVideosAlbum = persisted.largeVideosAlbum
        blurryPhotosAlbum = persisted.blurryPhotosAlbum
        yearSections = persisted.yearSections
        aiCategories = persisted.aiCategoryItems
        userAlbums = persisted.userAlbums
    }

    /// Snapshots the current published model layer to disk for the next
    /// launch's early paint. Encode + write run off-main; cheap enough to
    /// fire on every structural rebuild.
    private func persistSnapshotModels() {
        let persisted = PersistedLibrarySnapshot(
            storageOverview: storageOverview,
            photoSmartAlbums: photoSmartAlbums,
            videoSmartAlbums: videoSmartAlbums,
            largePhotosAlbum: largePhotosAlbum,
            oldPhotosAlbum: oldPhotosAlbum,
            largeVideosAlbum: largeVideosAlbum,
            blurryPhotosAlbum: blurryPhotosAlbum,
            yearSections: yearSections,
            aiCategoryItems: aiCategories,
            userAlbums: userAlbums,
            photoCount: allPhotos.count,
            videoCount: allVideos.count
        )
        Task.detached(priority: .utility) {
            LibrarySnapshotStore.save(persisted)
        }
    }

    private func applySnapshot(_ snapshot: LibrarySnapshot, markReady: Bool = true) {
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
        persistSnapshotModels()
        if markReady {
            self.isIndexing = false
            self.isLibrarySnapshotReady = true
            self.statusMessage = "Storage ready (\(snapshot.storageOverview.totalCount) items)"
        }
    }
    
    /// Fetches the full photo + video library (newest-first) plus the fetch
    /// results, which become the baseline for incremental change syncing.
    nonisolated private static func fetchLibraryAssets() -> (
        photos: [PHAsset],
        videos: [PHAsset],
        photosFetch: PHFetchResult<PHAsset>,
        videosFetch: PHFetchResult<PHAsset>
    ) {
        let photoOptions = PHFetchOptions()
        photoOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        photoOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Include Shared Library so Live Photos / Screenshots stay aligned with
        // system smart albums (and prune ground truth drops deleted shared IDs).
        photoOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
        let photoFetch = PHAsset.fetchAssets(with: photoOptions)

        var photos: [PHAsset] = []
        photos.reserveCapacity(photoFetch.count)
        photoFetch.enumerateObjects { asset, _, _ in photos.append(asset) }

        let videoOptions = PHFetchOptions()
        videoOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        videoOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        videoOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
        let videoFetch = PHAsset.fetchAssets(with: videoOptions)

        var videos: [PHAsset] = []
        videos.reserveCapacity(videoFetch.count)
        videoFetch.enumerateObjects { asset, _, _ in videos.append(asset) }

        return (photos, videos, photoFetch, videoFetch)
    }

    /// IDs from the system Screenshots smart album for the AI rail (main parity).
    nonisolated private static func screenshotAlbumAssetIDs(
        from photoAlbums: [SmartAlbumItem]
    ) -> [String] {
        photoAlbums.first { album in
            let title = album.title.lowercased()
            return title == "screenshots" || title.contains("screenshot")
        }?.assetIDs ?? []
    }

    /// Builds a library snapshot from already-fetched asset lists completely
    /// off the main thread. Runs in ~50-100ms on a background thread.
    nonisolated private static func buildLibrarySnapshot(
        photos: [PHAsset],
        videos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord],
        cachedAICategories: [String: String]
    ) -> LibrarySnapshot {
        return autoreleasepool {
            // Pure KVC Storage Overview
            let kvcStorage = StorageCalculator.computeOverview(photos: photos, videos: videos, sizeRecords: sizeRecords)
            
            // Smart Albums & Thresholds
            let photoAlbums = SmartAlbumScanner.fetchPhotoSmartAlbums(photos: photos, sizeRecords: sizeRecords)
            let videoAlbums = SmartAlbumScanner.fetchVideoSmartAlbums(videos: videos, sizeRecords: sizeRecords)
            let largePhotos = SmartAlbumScanner.filterLargePhotos(photos: photos, sizeRecords: sizeRecords)
            let oldPhotos = SmartAlbumScanner.filterOldPhotos(photos: photos, sizeRecords: sizeRecords)
            let largeVideos = SmartAlbumScanner.filterLargeVideos(videos: videos, sizeRecords: sizeRecords)
            
            // Timeline, cached AI Categories, and User Albums.
            // Screenshots on the AI rail come from the system smart album only.
            let timeline = TimelineAndAIScanner.buildTimeline(photos: photos, sizeRecords: sizeRecords)
            let screenshotIDs = Self.screenshotAlbumAssetIDs(from: photoAlbums)
            let aiCategories = TimelineAndAIScanner.buildAICategories(
                photos: photos,
                sizeRecords: sizeRecords,
                cachedCategories: cachedAICategories,
                screenshotAlbumIDs: screenshotIDs
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

    // MARK: - Manual Pipeline Control

    /// Current state of a pipeline process (`.idle` when absent).
    public func processState(_ process: PhotoManagerProcess) -> PhotoManagerProcessState {
        processStates[process] ?? .idle
    }

    /// Starts a process. No-ops while it is running/paused/completed.
    /// Completed scans restore from cache instead of re-hashing.
    public func startProcess(_ process: PhotoManagerProcess) {
        let state = processState(process)
        guard state == .idle || state == .cancelled else { return }
        guard isLibrarySnapshotReady else { return }
        processStates[process] = .running
        markProcessActive(process)

        let gate = ProcessPauseGate()
        pauseGates[process] = gate
        let pause: @Sendable () async -> Void = { await gate.waitIfPaused() }
        // Dedupe feeds the grouped cards, so it keeps user-initiated priority.
        // Size fetch and AI sort run at utility — AI inference in particular
        // must never compete with user interaction.
        let priority: TaskPriority = (process == .photoDedupe || process == .videoDedupe)
            ? .userInitiated
            : .utility
        let task = Task.detached(priority: priority) { [weak self] in
            guard let self = self else { return }
            await self.runProcess(process, pause: pause)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.pauseGates[process] = nil
                if Task.isCancelled || self.processStates[process] == .cancelled {
                    self.processStates[process] = .cancelled
                    switch process {
                    case .photoDedupe: self.photoDedupeProgress = .idle
                    case .videoDedupe: self.videoDedupeProgress = .idle
                    case .sizeFetch: self.sizeScanProgress = .idle
                    case .aiSort: self.aiSortProgress = .idle
                    }
                } else {
                    self.processStates[process] = .completed
                }
                self.processTasks[process.rawValue] = nil
                self.updateAggregatePipelineState()
                // Launch / full-rescan analytics wait for size coverage so
                // size params are not all zeros before the fetch lands.
                if process == .sizeFetch {
                    self.flushPendingLibraryScanAnalytics()
                }
            }
        }
        register(process.rawValue, task)
    }

    /// Pauses a running process at its next batch boundary.
    public func pauseProcess(_ process: PhotoManagerProcess) {
        guard processStates[process] == .running else { return }
        processStates[process] = .paused
        Task { await pauseGates[process]?.pause() }
    }

    /// Resumes a paused process.
    public func resumeProcess(_ process: PhotoManagerProcess) {
        guard processStates[process] == .paused else { return }
        processStates[process] = .running
        Task { await pauseGates[process]?.resume() }
    }

    /// Cancels a running or paused process. A paused process is woken first so
    /// its loop observes `Task.isCancelled` and unwinds.
    public func cancelProcess(_ process: PhotoManagerProcess) {
        guard let state = processStates[process], state == .running || state == .paused else { return }
        processStates[process] = .cancelled
        Task { [weak self] in
            await self?.pauseGates[process]?.resume()
            await MainActor.run { [weak self] in
                self?.processTasks[process.rawValue]?.cancel()
                self?.processTasks[process.rawValue] = nil
            }
        }
    }

    private func markProcessActive(_ process: PhotoManagerProcess) {
        isIndexing = true
        // While either dedupe process runs, keep that wave's step — the
        // grouped cards' processing state and progress pills key off it, and
        // both dedupes share wave 1.
        if processStates[.photoDedupe] == .running {
            currentStep = .photoDedupe
        } else if processStates[.videoDedupe] == .running {
            currentStep = .videoDedupe
        } else {
            currentStep = step(for: process)
        }
        statusMessage = statusMessage(for: process)
    }

    private func step(for process: PhotoManagerProcess) -> PipelineStep {
        switch process {
        case .photoDedupe: return .photoDedupe
        case .videoDedupe: return .videoDedupe
        case .sizeFetch: return .fetchingSizes
        case .aiSort: return .aiSorting
        }
    }

    private func statusMessage(for process: PhotoManagerProcess) -> String {
        switch process {
        case .photoDedupe: return "Scanning photo duplicates…"
        case .videoDedupe: return "Scanning video duplicates…"
        case .sizeFetch: return "Indexing asset sizes…"
        case .aiSort: return "Categorizing photos with AI Vision…"
        }
    }

    /// After any process finishes: `.completed` only when all five are done;
    /// idle/cancelled otherwise. Runs on the MainActor.
    private func updateAggregatePipelineState() {
        let states = PhotoManagerProcess.allCases.map { processStates[$0] ?? .idle }
        let allCompleted = states.allSatisfy { $0 == .completed }
        let anyActive = states.contains { $0 == .running || $0 == .paused }
        if allCompleted {
            currentStep = .completed
            isIndexing = false
            statusMessage = "Ready"
        } else if !anyActive {
            isIndexing = false
            // A process that restored from cache (or was cancelled) leaves no
            // step running — return to idle instead of a stale process step.
            currentStep = .idle
            statusMessage = "Ready"
        } else {
            isIndexing = true
        }
    }

    /// Body of one manual process. Each process is independent: it restores
    /// from cache when its scan already covers the library, and publishes its
    /// own results as soon as it finishes.
    nonisolated private func runProcess(
        _ process: PhotoManagerProcess,
        pause: @escaping @Sendable () async -> Void
    ) async {
        let cacheRef = self.cache
        switch process {
        case .photoDedupe:
            let photos = await MainActor.run { self.allPhotos }
            guard !photos.isEmpty, !Task.isCancelled else { return }
            let photoScanComplete = await cacheRef.isPhotoScanComplete()
            let photoHashCount = await cacheRef.getAllPhotoHashes().count
            guard !(photoScanComplete && photoHashCount >= photos.count) else {
                let cached = await cacheRef.getDedupeResults()
                await MainActor.run {
                    self.photoDuplicates = cached.photoDuplicates
                    self.photoSimilars = cached.photoSimilars
                    self.photoDedupeProgress = .done
                    // Cached groups predate the restored size index — re-apply
                    // whatever totals the index already holds.
                    self.refreshGroupSizes()
                }
                // Groups came from cache — also rebuild the blur album from
                // cached flags instead of leaving it nil until size fetch.
                let sizes = await MainActor.run { self.sizeRecords }
                await self.buildBlurryPhotosAlbum(photos: photos, sizeIndex: sizes, cache: cacheRef)
                return
            }
            await MainActor.run {
                self.photoDedupeProgress = ScanProgress(processed: 0, total: photos.count, isScanning: true, label: "Hashing")
            }
            let result = await self.runPhotoScan(assets: photos, cache: cacheRef, pause: pause)
            if Task.isCancelled { return }
            await MainActor.run {
                self.photoDuplicates = result.duplicates
                self.photoSimilars = result.similars
                self.photoDedupeProgress = .done
                // The size fetch runs concurrently now, so the scan's size
                // snapshot may be stale by publish time — re-apply current
                // totals; the size fetch's own backfill covers the rest.
                self.refreshGroupSizes()
            }
            let sizes = await MainActor.run { self.sizeRecords }
            await self.buildBlurryPhotosAlbum(photos: photos, sizeIndex: sizes, cache: cacheRef)

        case .videoDedupe:
            let videos = await MainActor.run { self.allVideos }
            guard !videos.isEmpty, !Task.isCancelled else { return }
            let videoScanComplete = await cacheRef.isVideoScanComplete()
            let fingerprintCount = await cacheRef.getAllVideoFingerprints().count
            guard !(videoScanComplete && fingerprintCount >= videos.count) else {
                let cached = await cacheRef.getDedupeResults()
                await MainActor.run {
                    self.videoDuplicates = cached.videoDuplicates
                    self.videoSimilars = cached.videoSimilars
                    self.videoDedupeProgress = .done
                    // Cached groups predate the restored size index — re-apply
                    // whatever totals the index already holds.
                    self.refreshGroupSizes()
                }
                return
            }
            await MainActor.run {
                self.videoDedupeProgress = ScanProgress(processed: 0, total: videos.count, isScanning: true, label: "Hashing")
            }
            let result = await self.runVideoScan(videos: videos, cache: cacheRef, pause: pause)
            if Task.isCancelled { return }
            await MainActor.run {
                self.videoDuplicates = result.duplicates
                self.videoSimilars = result.similars
                self.videoDedupeProgress = .done
                // The size fetch runs concurrently now, so the scan's size
                // snapshot may be stale by publish time — re-apply current
                // totals; the size fetch's own backfill covers the rest.
                self.refreshGroupSizes()
            }

        case .sizeFetch:
            let photos = await MainActor.run { self.allPhotos }
            let videos = await MainActor.run { self.allVideos }
            let currentSizes = await MainActor.run { self.sizeRecords }
            guard (!photos.isEmpty || !videos.isEmpty), !Task.isCancelled else { return }

            await self.runKvcSizeResolver(
                photos: photos,
                videos: videos,
                initialSizes: currentSizes,
                cache: cacheRef,
                maxConcurrent: max(8, min(16, ProcessInfo.processInfo.processorCount)),
                qos: .utility,
                pause: pause
            )
            if Task.isCancelled { return }
            let completedSizes = await cacheRef.getAllSizes()
            await MainActor.run {
                self.sizeRecords = completedSizes
                self.refreshGroupSizes()
            }
            await self.buildBlurryPhotosAlbum(photos: photos, sizeIndex: completedSizes, cache: cacheRef)

        case .aiSort:
            let photos = await MainActor.run { self.allPhotos }
            guard !photos.isEmpty, !Task.isCancelled else { return }
            // Mapper upgrade (evidence fusion + others fallback): old coarse
            // buckets would otherwise persist forever. Clear once and
            // re-classify the library under the new rules.
            let aiVersionKey = "pmk.aiMapperVersion"
            if UserDefaults.standard.integer(forKey: aiVersionKey) < 2 {
                UserDefaults.standard.set(2, forKey: aiVersionKey)
                await cacheRef.clearAICategories()
            }
            // Blur flags only re-evaluate for photos the pass actually
            // classifies, so a heuristic upgrade must force a full re-harvest
            // (Vision skipped for cached categories). Otherwise keep the
            // flags — an unconditional clear would empty the album on
            // category-complete libraries where nothing re-evaluates.
            var blurReharvestAll = false
            if UserDefaults.standard.integer(forKey: "pmk.blurAlgoVersion") < 6 {
                UserDefaults.standard.set(6, forKey: "pmk.blurAlgoVersion")
                blurReharvestAll = true
            }
            // Coverage repair: a kill between clearing flags and finishing the
            // harvest leaves the library blur-incomplete forever — the album
            // stays hidden because category-complete libraries re-evaluate
            // nothing on later runs. Any incomplete coverage forces the full
            // sweep (clear is a no-op when flags already sit empty).
            if !blurReharvestAll,
               !photos.isEmpty,
               !(await cacheRef.isBlurScanComplete()) {
                blurReharvestAll = true
            }
            if blurReharvestAll {
                await cacheRef.clearBlurFlags()
            }
            let initialCache = await cacheRef.getAllAICategories()
            await self.runAICategoryScanner(
                photos: photos,
                initialCache: initialCache,
                cache: cacheRef,
                blurReharvestAll: blurReharvestAll,
                pause: pause
            )
        }
    }
    
    /// Independent photo scan (hash + cluster) used by the manual photo process.
    nonisolated private func runPhotoScan(
        assets: [PHAsset],
        cache: PhotoManagerCache,
        pause: (@Sendable () async -> Void)? = nil
    ) async -> DedupeScanResult {
        let sizes = await MainActor.run { self.sizeRecords }
        let preset = await MainActor.run { self.similarityPreset }
        return await PhotoDedupeEngine.scanPhotoDedupe(
            assets: assets,
            cache: cache,
            sizeRecords: sizes,
            preset: preset,
            pause: pause,
            progressHandler: { [weak self] p in
                Task { @MainActor in
                    self?.photoDedupeProgress = Self.remapDedupeProgress(p)
                    if p.isScanning {
                        self?.statusMessage = p.label == "Resolving sizes"
                            ? "Resolving group sizes (\(p.processed)/\(p.total))…"
                            : "\(p.label ?? "Scanning") photos (\(p.processed)/\(p.total))…"
                    }
                }
            }
        )
    }
    
    /// Independent video scan (fingerprint + cluster) used by the manual video process.
    nonisolated private func runVideoScan(
        videos: [PHAsset],
        cache: PhotoManagerCache,
        pause: (@Sendable () async -> Void)? = nil
    ) async -> DedupeScanResult {
        let sizes = await MainActor.run { self.sizeRecords }
        let preset = await MainActor.run { self.similarityPreset }
        return await VideoDedupeEngine.scanVideoDedupe(
            videos: videos,
            cache: cache,
            sizeRecords: sizes,
            preset: preset,
            pause: pause,
            progressHandler: { [weak self] p in
                Task { @MainActor in
                    self?.videoDedupeProgress = Self.remapDedupeProgress(p)
                    if p.isScanning {
                        self?.statusMessage = p.label == "Resolving sizes"
                            ? "Resolving group sizes (\(p.processed)/\(p.total))…"
                            : "\(p.label ?? "Scanning") videos (\(p.processed)/\(p.total))…"
                    }
                }
            }
        )
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
        qos: DispatchQoS.QoSClass = .utility,
        pause: (@Sendable () async -> Void)? = nil
    ) async {
        // A record with totalBytes 0 is a FAILED resolve (iCloud-only asset whose
        // resources aren't local yet) — the UI treats 0 as "still sizing", so
        // caching it made the loaders spin forever and the asset never retried.
        // Treat 0-byte records as uncached and keep retrying each pass.
        // Videos are a separate pass: the size pipeline runs several chunks at
        // once, so mixing them with photos let photo-heavy libraries fill the
        // slots and the Home storage card stayed on "--" until photos landed.
        let uncachedVideos = videos.filter {
            (initialSizes[$0.localIdentifier]?.totalBytes ?? 0) <= 0
        }
        let uncachedPhotos = photos.filter {
            (initialSizes[$0.localIdentifier]?.totalBytes ?? 0) <= 0
        }
        guard !uncachedVideos.isEmpty || !uncachedPhotos.isEmpty else { return }

        // Progress spans the WHOLE library, not just this run's missing
        // assets. On relaunch the fetch only covers new/uncached items; without
        // the cached baseline the bar would restart at 0% and snap to 100%.
        let alreadyResolved = (photos.count + videos.count) - uncachedVideos.count - uncachedPhotos.count
        let scanTotal = photos.count + videos.count
        await MainActor.run {
            self.sizeScanProgress = ScanProgress(processed: alreadyResolved, total: scanTotal, isScanning: true)
        }
        
        let chunkSize = 50

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
        // The full app observes `storageOverview` on every assignment (Home
        // storage card + tab-bar token). Publishing per 200-item batch would
        // re-render that heavy UI dozens of times per second; gate publishes
        // to once per second — running totals still land every batch.
        var lastOverviewPublish = Date.distantPast
        // Cold start has no byte total yet. The first successful records must
        // publish immediately — the Home tutorial spotlights this card, and a
        // 200-item wait leaves it on "--" under that overlay.
        var needsStorageHeadline = baseline.totalBytes <= 0
        
        // Bounded pipeline: keep a fixed number of chunk tasks in flight at all times.
        // The per-asset size resolution is offloaded to GCD (`resolveExactSizeAsync`), so these
        // tasks are lightweight suspended continuations that never block a Swift executor thread.
        // Callers choose the width/QoS: a narrow trickle while hashing runs, full width afterwards.
        let workerCount = max(1, maxConcurrent)

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
                // Undownloaded iCloud assets resolve to 0 — don't persist that
                // poisoned record; leave the asset uncached so a later pass
                // (once the content is local) picks it up.
                guard rec.totalBytes > 0 else { continue }
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

        func drain(_ assets: [PHAsset], flushThreshold: Int) async {
            guard !assets.isEmpty else { return }
            let chunks: [[PHAsset]] = stride(from: 0, to: assets.count, by: chunkSize).map {
                Array(assets[$0..<min($0 + chunkSize, assets.count)])
            }
            let chunkStream = AsyncStream<[PHAsset]> { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
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
            while inFlight < workerCount {
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
                let snapshot = ScanProgress(processed: alreadyResolved + processedCount, total: scanTotal, isScanning: true)
                let chunkBytes = result.bytes
                await MainActor.run {
                    self.sizeScanProgress = snapshot
                    self.sizeScanResolvedBytes += chunkBytes
                }
                
                // First records publish immediately so the storage card is not
                // empty under the tutorial. Later passes keep the 200-item
                // gate. Every pass still flushes when its pipeline dries up.
                let readyForHeadline = needsStorageHeadline && !accumulatedBatch.isEmpty
                if accumulatedBatch.count >= flushThreshold || readyForHeadline || (streamExhausted && inFlight == 0) {
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
                    let publishOverview = needsStorageHeadline
                        || lastOverviewPublish.timeIntervalSinceNow <= -1.0
                        || (streamExhausted && inFlight == 0)
                    if publishOverview {
                        lastOverviewPublish = Date()
                        if updatedOverview.totalBytes > 0 {
                            needsStorageHeadline = false
                        }
                    }

                    await MainActor.run {
                        self.sizeRecords.merge(dispatchBatch) { _, new in new }
                        if publishOverview {
                            self.storageOverview = updatedOverview
                        }
                    }
                    accumulatedBatch.removeAll(keepingCapacity: true)
                }
                
                // Keep the pipe full — but honor a pause request between chunks so
                // in-flight chunk tasks drain before the resolver suspends.
                await pause?()
                while inFlight < workerCount, !streamExhausted {
                    await spawnNext()
                }
                
                await Task.yield()
            }
            }
        }

        // First 10 items, videos first, are their own chunk so the storage
        // card gets a total before the tutorial spotlight opens. A 50-item
        // chunk would still be waiting when that overlay appears.
        let headlineCount = 10
        var headlineAssets: [PHAsset] = []
        headlineAssets.reserveCapacity(headlineCount)
        for asset in uncachedVideos where headlineAssets.count < headlineCount {
            headlineAssets.append(asset)
        }
        if headlineAssets.count < headlineCount {
            for asset in uncachedPhotos where headlineAssets.count < headlineCount {
                headlineAssets.append(asset)
            }
        }
        let headlineIDs = Set(headlineAssets.map(\.localIdentifier))
        let remainingVideos = uncachedVideos.filter { !headlineIDs.contains($0.localIdentifier) }
        let remainingPhotos = uncachedPhotos.filter { !headlineIDs.contains($0.localIdentifier) }
        await drain(headlineAssets, flushThreshold: 1)
        if !Task.isCancelled {
            await drain(remainingVideos, flushThreshold: 200)
        }
        if !Task.isCancelled {
            await drain(remainingPhotos, flushThreshold: 200)
        }

        await MainActor.run {
            self.sizeScanProgress = .idle
        }
        
        // Final background refresh of size-dependent collections once all sizes are resolved
        let allCurrentSizes = await cache.getAllSizes()
        let pSmart = SmartAlbumScanner.fetchPhotoSmartAlbums(photos: photos, sizeRecords: allCurrentSizes)
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
        cache: PhotoManagerCache,
        publishToHomeCache: Bool = false
    ) async {
        let blurryIDs = await cache.getBlurryPhotoIDs()
        guard !blurryIDs.isEmpty else {
            await publishBlurryPhotosAlbum(nil, publishToHomeCache: publishToHomeCache)
            return
        }
        
        // Preserve library order and drop stale IDs for assets no longer in the library.
        let orderedIDs = photos.compactMap { blurryIDs.contains($0.localIdentifier) ? $0.localIdentifier : nil }
        let staleIDs = blurryIDs.subtracting(orderedIDs)
        if !staleIDs.isEmpty {
            await cache.removeBlurryPhotoIDs(staleIDs)
        }
        guard !orderedIDs.isEmpty else {
            await cache.flush()
            await publishBlurryPhotosAlbum(nil, publishToHomeCache: publishToHomeCache)
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
        await publishBlurryPhotosAlbum(album, publishToHomeCache: publishToHomeCache)
    }

    /// Publishes the blur album and, after a finished AI harvest, writes the
    /// same IDs where Home and the blur list read them.
    /// A nil album always persists empty blur IDs so a full wipe cannot
    /// resurrect the card from CleanupGroupsCache or the library snapshot.
    private func publishBlurryPhotosAlbum(
        _ album: SmartAlbumItem?,
        publishToHomeCache: Bool
    ) async {
        let ids = album?.assetIDs ?? []
        await MainActor.run {
            self.blurryPhotosAlbum = album
            if publishToHomeCache, !ids.isEmpty {
                self.blurHarvestGeneration &+= 1
            }
            self.persistSnapshotModels()
        }
        CleanupGroupsCache.saveBlurIDs(ids)
    }
    
    nonisolated private func runAICategoryScanner(
        photos: [PHAsset],
        initialCache: [String: String],
        cache: PhotoManagerCache,
        blurReharvestAll: Bool = false,
        pause: (@Sendable () async -> Void)? = nil
    ) async {
        let total = photos.count
        let baseline = photos.reduce(0) { partial, asset in
            partial + (initialCache[asset.localIdentifier] == nil ? 0 : 1)
        }

        // Publishing state lives in a reference box so the @Sendable batch
        // closure can accumulate classifications without captured-var mutation.
        final class PublishState: @unchecked Sendable {
            var accumulated: [String: String] = [:]
            var classified = 0
            var lastRebuild = Date.distantPast
        }
        let publishState = PublishState()

        func rebuildAndPublish() async {
            let (currentPhotos, currentSizes, screenshotIDs) = await MainActor.run {
                (self.allPhotos, self.sizeRecords, Self.screenshotAlbumAssetIDs(from: self.photoSmartAlbums))
            }
            let updatedAICategories = TimelineAndAIScanner.buildAICategories(
                photos: currentPhotos,
                sizeRecords: currentSizes,
                cachedCategories: initialCache.merging(publishState.accumulated) { _, new in new },
                screenshotAlbumIDs: screenshotIDs
            )
            await MainActor.run {
                self.aiCategories = updatedAICategories
                if total > 0 {
                    self.aiSortProgress = ScanProgress(
                        processed: min(baseline + publishState.classified, total),
                        total: total,
                        isScanning: true,
                        label: "Classifying"
                    )
                }
            }
        }

        await TimelineAndAIScanner.classifyUncachedPhotosInBackground(
            photos: photos,
            cachedCategories: initialCache,
            batchSize: 20,
            blurReharvestAll: blurReharvestAll,
            pause: pause
        ) { batch in
            await cache.setAICategories(batch.categories)
            if !batch.blurryIDs.isEmpty {
                await cache.putBlurryPhotoIDs(batch.blurryIDs)
            }
            publishState.accumulated.merge(batch.categories) { _, new in new }
            publishState.classified += batch.categories.count
            // Rebuilding categories is O(photo count); publishing per 20-item
            // batch is quadratic churn on the main actor. Throttle rebuilds to
            // one per second; the final rebuild below publishes the remainder.
            let now = Date()
            guard now.timeIntervalSince(publishState.lastRebuild) >= 1.0 else { return }
            publishState.lastRebuild = now
            await rebuildAndPublish()
        }
        // Final publish so the AI rail reflects every classification.
        await rebuildAndPublish()
        // Only mark blur coverage when the pass finished — cancel / pause-kill
        // must leave `blurScanCompleted` false so the next launch restarts.
        // Check process state too: cancelProcess flips it before Task.cancel.
        // (`||` cannot take `await` on the right — short-circuit uses an autoclosure.)
        if Task.isCancelled { return }
        let processCancelled = await MainActor.run {
            self.processStates[.aiSort] == .cancelled
        }
        guard !processCancelled else { return }
        await cache.markBlurScanComplete()
        let finalSizes = await MainActor.run { self.sizeRecords }
        await self.buildBlurryPhotosAlbum(
            photos: photos,
            sizeIndex: finalSizes,
            cache: cache,
            publishToHomeCache: true
        )
        await MainActor.run { self.aiSortProgress = .done }
    }

    /// Hashing fills 0–90% and grouping the last 10%, so a dedupe card reaches
    /// 100% exactly once at the end instead of hitting 100% for hashing and
    /// again during grouping.
    nonisolated private static func remapDedupeProgress(_ p: ScanProgress) -> ScanProgress {
        guard p.isScanning, p.total > 0 else { return p }
        let total = p.total
        if p.label == "Grouping" {
            // The engine's grouping kickoff reports processed == total — treat
            // it as "grouping just started" so the remap still climbs 90→100.
            let fraction = p.processed >= total ? 0 : p.fraction
            return ScanProgress(
                processed: min(total, Int((0.9 + 0.1 * fraction) * Double(total))),
                total: total,
                isScanning: true,
                label: p.label
            )
        }
        return ScanProgress(
            processed: min(p.processed, Int(0.9 * Double(total))),
            total: total,
            isScanning: true,
            label: p.label
        )
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
    
    /// Resolves sizes for just the requested assets, ahead of the background
    /// size fetch. Used by the Home tutorial so the tour's delete prompt
    /// quotes a real byte total even while the full-library size index is
    /// still building. Returns resolved records keyed by asset id (empty when
    /// nothing was missing or the bounded wait expired).
    @discardableResult
    public func resolveSizesOnPriority(forAssetIDs ids: [String]) async -> [String: AssetSizeRecord] {
        let missingIDs = ids.filter { sizeRecords[$0] == nil }
        guard !missingIDs.isEmpty else { return [:] }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: missingIDs, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else { return [:] }

        // The tutorial must never stall on PhotoKit I/O — cap the wait and
        // keep whatever resolved in time.
        return await withTaskGroup(of: [String: AssetSizeRecord].self) { group in
            group.addTask {
                await StorageCalculator.resolveMissingSizes(
                    for: assets,
                    existing: [:],
                    maxConcurrent: 4,
                    qos: .userInitiated
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return [:]
            }
            let resolved = await group.next() ?? [:]
            group.cancelAll()
            guard !resolved.isEmpty else { return resolved }

            // Undownloaded assets resolve to 0 — never persist those (same
            // poisoned-record rule as the main resolver).
            let persisted = resolved.filter { $0.value.totalBytes > 0 }
            guard !persisted.isEmpty else { return resolved }

            // Fold into the shared index — the didSet bump reaches every open
            // list through `sizeRecordsRevision`, and persisting the record
            // means the background fetch skips the asset when its turn comes.
            await cache.putSizeBatch(persisted)
            sizeRecords.merge(persisted) { _, new in new }
            refreshGroupSizes()
            return resolved
        }
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
        LibrarySnapshotStore.remove()
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
        aiSortProgress = .idle
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

    /// Drops IDs PhotoKit has already deleted from the published library.
    /// Does not call `performChanges` and does not refetch the whole library,
    /// so a select-all success cannot repaint the category from a stale fetch.
    public func pruneDeletedAssetIDs(_ ids: [String]) async {
        let deletedSet = Set(ids)
        guard !deletedSet.isEmpty else { return }

        allPhotos.removeAll { deletedSet.contains($0.localIdentifier) }
        allVideos.removeAll { deletedSet.contains($0.localIdentifier) }
        sizeRecords = sizeRecords.filter { !deletedSet.contains($0.key) }
        photoDuplicates = cleanGroups(photoDuplicates, deleted: deletedSet)
        photoSimilars = cleanGroups(photoSimilars, deleted: deletedSet)
        videoDuplicates = cleanGroups(videoDuplicates, deleted: deletedSet)
        videoSimilars = cleanGroups(videoSimilars, deleted: deletedSet)
        if var blur = blurryPhotosAlbum {
            blur.assetIDs.removeAll { deletedSet.contains($0) }
            blur.count = blur.assetIDs.count
            blur.totalBytes = blur.assetIDs.reduce(Int64(0)) { $0 + (sizeRecords[$1]?.totalBytes ?? 0) }
            blur.newestAssetID = blur.assetIDs.first
            blurryPhotosAlbum = blur.assetIDs.isEmpty ? nil : blur
        }

        // Drop deleted IDs from the on-disk blur cache. Leaving them lets a
        // relaunch rebuild Blurry Photos from flags that no longer exist.
        await cache.removeBlurryPhotoIDs(deletedSet)
        if blurryPhotosAlbum == nil {
            await cache.flush()
            CleanupGroupsCache.saveBlurIDs([])
        }

        let photos = allPhotos
        let videos = allVideos
        let sizes = sizeRecords
        let aiCats = await cache.getAllAICategories()
        let built = await Task.detached(priority: .utility) {
            Self.buildLibrarySnapshot(
                photos: photos,
                videos: videos,
                sizeRecords: sizes,
                cachedAICategories: aiCats
            )
        }.value
        applySnapshot(built)
        // PhotoKit smart-album fetches can still list deleted IDs briefly.
        // Reconcile every published surface against the pruned library so Home
        // never keeps Live / Screenshots / Screen Recordings / etc. shells.
        reconcilePublishedSurfacesAfterDeletion(deletedSet)
        await cache.putPhotoGroups(duplicates: photoDuplicates, similars: photoSimilars)
        await cache.putVideoGroups(duplicates: videoDuplicates, similars: videoSimilars)
        if blurryPhotosAlbum == nil {
            await cache.flush()
        }
        persistSnapshotModels()
    }

    /// Drops deleted (and otherwise missing) IDs from every Home-facing album /
    /// group / AI category. Emptied surfaces become `nil` / `[]` so the Home
    /// bridge cannot paint stale cards after Smart Clean or category wipe.
    private func reconcilePublishedSurfacesAfterDeletion(_ deleted: Set<String>) {
        let livePhotoIDs = Set(allPhotos.map(\.localIdentifier))
        let liveVideoIDs = Set(allVideos.map(\.localIdentifier))

        func stripAlbum(_ album: SmartAlbumItem, live: Set<String>) -> SmartAlbumItem? {
            let ids = album.assetIDs.filter { live.contains($0) && !deleted.contains($0) }
            guard !ids.isEmpty else { return nil }
            var copy = album
            copy.assetIDs = ids
            copy.count = ids.count
            copy.newestAssetID = ids.first
            copy.totalBytes = ids.reduce(Int64(0)) { $0 + (sizeRecords[$1]?.totalBytes ?? 0) }
            return copy
        }

        photoSmartAlbums = photoSmartAlbums.compactMap { stripAlbum($0, live: livePhotoIDs) }
        videoSmartAlbums = videoSmartAlbums.compactMap { stripAlbum($0, live: liveVideoIDs) }
        if let large = largePhotosAlbum {
            largePhotosAlbum = stripAlbum(large, live: livePhotoIDs)
        }
        if let old = oldPhotosAlbum {
            oldPhotosAlbum = stripAlbum(old, live: livePhotoIDs)
        }
        if let largeVideos = largeVideosAlbum {
            largeVideosAlbum = stripAlbum(largeVideos, live: liveVideoIDs)
        }

        if var blur = blurryPhotosAlbum {
            blur.assetIDs = blur.assetIDs.filter { livePhotoIDs.contains($0) && !deleted.contains($0) }
            blur.count = blur.assetIDs.count
            blur.totalBytes = blur.assetIDs.reduce(Int64(0)) { $0 + (sizeRecords[$1]?.totalBytes ?? 0) }
            blur.newestAssetID = blur.assetIDs.first
            blurryPhotosAlbum = blur.assetIDs.isEmpty ? nil : blur
        }
        if blurryPhotosAlbum == nil {
            CleanupGroupsCache.saveBlurIDs([])
        }

        aiCategories = aiCategories.compactMap { category in
            let ids = category.assetIDs.filter { livePhotoIDs.contains($0) && !deleted.contains($0) }
            guard !ids.isEmpty else { return nil }
            var copy = category
            copy.assetIDs = ids
            copy.count = ids.count
            copy.coverAssetID = ids.first
            copy.totalBytes = ids.reduce(Int64(0)) { $0 + (sizeRecords[$1]?.totalBytes ?? 0) }
            return copy
        }

        photoDuplicates = cleanGroups(photoDuplicates, deleted: deleted.union(
            Set(photoDuplicates.flatMap(\.items).map(\.id)).subtracting(livePhotoIDs)
        ))
        photoSimilars = cleanGroups(photoSimilars, deleted: deleted.union(
            Set(photoSimilars.flatMap(\.items).map(\.id)).subtracting(livePhotoIDs)
        ))
        videoDuplicates = cleanGroups(videoDuplicates, deleted: deleted.union(
            Set(videoDuplicates.flatMap(\.items).map(\.id)).subtracting(liveVideoIDs)
        ))
        videoSimilars = cleanGroups(videoSimilars, deleted: deleted.union(
            Set(videoSimilars.flatMap(\.items).map(\.id)).subtracting(liveVideoIDs)
        ))
    }

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
            self.sizeRecords = self.sizeRecords.filter { !deletedSet.contains($0.key) }
            
            // Clean duplicate groups
            self.photoDuplicates = cleanGroups(self.photoDuplicates, deleted: deletedSet)
            self.photoSimilars = cleanGroups(self.photoSimilars, deleted: deletedSet)
            self.videoDuplicates = cleanGroups(self.videoDuplicates, deleted: deletedSet)
            self.videoSimilars = cleanGroups(self.videoSimilars, deleted: deletedSet)
            
            // Prune deleted assets from the blur album + on-disk blur flags.
            if var blur = self.blurryPhotosAlbum {
                blur.assetIDs.removeAll { deletedSet.contains($0) }
                blur.count = blur.assetIDs.count
                blur.totalBytes = blur.assetIDs.reduce(Int64(0)) { $0 + (self.sizeRecords[$1]?.totalBytes ?? 0) }
                self.blurryPhotosAlbum = blur.assetIDs.isEmpty ? nil : blur
            }
            await cache.removeBlurryPhotoIDs(deletedSet)
            if self.blurryPhotosAlbum == nil {
                await cache.flush()
                CleanupGroupsCache.saveBlurIDs([])
            }
            
            // Recalculate smart albums & overview in background
            let sizes = self.sizeRecords
            let aiCats = await cache.getAllAICategories()
            let snapshot = await Task.detached(priority: .userInitiated) {
                let assets = Self.fetchLibraryAssets()
                let built = Self.buildLibrarySnapshot(
                    photos: assets.photos,
                    videos: assets.videos,
                    sizeRecords: sizes,
                    cachedAICategories: aiCats
                )
                return (built, assets.photosFetch, assets.videosFetch)
            }.value
            self.photosFetchResult = snapshot.1
            self.videosFetchResult = snapshot.2
            self.applySnapshot(snapshot.0)
            // PhotoKit fetch can briefly still list just-deleted assets.
            self.allPhotos.removeAll { deletedSet.contains($0.localIdentifier) }
            self.allVideos.removeAll { deletedSet.contains($0.localIdentifier) }
            self.reconcilePublishedSurfacesAfterDeletion(deletedSet)
            await cache.putPhotoGroups(duplicates: photoDuplicates, similars: photoSimilars)
            await cache.putVideoGroups(duplicates: videoDuplicates, similars: videoSimilars)
            self.persistSnapshotModels()
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

#if canImport(Photos)
/// Bridges PHPhotoLibrary change callbacks into the coordinator — the
/// change-observer protocol requires NSObject conformance, so the box
/// inherits it and forwards on the main actor.
private final class PhotoLibraryChangeObserverBox: NSObject, PHPhotoLibraryChangeObserver {
    weak var coordinator: PhotoManagerCoordinator?

    init(coordinator: PhotoManagerCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    #if canImport(Photos)
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let coordinator else { return }
        Task { @MainActor in
            coordinator.handlePhotoLibraryChange(changeInstance)
        }
    }
    #endif
}
#endif

// MARK: - Manual Pipeline Control Types

/// The four independently controllable pipeline processes. Blur detection
/// rides the AI sort pass (same decoded thumbnail), not its own process.
public enum PhotoManagerProcess: String, CaseIterable, Sendable, Identifiable {
    case photoDedupe
    case videoDedupe
    case sizeFetch
    case aiSort

    public var id: String { rawValue }
}

public enum PhotoManagerProcessState: String, Sendable {
    case idle
    case running
    case paused
    case completed
    case cancelled
}

/// Cooperative pause gate. Scan loops call `waitIfPaused()` at batch
/// boundaries; `resume()` releases every waiter. Cancellation is separate —
/// it uses `Task.cancel` and the loops' existing `Task.isCancelled` checks.
public actor ProcessPauseGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func pause() {
        paused = true
    }

    public func resume() {
        paused = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    public func waitIfPaused() async {
        guard paused else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
